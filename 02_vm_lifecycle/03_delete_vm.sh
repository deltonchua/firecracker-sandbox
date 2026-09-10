#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/variables.sh"

require_root

# ------------------------------------------------------------
# 1. Remove VM group and user
# ------------------------------------------------------------

echo "1. Remove ${VM_ID} group and user"

userdel "${VM_USER_NAME}"
# groupdel "${VM_GROUP_NAME}"

# ------------------------------------------------------------
# 2. Remove vm directories
# ------------------------------------------------------------

echo "2. Remove vm directories"

rm -rf "${VM_DIR}"
rm -rf "${JAILER_CHROOT_BASE_DIR}/${JAILER_EXEC_NAME}/${VM_ID}"
