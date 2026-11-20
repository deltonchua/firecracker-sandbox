#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 1. Create per-VM group and user
# ------------------------------------------------------------

echo "1. Create group and user for ${VM_ID}"

# Check GID and group-name availability
getent group "${VM_GID}" >/dev/null &&
  fail "GID ${VM_GID} already exists on the system."
getent group "${VM_GROUP_NAME}" >/dev/null &&
  fail "group ${VM_GROUP_NAME} already exists on the system."

# Check UID and username availability
getent passwd "${VM_UID}" >/dev/null &&
  fail "UID ${VM_UID} already exists on the system."
getent passwd "${VM_USER_NAME}" >/dev/null &&
  fail "user ${VM_USER_NAME} already exists on the system."

# Create a dedicated group and user
groupadd -g "${VM_GID}" "${VM_GROUP_NAME}" ||
  fail "groupadd failed for ${VM_ID}."
useradd -M -N -u "${VM_UID}" -g "${VM_GID}" -s /usr/sbin/nologin \
  -c "Firecracker jailer user for ${VM_ID}" "${VM_USER_NAME}" ||
  fail "useradd failed for ${VM_ID}."

# ------------------------------------------------------------
# 2. Copy images to vm directory
# ------------------------------------------------------------

echo "2. Copy images to ${VM_DIR}"

[[ -e "${VM_DIR}" ]] &&
  fail "${VM_DIR} already exists."
install -d -m 0700 -o "${VM_UID}" -g "${VM_GID}" "${VM_DIR}"

for image in "${KERNEL_IMAGE}" "${ROOTFS_IMAGE}" "${DATA_IMAGE}"; do
  cp --reflink=auto "${FC_IMAGES_DIR}/${image}" "${VM_DIR}/${image}" ||
    fail "Could not copy ${image} into vm directory."
  chmod 0600 "${VM_DIR}/${image}"
done

chown -R "${VM_UID}:${VM_GID}" "${VM_DIR}"

# ------------------------------------------------------------
# 3. Copy images to jailer root
# ------------------------------------------------------------

echo "3. Copy images to ${JAILER_ROOT_DIR}"

[[ -e "${JAILER_ROOT_DIR}" ]] &&
  fail "${JAILER_ROOT_DIR} already exists."
install -d -m 0700 -o "${VM_UID}" -g "${VM_GID}" "${JAILER_ROOT_DIR}"
install -d -m 0700 -o "${VM_UID}" -g "${VM_GID}" "${JAILER_ROOT_DIR}/run"

for image in "${KERNEL_IMAGE}" "${ROOTFS_IMAGE}" "${DATA_IMAGE}"; do
  ln "${VM_DIR}/${image}" "${JAILER_ROOT_DIR}/${image}" ||
    fail "Could not hardlink ${image} into jailer root directory."
  chmod 0600 "${JAILER_ROOT_DIR}/${image}"
done

chown -R "${VM_UID}:${VM_GID}" "${JAILER_ROOT_DIR}"
