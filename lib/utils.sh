#!/usr/bin/env bash

fail() {
  printf '\nERROR: %s\n' "$1" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] ||
    fail "This script must be run as root."
}
