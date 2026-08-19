#!/usr/bin/env bash
# An honest failure: the script ran and reported it.
set -euo pipefail
. "$(dirname "$0")/lib/assert.sh"
assert this-one-fails false
vmkit_result "expected failure fixture"
