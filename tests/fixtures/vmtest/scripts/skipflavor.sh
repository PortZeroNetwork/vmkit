#!/usr/bin/env bash
# A whole-script SKIP: not a pass, not a failure, and it says why.
set -euo pipefail
. "$(dirname "$0")/lib/assert.sh"
vmkit_skip "fixture declines on purpose"
