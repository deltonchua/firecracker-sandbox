#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 0. Configuration
# ------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
DATA_OUT="${FC_IMAGES_DIR}/${DATA_IMAGE}"
DATA_TMP="${TMP_DIR}/${DATA_IMAGE}"
DATA_MNT="${TMP_DIR}/data-mnt"
LOOP_DEV=""

cleanup() {
  # Best-effort cleanup on success or failure.
  if [[ -n "${LOOP_DEV:-}" ]]; then
    umount "${DATA_MNT}" 2>/dev/null || true
    losetup -d "${LOOP_DEV}" 2>/dev/null || true
  fi

  rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

# ------------------------------------------------------------
# 1. Prepare workspace
# ------------------------------------------------------------

echo "1. Prepare workspace"

install -d -m 0755 "${DATA_MNT}"

# ------------------------------------------------------------
# 2. Create data image and filesystem
# ------------------------------------------------------------

echo "2. Create ${DATA_SIZE_MB}MB ext4 data image"

truncate -s "${DATA_SIZE_MB}M" "${DATA_TMP}" ||
  fail "Could not allocate data image file."

mkfs.ext4 -q "${DATA_TMP}" ||
  fail "mkfs.ext4 failed."

LOOP_DEV="$(losetup --find --show "${DATA_TMP}")" ||
  fail "Could not attach loop device."

mount "${LOOP_DEV}" "${DATA_MNT}" ||
  fail "Could not mount data image."

# ------------------------------------------------------------
# 3. Copy dotfiles
# ------------------------------------------------------------

echo "3. Copy dotfiles"

# Copy dotfiles into worker's home.
if [[ -d "${DOTFILES_DIR}" ]]; then
  cp -a "${DOTFILES_DIR}/." "${DATA_MNT}" ||
    fail "Could not copy dotfiles."
fi

# ------------------------------------------------------------
# 4. Configure SSH authentication
# ------------------------------------------------------------

echo "4. Configure SSH authentication"

# Optional SSH public key for worker user login.
# If empty, SSH falls back to password authentication.
if [[ -n "${HOST_SSH_PUBKEY}" ]]; then
  echo "Use public-key authentication for worker."

  install -d -m 0700 "${DATA_MNT}/.ssh"

  printf '%s\n' "${HOST_SSH_PUBKEY}" \
    >"${DATA_MNT}/.ssh/authorized_keys"

  chmod 0600 "${DATA_MNT}/.ssh/authorized_keys"

else
  echo "Use worker password authentication."

fi

# ------------------------------------------------------------
# 5. Unmount data
# ------------------------------------------------------------

echo "5. Unmount data"

chown -R "${WORKER_UID}:${WORKER_GID}" "${DATA_MNT}" ||
  fail "Could not set worker ownership."

umount "${DATA_MNT}" ||
  fail "Could not unmount data-mnt."

losetup -d "${LOOP_DEV}" ||
  fail "Could not detach loop device."

LOOP_DEV=""

mv "${DATA_TMP}" "${DATA_OUT}" ||
  fail "Could not move finished data image into place."

chmod 0644 "${DATA_OUT}"

echo "Data image created: ${DATA_OUT}"

# ------------------------------------------------------------
# 6. Verify data image
# ------------------------------------------------------------

echo "6. Verify data image"

e2fsck -fn "${DATA_OUT}" >/dev/null 2>&1 ||
  fail "Data image verification failed."

echo "Provisioned size: $(du -h --apparent-size "${DATA_OUT}" | cut -f1)"
