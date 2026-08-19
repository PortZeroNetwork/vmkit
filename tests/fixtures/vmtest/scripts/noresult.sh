#!/usr/bin/env bash
# Exits non-zero having printed phases but never a RESULT= line.
# Before the verdict gate this was reported as PASS.
set -euo pipefail
echo "PHASE=started ok=true"
echo "PHASE=partway ok=true"
exit 1
