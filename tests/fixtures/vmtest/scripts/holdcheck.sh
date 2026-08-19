#!/usr/bin/env bash
# Asserts, from inside the "guest", that vmkit is holding the host WHILE the
# guest script runs — the window issue #11 is about. Only possible because the
# fake guest is the host: a real guest cannot see $VMKIT_STATE_DIR.
set -euo pipefail
. "$(dirname "$0")/lib/assert.sh"
assert host-is-held test -f "${VMKIT_STATE_DIR:-/nonexistent}/hold"
vmkit_result "hold visible during the run"
