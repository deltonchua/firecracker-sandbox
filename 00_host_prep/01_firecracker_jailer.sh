#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 1. Create firecracker directories
# ------------------------------------------------------------

echo "1. Create firecracker directories"

# Create drwxr-xr-x root root /opt/firecracker/bin
install -d -m 0755 -o root -g root "${FC_BIN_DIR}"

# Create drwxr-x--- root root /opt/firecracker/images
install -d -m 0750 -o root -g root "${FC_IMAGES_DIR}"

# ------------------------------------------------------------
# 2. Create jailer directories
# ------------------------------------------------------------

echo "2. Create jailer directories"

# Create drwx------ root root /srv/jailer
install -d -m 0700 -o root -g root "${JAILER_CHROOT_BASE_DIR}"

JAILER_PARENT_DIR="$(dirname "${JAILER_CHROOT_BASE_DIR}")"
chmod go-w "${JAILER_PARENT_DIR}" ||
  fail "Could not strip group/world write from ${JAILER_PARENT_DIR}."

# ------------------------------------------------------------
# 3. Download pinned release of firecracker and jailer
# ------------------------------------------------------------

echo "3. Download firecracker and jailer ${FC_VERSION}"

# Create a temporary directory
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Fetch tarball
FC_TARBALL="firecracker-${FC_VERSION}-${CPU_ARCH}.tgz"
FC_URL="https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/${FC_TARBALL}"

wget --quiet --show-progress -O "${TMP_DIR}/${FC_TARBALL}" "${FC_URL}"

# Extract tarball
tar -xzf "${TMP_DIR}/${FC_TARBALL}" -C "${TMP_DIR}"

# ------------------------------------------------------------
# 4. Install firecracker and jailer
# ------------------------------------------------------------

echo "4. Install firecracker and jailer"

install -m 0755 -o root -g root \
  "${TMP_DIR}/release-${FC_VERSION}-${CPU_ARCH}/firecracker-${FC_VERSION}-${CPU_ARCH}" \
  "${FC_BIN_DIR}/firecracker"

install -m 0755 -o root -g root \
  "${TMP_DIR}/release-${FC_VERSION}-${CPU_ARCH}/jailer-${FC_VERSION}-${CPU_ARCH}" \
  "${FC_BIN_DIR}/jailer"
