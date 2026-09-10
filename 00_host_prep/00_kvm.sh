#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

require_root

# ------------------------------------------------------------
# 1. Verify KVM support and access
# ------------------------------------------------------------

echo "1. Verify KVM support and access"

[[ -c /dev/kvm ]] ||
  fail "/dev/kvm not found. Check BIOS virtualization and the KVM module."

grep -qE '^kvm_(intel|amd)\b' /proc/modules ||
  fail "No kvm_intel/kvm_amd module loaded."

# ------------------------------------------------------------
# 2. Set KVM permissions
# ------------------------------------------------------------

echo "2. Set KVM permissions"

chown root:kvm /dev/kvm
chmod 660 /dev/kvm

KVM_PERMS="$(stat -c '%U:%G %a' /dev/kvm)"
[[ "${KVM_PERMS}" == "root:kvm 660" ]] ||
  fail "/dev/kvm expected to be root:kvm with 660 permissions."
