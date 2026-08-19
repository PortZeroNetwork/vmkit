#!/usr/bin/env bash
# Sources a helper from a SIBLING directory (../shared), which resolves on the
# host and is absent in a macOS guest: vmkit pushes the script's own directory
# and nothing above it. The mistake that produced a green leg downstream.
set -uo pipefail
. "$(dirname "$0")/../shared/assert.sh"
assert something true
vmkit_result "unreachable in a real guest"
