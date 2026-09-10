#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 0. Configuration
# ------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
ROOTFS_OUT="${FC_IMAGES_DIR}/${ROOTFS_IMAGE}"
ROOTFS_TMP="${TMP_DIR}/${ROOTFS_IMAGE}"
ROOTFS_MNT="${TMP_DIR}/rootfs-mnt"
LOOP_DEV=""

cleanup() {
  # Best-effort cleanup on success or failure.
  if [[ -n "${LOOP_DEV:-}" ]]; then
    umount "${ROOTFS_MNT}" 2>/dev/null || true
    losetup -d "${LOOP_DEV}" 2>/dev/null || true
  fi

  rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

# ------------------------------------------------------------
# 1. Prepare workspace
# ------------------------------------------------------------

echo "1. Prepare workspace"

install -d -m 0755 "${ROOTFS_MNT}"

# ------------------------------------------------------------
# 2. Create rootfs image and filesystem
# ------------------------------------------------------------

echo "2. Create ${ROOTFS_SIZE_MB}MB ext4 rootfs image"

truncate -s "${ROOTFS_SIZE_MB}M" "${ROOTFS_TMP}" ||
  fail "Could not allocate rootfs image file."

mkfs.ext4 -q "${ROOTFS_TMP}" ||
  fail "mkfs.ext4 failed."

LOOP_DEV="$(losetup --find --show "${ROOTFS_TMP}")" ||
  fail "Could not attach loop device."

mount "${LOOP_DEV}" "${ROOTFS_MNT}" ||
  fail "Could not mount rootfs image."

# ------------------------------------------------------------
# 3. Pacstrap Arch base + development tools
# ------------------------------------------------------------

echo "3. Pacstrap Arch base + development tools"

pacstrap -K "${ROOTFS_MNT}" "${ARCH_BASE_PACKAGES[@]}" ||
  fail "pacstrap failed."

# pacstrap -K may leave gpg-agent watching the target keyring.
gpg-connect-agent --homedir "${ROOTFS_MNT}/etc/pacman.d/gnupg" \
  KILLAGENT /bye 2>/dev/null || true

# # Firecracker supplies the root device via the kernel command line.
# : >"${ROOTFS_MNT}/etc/fstab"

# ------------------------------------------------------------
# 4. Create worker
# ------------------------------------------------------------

echo "4. Create worker"

# Enable sudo for the standard Arch wheel group.
install -d -m 0755 "${ROOTFS_MNT}/etc/sudoers.d"

cat >"${ROOTFS_MNT}/etc/sudoers.d/10-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF

chmod 0440 "${ROOTFS_MNT}/etc/sudoers.d/10-wheel"

# Create the worker user with a bash shell,
# then add it to the wheel group.
arch-chroot "${ROOTFS_MNT}" \
  groupadd -g "${WORKER_GID}" worker ||
  fail "Could not create worker group."

arch-chroot "${ROOTFS_MNT}" \
  useradd -u "${WORKER_UID}" -g "${WORKER_GID}" \
  -G wheel -s /bin/bash worker ||
  fail "Could not create worker user."

# Set worker password
printf '%s\n' 'worker:worker' |
  arch-chroot "${ROOTFS_MNT}" chpasswd ||
  fail "Could not set worker password."

# Root filesystem is mounted by Firecracker/kernel.
# The worker home lives on the separate data disk.
install -d -m 0755 "${ROOTFS_MNT}/home/worker"

cat >"${ROOTFS_MNT}/etc/fstab" <<'EOF'
/dev/vdb  /home/worker  ext4  defaults  0  2
EOF

# ------------------------------------------------------------
# 5. Enable SSHD
# ------------------------------------------------------------

echo "5. Enable SSHD"

arch-chroot "${ROOTFS_MNT}" systemctl enable sshd ||
  fail "Could not enable sshd."

# Optional SSH public key for worker user login.
# If empty, worker:worker password authentication is used instead.
install -d -m 0755 "${ROOTFS_MNT}/etc/ssh/sshd_config.d"

if [[ -n "${HOST_SSH_PUBKEY}" ]]; then
  # Disable root login and allow SSH access only for worker using public keys.
  cat >"${ROOTFS_MNT}/etc/ssh/sshd_config.d/10-sandbox.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers worker
EOF

else
  # Disable root login and allow password authentication for worker.
  cat >"${ROOTFS_MNT}/etc/ssh/sshd_config.d/10-sandbox.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AllowUsers worker
EOF

fi

# ------------------------------------------------------------
# 6. Configure DNS
# ------------------------------------------------------------

echo "6. Configure DNS"

cat >"${ROOTFS_MNT}/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# ------------------------------------------------------------
# 7. Unmount rootfs
# ------------------------------------------------------------

echo "7. Unmount rootfs"

umount "${ROOTFS_MNT}" ||
  fail "Could not unmount rootfs-mnt."

losetup -d "${LOOP_DEV}" ||
  fail "Could not detach loop device."

LOOP_DEV=""

mv "${ROOTFS_TMP}" "${ROOTFS_OUT}" ||
  fail "Could not move finished rootfs into place."

chmod 0644 "${ROOTFS_OUT}"

echo "Rootfs created: ${ROOTFS_OUT}"

# ------------------------------------------------------------
# 8. Verify rootfs
# ------------------------------------------------------------

echo "8. Verify rootfs"

e2fsck -fn "${ROOTFS_OUT}" >/dev/null 2>&1 ||
  fail "Rootfs verification failed."

echo "Provisioned size: $(du -h --apparent-size "${ROOTFS_OUT}" | cut -f1)"
