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
if [[ -e "${VM_DIR_ROOTFS_IMAGE}" ]]; then
  rm "${VM_DIR_ROOTFS_IMAGE}"
fi
cp --reflink=auto "${FC_IMAGES_DIR}/${ROOTFS_IMAGE}" "${VM_DIR_ROOTFS_IMAGE}" ||
  fail "Could not copy ${ROOTFS_IMAGE} into vm directory."
chmod 0600 "${VM_DIR_ROOTFS_IMAGE}"
chown "${VM_UID}:${VM_GID}" "${VM_DIR_ROOTFS_IMAGE}"

JAILER_DIR_ROOTFS_IMAGE="${JAILER_ROOT_DIR}/${ROOTFS_IMAGE}"
if [[ -e "${JAILER_DIR_ROOTFS_IMAGE}" ]]; then
  rm "${JAILER_DIR_ROOTFS_IMAGE}"
fi
ln "${VM_DIR}/${ROOTFS_IMAGE}" "${JAILER_DIR_ROOTFS_IMAGE}" ||
  fail "Could not hardlink ${ROOTFS_IMAGE} into jailer root directory."
chmod 0600 "${JAILER_DIR_ROOTFS_IMAGE}"
chown "${VM_UID}:${VM_GID}" "${JAILER_DIR_ROOTFS_IMAGE}"

# ------------------------------------------------------------
# 2. Configure networking
# ------------------------------------------------------------

echo "2. Configure networking"

# Let the kernel route packets between interfaces (guest <-> uplink)
echo 1 | tee /proc/sys/net/ipv4/ip_forward >/dev/null

# Create the tap device, owned by the user/group that will run Firecracker
ip tuntap add "${HOST_DEV_NAME}" mode tap user "${VM_UID}" group "${VM_GID}"
# Turn off IPv6 on the tap so it has no v6 address or link-local traffic
sysctl -qw "net.ipv6.conf.${HOST_DEV_NAME}.disable_ipv6=1"
# Give the host end of the /30 its address (the guest's gateway)
ip addr add "${HOST_IP}/30" dev "${HOST_DEV_NAME}"
# Bring the tap up
ip link set "${HOST_DEV_NAME}" up

# Load the whole ruleset in one atomic nft transaction
nft -f - <<EOF
# One table in the inet family, so it sees both IPv4 and IPv6
table inet ${NFT_TABLE} {
  # NAT chain, runs after routing is decided
  chain postrouting {
    # Hook into postrouting at NAT priority; unmatched packets pass
    type nat hook postrouting priority srcnat; policy accept;
    # Rewrite the guest's source IP to the host's uplink IP so replies find their way back
    ip saddr ${VM_IP} oifname "${UPLINK_IFACE}" masquerade
  }

  # Filter chain for traffic routed THROUGH the host (guest <-> other networks)
  chain forward {
    # Hook into forward; unmatched packets pass
    type filter hook forward priority filter; policy accept;

    # Let replies to connections that are already allowed come back
    ct state established,related accept
    # Block any new connection into the guest from other networks
    oifname "${HOST_DEV_NAME}" drop

    # Drop all IPv6 coming from the tap
    iifname "${HOST_DEV_NAME}" meta nfproto ipv6 drop
    # Drop packets whose source isn't the guest's real IP (anti-spoofing)
    iifname "${HOST_DEV_NAME}" ip saddr != ${VM_IP} drop
    # Block guest access to private, link-local (incl. cloud metadata), CGNAT,
    # benchmarking, and multicast/reserved/broadcast IPv4 ranges
    iifname "${HOST_DEV_NAME}" ip daddr {
        10.0.0.0/8,
        100.64.0.0/10,
        169.254.0.0/16,
        172.16.0.0/12,
        192.168.0.0/16,
        198.18.0.0/15,
        224.0.0.0/3
    } drop

    # NOTE: the guest must use a public DNS resolver; private or host resolvers are blocked
    # Allow web and DNS over tcp (53, 80, 443) out the uplink (public IPs only; see drop above)
    iifname "${HOST_DEV_NAME}" oifname "${UPLINK_IFACE}" tcp dport { 53, 80, 443 } accept
    # Allow DNS and QUIC over udp (53, 443) out the uplink (public IPs only)
    iifname "${HOST_DEV_NAME}" oifname "${UPLINK_IFACE}" udp dport { 53, 443 } accept
    # Allow the guest to ping out (IPv4)
    iifname "${HOST_DEV_NAME}" oifname "${UPLINK_IFACE}" icmp type echo-request accept
    # Anything else from the tap is dropped
    iifname "${HOST_DEV_NAME}" drop
  }

  # Filter chain for traffic addressed TO the host itself (guest -> host)
  chain input {
    # Hook into input; unmatched packets pass
    type filter hook input priority filter; policy accept;

    # Allow replies to connections the host started (ssh/rsync into the guest)
    iifname "${HOST_DEV_NAME}" ct state established,related accept
    # Allow the guest to ping the host (IPv4)
    iifname "${HOST_DEV_NAME}" icmp type echo-request accept
    # Everything else from the guest to the host is dropped
    iifname "${HOST_DEV_NAME}" drop
  }
}
EOF

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
