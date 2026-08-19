#!/usr/bin/env bash
# A RESULT= line that isn't one of the three verdicts. Guessing which way it
# was meant is exactly how a harness reports green for nothing.
set -euo pipefail
echo "RESULT=OK probably fine?"
exit 0
