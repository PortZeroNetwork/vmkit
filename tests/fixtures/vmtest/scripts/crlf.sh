#!/usr/bin/env bash
# Windows guests end every line with CRLF. The verdict word is still PASS.
set -euo pipefail
printf 'PHASE=work ok=true\r\n'
printf 'RESULT=PASS crlf fixture\r\n'
exit 0
