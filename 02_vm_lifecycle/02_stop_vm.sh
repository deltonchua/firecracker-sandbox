#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 1. Stop firecracker
# ------------------------------------------------------------

echo "1. Stop firecracker"

pkill -TERM -f "/firecracker --id ${VM_ID}" ||
  fail "Could not terminate firecracker."

# ------------------------------------------------------------
# 2. Clean up networking
# ------------------------------------------------------------

echo "2. Clean up networking"

ip link del "${HOST_DEV_NAME}" ||
  fail "Could not delete tap device."

# NOTE: Run the following only if you have no more guests
# running on the host
echo 0 | tee /proc/sys/net/ipv4/ip_forward >/dev/null
nft delete table inet "${NFT_TABLE}"

# ------------------------------------------------------------
# 3. Remove VM IP from known hosts
# ------------------------------------------------------------

echo "3. Remove VM IP from known hosts"

SSH_USER="${SUDO_USER:-$(id -un)}"

sudo -u "${SSH_USER}" ssh-keygen \
  -R "${VM_IP}" -f "${KNOWN_HOSTS}" \
  >/dev/null 2>&1 ||
  fail "Could not remove VM IP from known hosts."

# ------------------------------------------------------------
# 4. Delete VM rootfs
# ------------------------------------------------------------

echo "4. Delete VM rootfs"

JAILER_DIR_ROOTFS_IMAGE="${JAILER_ROOT_DIR}/${ROOTFS_IMAGE}"
if [[ -e "${JAILER_DIR_ROOTFS_IMAGE}" ]]; then
  rm "${JAILER_DIR_ROOTFS_IMAGE}"
fi

VM_DIR_ROOTFS_IMAGE="${VM_DIR}/${ROOTFS_IMAGE}"
if [[ -e "${VM_DIR_ROOTFS_IMAGE}" ]]; then
  rm "${VM_DIR_ROOTFS_IMAGE}"
fi

# ------------------------------------------------------------
# 5. Clean up jailer artifacts
# ------------------------------------------------------------

echo "5. Clean up jailer artifacts"

rm -rf "${JAILER_ROOT_DIR}/dev"
rm "${JAILER_ROOT_DIR}/firecracker"
rm "${JAILER_ROOT_DIR}/firecracker.pid"
# rm "${JAILER_ROOT_DIR}/run/firecracker.socket"
