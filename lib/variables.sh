# System
CPU_ARCH="$(uname -m)"

# Firecracker
FC_ROOT="/opt/firecracker"
FC_BIN_DIR="${FC_ROOT}/bin"
FC_IMAGES_DIR="${FC_ROOT}/images"
FC_VERSION="v1.16.1"

# Jailer
JAILER_CHROOT_BASE_DIR="/srv/jailer"
JAILER_EXEC_NAME="firecracker" # jailer derives this from --exec-file basename

# Images
KERNEL_VERSION="6.18"
KERNEL_PATCH="62" # NOTE: Manually update patch version after 00_get_kernel.sh
KERNEL_IMAGE="vmlinux-${KERNEL_VERSION}.${KERNEL_PATCH}"
ROOTFS_IMAGE="rootfs.ext4"
ROOTFS_SIZE_MB="4096"
ARCH_BASE_PACKAGES=(
  base
  base-devel
  bat
  curl
  fastfetch
  fd
  fzf
  git
  go
  htop
  jq
  man-db
  neovim
  nodejs
  npm
  openssh
  podman
  python
  ripgrep
  rustup
  tmux
  tree
  tree-sitter-cli
  uv
  unzip
  wget
  zip
  zoxide
)
WORKER_UID=1000
WORKER_GID=1000
DATA_IMAGE="data.ext4"
DATA_SIZE_MB="20480"
HOST_SSH_PUBKEY="$(</path/to/ssh-pubkey)"
# HOST_SSH_PUBKEY="" # Use password
KNOWN_HOSTS="/path/to/known_hosts"
DOTFILES_DIR="/path/to/dotfiles"

# VM
VM_NO=0
VM_ID="vm${VM_NO}"
VM_UID="$((10000 + VM_NO))"
VM_GID="${VM_UID}"
VM_USER_NAME="fc-${VM_ID}"
VM_GROUP_NAME="${VM_USER_NAME}"
VM_DIR="${FC_ROOT}/${VM_ID}"
JAILER_ROOT_DIR="${JAILER_CHROOT_BASE_DIR}/${JAILER_EXEC_NAME}/${VM_ID}/root"
VM_FC_CONFIG="${JAILER_ROOT_DIR}/config.json"
KERNEL_BOOT_ARGS="reboot=k panic=1 pci=off ipv6.disable=1 nomodules tsc=reliable quiet 8250.nr_uarts=0 i8042.nokbd i8042.noaux systemd.hostname=${VM_ID}"
# KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off nomodules i8042.nokbd i8042.noaux systemd.hostname=${VM_ID}" # For debugging
VCPU_COUNT=4
MEM_SIZE_MIB=8192
SMT_ENABLED=false

# Network
UPLINK_IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
NFT_TABLE="firecracker"
SUBNET_MASK="255.255.255.252" # equals to /30 -> 2 usable addresses (one for the host and one for the guest)
HOST_IP="10.0.$(((4 * VM_NO + 1) / 256)).$(((4 * VM_NO + 1) % 256))"
HOST_DEV_NAME="tap${VM_NO}"
VM_IP="10.0.$(((4 * VM_NO + 2) / 256)).$(((4 * VM_NO + 2) % 256))"
VM_MAC="$(printf '02:FC:00:00:%02X:%02X' $((VM_NO / 256)) $((VM_NO % 256)))"
KERNEL_BOOT_ARGS="${KERNEL_BOOT_ARGS} ip=${VM_IP}::${HOST_IP}:${SUBNET_MASK}::eth0:off"
