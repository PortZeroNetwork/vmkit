#!/usr/bin/env bash
# vmkit flavor script (linux + macOS guests). Say here what this leg PROVES.
#
# The helpers live in lib/ INSIDE this directory, and that is load-bearing:
# vmkit pushes this script's own directory into the guest and nothing above it,
# so "$(dirname "$0")/lib/assert.sh" works and "$(dirname "$0")/../lib/..."
# does not -- it resolves on the host and is absent in the guest.
#
# Protocol: print "PHASE=<name> ok=true|false|SKIP" lines, end with
# vmkit_result. A script that ends without printing RESULT= is reported as
# NO-RESULT, never as a pass.
set -euo pipefail

lib="$(dirname "$0")/lib/assert.sh"
# Defend in depth: say so in the protocol's own language rather than dying with
# a cascade of "command not found".
if [ ! -f "$lib" ]; then
    echo "RESULT=FAIL the assertion helpers were not pushed with this script ($lib)"
    exit 1
fi
. "$lib"

assert guest-is-alive true
assert_not nothing-impossible false

vmkit_result "smoke"
