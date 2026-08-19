#!/usr/bin/env bash
# Every file vmkit ships FOR COPYING INTO A GUEST must be ASCII.
#
# Windows PowerShell 5.1 reads a UTF-8 file with no BOM as CP1252, so an em
# dash (E2 80 94) arrives as three characters ending in U+201D -- a smart quote
# PowerShell honours as a string delimiter. One of them inside a double-quoted
# string ends it early, the rest of the file parses as code, and the parser
# reports `Missing closing '}'` on a line whose braces are balanced. That cost
# a downstream integration its first Windows run (docs/FAILURES.md #24).
#
# The rule is per-directory rather than per-extension on purpose: "only in
# strings, only in .ps1" is not a rule anyone applies reliably while writing
# prose in a comment, and these are the files everyone copies.
#
# The alternative fix -- writing .ps1 with a UTF-8 BOM -- was rejected: a BOM
# is invisible, an editor or a `sed` drops it silently, and the constraint then
# depends on a byte nobody can see.
#
# vmkit runs this over its own guest-lib/ and scaffold. `vmkit check-scripts`
# applies the same rule to a consuming repo's flavor scripts.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
for dir in guest-lib templates/scaffold; do
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if LC_ALL=C grep -qn '[^ -~	]' "$f"; then
            echo "::error file=$f::non-ASCII character in a file that is copied into guests"
            LC_ALL=C grep -n '[^ -~	]' "$f" | sed 's/^/    /'
            status=1
        fi
    done < <(find "$dir" -type f)
done
[ "$status" -eq 0 ] && echo "guest-lib + scaffold: ASCII-only"
exit "$status"
