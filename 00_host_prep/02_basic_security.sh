#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"

require_root

# ------------------------------------------------------------
# 1. Check swap status
# ------------------------------------------------------------

echo "1. Check swap status"

if swapon --show | grep -q .; then
  fail "Swap is enabled. To disable, run 'sudo swapoff -a'."
fi

# ------------------------------------------------------------
# 2. Disable KSM
# ------------------------------------------------------------

echo "2. Disable KSM"

if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 0 >/sys/kernel/mm/ksm/run || fail "Could not disable KSM."
else
  step "KSM not present on this kernel, skipping."
fi

# Other security measures, e.g., SMT-disable and microcode updates are
# intentionally left out of this script;
# do them deliberately where appropriate.
# See https://github.com/firecracker-microvm/firecracker/blob/main/docs/prod-host-setup.md
# for more info.
