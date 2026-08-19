#!/usr/bin/env bash
# The control case: a well-formed flavor script. If this one ever stops
# reporting PASS, the broken-script cases below prove nothing.
set -euo pipefail
. "$(dirname "$0")/lib/assert.sh"
assert reachable true
assert_not absent false
vmkit_result "control fixture"
