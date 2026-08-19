#!/usr/bin/env bash
# Says it passed, then dies on the way out. The sentinel must not outrank a
# non-zero exit: everything after the last PHASE= line did not happen.
set -uo pipefail
echo "PHASE=work ok=true"
echo "RESULT=PASS but the teardown is about to fail"
exit 1
