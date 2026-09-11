#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 1. Refresh rootfs
# ------------------------------------------------------------

echo "1. Refresh rootfs"

VM_DIR_ROOTFS_IMAGE="${VM_DIR}/${ROOTFS_IMAGE}"
if [[ -e "$VM_DIR_ROOTFS_IMAGE" ]]; then
  rm "$VM_DIR_ROOTFS_IMAGE"
fi
cp --reflink=auto "${FC_IMAGES_DIR}/${ROOTFS_IMAGE}" "${VM_DIR_ROOTFS_IMAGE}" ||
  fail "Could not copy ${ROOTFS_IMAGE} into vm directory."
chmod 0600 "${VM_DIR_ROOTFS_IMAGE}"
chown "${VM_UID}:${VM_GID}" "${VM_DIR_ROOTFS_IMAGE}"

JAILER_DIR_ROOTFS_IMAGE="${JAILER_ROOT_DIR}/${ROOTFS_IMAGE}"
if [[ -e "$JAILER_DIR_ROOTFS_IMAGE" ]]; then
  rm "$JAILER_DIR_ROOTFS_IMAGE"
fi
ln "${VM_DIR}/${ROOTFS_IMAGE}" "${JAILER_DIR_ROOTFS_IMAGE}" ||
  fail "Could not hardlink ${ROOTFS_IMAGE} into jailer root directory."
chmod 0600 "${JAILER_DIR_ROOTFS_IMAGE}"
chown "${VM_UID}:${VM_GID}" "${JAILER_DIR_ROOTFS_IMAGE}"

# ------------------------------------------------------------
# 2. Configure networking
# ------------------------------------------------------------

echo "2. Configure networking"

# Enable IPv4 forwarding
echo 1 | tee /proc/sys/net/ipv4/ip_forward >/dev/null

# Create the tap device.
ip tuntap add ${HOST_DEV_NAME} mode tap
# Assign it the tap IP and start up the device.
ip addr add "${HOST_IP}/30" dev ${HOST_DEV_NAME}
ip link set ${HOST_DEV_NAME} up

# Create nft table
nft add table "${NFT_TABLE}"
nft "add chain ${NFT_TABLE} postrouting { type nat hook postrouting priority srcnat; policy accept; }"
nft "add chain ${NFT_TABLE} filter { type filter hook forward priority filter; policy accept; }"
# Add rules
nft add rule "${NFT_TABLE}" postrouting ip saddr "${VM_IP}" oifname "${UPLINK_IFACE}" counter masquerade
nft add rule "${NFT_TABLE}" filter iifname "${HOST_DEV_NAME}" oifname "${UPLINK_IFACE}" accept

# ------------------------------------------------------------
# 3. Prepare Firecracker config.json
# ------------------------------------------------------------

echo "3. Prepare Firecracker config.json"

cat >"${VM_FC_CONFIG}" <<EOF
{
  "boot-source": {
    "kernel_image_path": "/${KERNEL_IMAGE}",
    "boot_args": "${KERNEL_BOOT_ARGS}"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/${ROOTFS_IMAGE}",
      "is_root_device": true,
      "is_read_only": false
    },
    {
      "drive_id": "data",
      "path_on_host": "/${DATA_IMAGE}",
      "is_root_device": false,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "net0",
      "guest_mac": "${VM_MAC}",
      "host_dev_name": "${HOST_DEV_NAME}"
    }
  ],
  "machine-config": {
    "vcpu_count": ${VCPU_COUNT},
    "mem_size_mib": ${MEM_SIZE_MIB},
    "smt": ${SMT_ENABLED}
  }
}
EOF

chmod 0600 "${VM_FC_CONFIG}"
chown "${VM_UID}:${VM_GID}" "${VM_FC_CONFIG}"

# ------------------------------------------------------------
# 4. Launch firecracker with jailer
# ------------------------------------------------------------

echo "4. Launch firecracker with jailer"

CGROUP_CPU_PERIOD_US=100000
CGROUP_CPU_QUOTA_US=$((VCPU_COUNT * 100000)) # e.g. 200% -> "200000 100000"
CGROUP_MEM_MAX_BYTES=$((MEM_SIZE_MIB * 1024 * 1024))

if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  CGROUP_VERSION="2"
else
  CGROUP_VERSION="1"
fi

CGROUP_ARGS=()

if [[ "${CGROUP_VERSION}" == "2" ]]; then
  CGROUP_ARGS+=(
    --cgroup "cpu.max=${CGROUP_CPU_QUOTA_US} ${CGROUP_CPU_PERIOD_US}"
    --cgroup "memory.max=${CGROUP_MEM_MAX_BYTES}"
    --cgroup "pids.max=512"
  )
else
  CGROUP_ARGS+=(
    --cgroup "cpu.cfs_period_us=${CGROUP_CPU_PERIOD_US}"
    --cgroup "cpu.cfs_quota_us=${CGROUP_CPU_QUOTA_US}"
    --cgroup "memory.limit_in_bytes=${CGROUP_MEM_MAX_BYTES}"
    --cgroup "pids.max=512"
  )
fi

"${FC_BIN_DIR}/jailer" \
  --id "${VM_ID}" \
  --exec-file "${FC_BIN_DIR}/${JAILER_EXEC_NAME}" \
  --uid "${VM_UID}" \
  --gid "${VM_GID}" \
  --chroot-base-dir "${JAILER_CHROOT_BASE_DIR}" \
  --cgroup-version "${CGROUP_VERSION}" \
  "${CGROUP_ARGS[@]}" \
  --resource-limit no-file=4096 \
  --daemonize \
  -- \
  --config-file /config.json \
  --no-api

echo "Login: ssh worker@${VM_IP}"
