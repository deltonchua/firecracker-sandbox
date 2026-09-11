# firecracker-sandbox

A set of small, composable Bash scripts for building and managing **isolated
micro-VMs** on a Linux host using
[Firecracker](https://firecracker-microvm.github.io/) and its `jailer`.

The goal is a lightweight, hand-rolled "sandbox" you can SSH into: disposable,
hardware-virtualized VMs suitable as hardened development/build environments or
for running untrusted code. The guest image is **Arch Linux**, built with
`pacstrap`.

Intended for local development use only; not hardened or tested for production.

> These scripts are Linux-only, must be run as **root**, and assume an
> **Arch-based host** for building the guest image (see
> [Prerequisites](#prerequisites) and [Porting to a non-Arch host/guest](#porting-to-a-non-arch-hostguest)).
> They are intentionally explicit and step-by-step rather than a single
> monolithic tool.

---

## How it works

The workflow has three phases, encoded as numbered directories. Run the scripts
in order:

```
00_host_prep/                 one-time host setup
01_guest_kernel_rootfs_data/  build the "golden" guest images (kernel + rootfs + data disk)
02_vm_lifecycle/              create / start / stop / delete individual VMs
lib/                          shared config (variables.sh) and helpers (utils.sh)
```

### Lifecycle at a glance

1. **Prepare the host** (once) - verify KVM, install pinned `firecracker`/`jailer`, tighten host security.
2. **Build golden images** (once, or when images change) - download a Firecracker CI kernel, build an Arch rootfs and a separate data disk.
3. **Create a VM** (once per `VM_NO`) - provision a dedicated jailer user/group and copy images.
4. **Start a VM** (daily) - refresh the rootfs from the golden image, set up a TAP network + nftables NAT, generate `config.json`, launch under `jailer`.
5. **SSH in** - `ssh worker@<VM_IP>`.
6. **Stop a VM** (daily) - tear down the VM process, its network, jailer artifacts, and the host SSH `known_hosts` entry.
7. **Delete a VM** (occasional) - remove the jailer user and VM directories.

---

## Prerequisites

- A Linux host with hardware virtualization (Intel VT-x / AMD-V) enabled in BIOS.
- `/dev/kvm` present and the `kvm_intel` or `kvm_amd` module loaded.
- Root access (the scripts call `require_root`; the quick start uses `sudo`).
- An Arch host for the guest build: `pacstrap`/`arch-chroot` are used by
  [`01_guest_kernel_rootfs_data/01_create_rootfs.sh`](01_guest_kernel_rootfs_data/01_create_rootfs.sh).
  For other distributions, see [Porting to a non-Arch host/guest](#porting-to-a-non-arch-hostguest).
- Outbound network access (downloads Firecracker, the guest kernel, and Arch packages).
- Swap **disabled** and KSM **disabled** (checked/enforced by `00_host_prep/02_basic_security.sh`).

---

## Configuration

All tunables live in [`lib/variables.sh`](lib/variables.sh). **Edit it before
running any script.** These placeholders you *must* set:

| Variable          | Purpose                                                 |
|-------------------|---------------------------------------------------------|
| `HOST_SSH_PUBKEY` | Public key injected into `worker`'s `authorized_keys`. Set to `""` to fall back to `worker:worker` password auth. |
| `KNOWN_HOSTS`     | Path to the host `known_hosts` file to clean up on stop. |
| `DOTFILES_DIR`    | Optional directory whose contents are copied to `/home/worker` on the data disk. |

Other notable settings:

| Variable        | Default                         | Meaning                                      |
|-----------------|---------------------------------|----------------------------------------------|
| `FC_VERSION`    | `v1.16.1`                       | Pinned Firecracker / jailer release.         |
| `KERNEL_VERSION`/`KERNEL_PATCH` | `6.18` / `44`   | Guest kernel. |
| `ROOTFS_SIZE_MB`/`DATA_SIZE_MB` | `4096` / `20480`| Golden image sizes.                          |
| `VCPU_COUNT` / `MEM_SIZE_MIB` / `SMT_ENABLED` | `4` / `8192` / `false` | Machine config per VM. |
| `VM_NO`         | `0`                             | **VM index.** Drives UID/GID, `vm_id`, tap name, MAC, and host/VM IPs. Increment per VM. |

### Networking & scaling scheme

`VM_NO` deterministically derives everything, so multiple VMs coexist. The
host-to-guest link is a `/30` subnet (2 usable addresses), and `VM_MAC` plus the
jailer `UID`/`GID` (`10000 + VM_NO`) follow from the same index:

- `VM_NO=0` -> host `10.0.0.1`, guest `10.0.0.2`, tap `tap0`.
- `VM_NO=1` -> host `10.0.0.5`, guest `10.0.0.6`, tap `tap1`, etc.

To run more than one VM, set `VM_NO` to a unique value (e.g. edit
`variables.sh` per invocation) and repeat the lifecycle steps.

---

## Quick start

```bash
# 1. Host preparation (once)
sudo ./00_host_prep/00_kvm.sh
sudo ./00_host_prep/01_firecracker_jailer.sh
sudo ./00_host_prep/02_basic_security.sh

# 2. Build the golden guest images (once, or when images change)
sudo ./01_guest_kernel_rootfs_data/00_get_kernel.sh
#    -> then set KERNEL_PATCH in lib/variables.sh to match the downloaded file
sudo ./01_guest_kernel_rootfs_data/01_create_rootfs.sh
sudo ./01_guest_kernel_rootfs_data/02_create_data.sh

# 3. Create the VM (once per VM_NO)
sudo ./02_vm_lifecycle/00_create_vm.sh

# 4. Start the VM (daily)
sudo ./02_vm_lifecycle/01_start_vm.sh

# 5. Connect
ssh worker@10.0.0.2   # VM_IP for VM_NO=0

# 6. Stop the VM (daily)
sudo ./02_vm_lifecycle/02_stop_vm.sh

# 7. Delete the VM (only to fully remove it)
sudo ./02_vm_lifecycle/03_delete_vm.sh
```

The day-to-day loop is just **`01_start_vm.sh` -> `ssh` -> `02_stop_vm.sh`**.
Re-running `01_start_vm.sh` does not require `00_create_vm.sh` again - see
[Design notes](#design-notes) for why the workspace survives each restart.

---

## Script reference

### `00_host_prep/` - one-time host setup

| Script                       | What it does                                                                 |
|------------------------------|------------------------------------------------------------------------------|
| `00_kvm.sh`                  | Verifies `/dev/kvm` and a loaded `kvm_intel`/`kvm_amd` module; sets `root:kvm 660` permissions. |
| `01_firecracker_jailer.sh`   | Installs pinned `firecracker` and `jailer` into `/opt/firecracker/bin`; creates `/srv/jailer` chroot base. |
| `02_basic_security.sh`       | Fails if swap is enabled; disables KSM. SMT/microcode hardening is left to the operator. |

### `01_guest_kernel_rootfs_data/` - build golden images

| Script                | What it does                                                                                   |
|-----------------------|------------------------------------------------------------------------------------------------|
| `00_get_kernel.sh`    | Finds and downloads the latest Firecracker CI `vmlinux` for `KERNEL_VERSION` from the S3 bucket. |
| `01_create_rootfs.sh` | Builds an ext4 rootfs via `pacstrap` (Arch base + dev tools), creates the `worker` user, enables `sshd`, writes fstab/resolv.conf. |
| `02_create_data.sh`   | Builds the larger ext4 data disk (mounted at `/home/worker`), seeds dotfiles and SSH keys, sets `worker` ownership. |

### `02_vm_lifecycle/` - per-VM lifecycle

| Script              | Cadence              | What it does                                                                                                          |
|---------------------|----------------------|-----------------------------------------------------------------------------------------------------------------------|
| `00_create_vm.sh`   | once per `VM_NO`     | Creates a dedicated `fc-vm<N>` user/group; copies golden images into the VM dir and hardlinks them into the jailer root. |
| `01_start_vm.sh`    | daily                | Refreshes the VM's rootfs from the golden image, sets up the TAP device + nftables NAT/forward rules, writes `config.json`, and launches Firecracker under `jailer` with cgroup CPU/memory/pids limits (cgroup v1 and v2 aware). |
| `02_stop_vm.sh`     | daily                | Terminates Firecracker, deletes the TAP device, removes the nftables table, cleans the host `known_hosts` entry and jailer artifacts. |
| `03_delete_vm.sh`   | occasional           | Deletes the jailer user and removes the VM directories.                                                                |

---

## Design notes

- **Disposable rootfs, persistent home.** On every `start`, the guest rootfs is
  re-copied from the pristine golden image, while `/home/worker` lives on the
  separate, persistent **data disk**. This gives ephemeral compute with a durable
  workspace, and is why `01_start_vm.sh`/`02_stop_vm.sh` are the only daily steps.
- **Defense in depth.** Each VM runs under a dedicated user via the `jailer`
  chroot, with KVM access checks, cgroup CPU/memory/PID limits, disabled swap &
  KSM, and hardened SSH (`PermitRootLogin no`, key-or-password auth,
  `AllowUsers worker`).
- **No Firecracker API.** VMs are launched `--daemonize --no-api` from a
  generated `config.json`, keeping the runtime surface minimal.

---

## Porting to a non-Arch host/guest

The **only** Arch-specific script is
[`01_guest_kernel_rootfs_data/01_create_rootfs.sh`](01_guest_kernel_rootfs_data/01_create_rootfs.sh):
it builds the rootfs by running `pacstrap` and `arch-chroot` and installing the
`ARCH_BASE_PACKAGES` list. To target other distributions, rewrite that one
script for your distro's bootstrap tooling - e.g. `debootstrap` (Debian/Ubuntu),
`dnf --installroot` (Fedora/RHEL), or `mkosi` - and replace the package list
(`ARCH_BASE_PACKAGES` lives in [`lib/variables.sh`](lib/variables.sh)) with your
distro's equivalents. Everything else (host prep, the data disk, and the VM
lifecycle scripts) is distribution-agnostic, provided you:

- keep a `worker` user with UID/GID matching `WORKER_UID`/`WORKER_GID`,
- enable an SSH server with the same hardening in `sshd_config.d`,
- leave `/etc/fstab` mounting `/dev/vdb` at `/home/worker`, and
- keep the kernel boot args compatible with the guest's init system.

---

## Caveats / TODO

- These scripts are **not fully idempotent as a whole** and have no top-level
  orchestration - follow the numbered order.
- `KERNEL_PATCH` in `lib/variables.sh` must be **manually** updated to match the
  filename produced by `00_get_kernel.sh` before `config.json` will resolve it.
- The placeholder paths in `lib/variables.sh` (`/path/to/...`) must be set before
  the image/lifecycle scripts will succeed.
- `02_stop_vm.sh` disables global `ip_forward` and deletes the whole
  `firecracker` nftables table - **only safe if no other guests are running**; 
  comment out the relevant lines if running multiple guests.

---

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE) for details.
