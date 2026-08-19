#!/usr/bin/env bash
# The downstream first-run failure, reproduced exactly: the helpers cannot be
# sourced, so every assertion is `command not found`, nothing prints RESULT=,
# and `set -u` kills the script on the helper's own counter variable.
#
# `set -e` is deliberately absent, as it was downstream — the failing `.` would
# otherwise end the script early and hide the `command not found` cascade that
# made the real log so confusing.
set -uo pipefail
. "$(dirname "$0")/lib/assert-that-was-never-copied.sh"
assert something true
vmkit_result "unreachable"
echo "fails=$VMKIT_FAILS"
