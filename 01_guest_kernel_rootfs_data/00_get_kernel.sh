#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 1. Download kernel from firecracker CI
# ------------------------------------------------------------

echo "1. Download kernel from firecracker CI"

S3="https://s3.amazonaws.com/spec.ccfc.min"

# Find the latest Firecracker CI artifact.
CI_ARTIFACTS_PREFIX="$(
  curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" |
    grep -oP '(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)' |
    sort |
    tail -1
)"

[[ -n "$CI_ARTIFACTS_PREFIX" ]] || fail "No firecracker-ci artifact prefix found."

# Find the latest KERNEL_VERSION kernel within that artifact.
KERNEL_KEY="$(
  curl -fsSL \
    "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${CPU_ARCH}/vmlinux-${KERNEL_VERSION}" |
    grep -oP "(?<=<Key>)${CI_ARTIFACTS_PREFIX}${CPU_ARCH}/vmlinux-${KERNEL_VERSION}\.[0-9]{1,3}(?=</Key>)" |
    sort -V |
    tail -1
)"

[[ -n "$KERNEL_KEY" ]] || fail "Could not find Linux $KERNEL_VERSION kernel for $CPU_ARCH."

KERNEL_OUT="${FC_IMAGES_DIR}/$(basename "$KERNEL_KEY")"

wget --quiet --show-progress -O "$KERNEL_OUT" "$S3/$KERNEL_KEY"

chmod 0644 "${KERNEL_OUT}"

echo "Kernel saved: ${KERNEL_OUT}"
