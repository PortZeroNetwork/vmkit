# shellcheck shell=bash
# vmkit guest-side assertion helpers (bash; linux + macos guests).
#
# Copy this file into a lib/ directory INSIDE your flavor script's own
# directory (guests can't reach the host's vmkit install) and source it:
#     . "$(dirname "$0")/lib/assert.sh"
#
# `vmkit init` scaffolds exactly that layout, and it is not a preference:
# vmkit pushes the flavor script's OWN directory into the guest and nothing
# above it, so a sibling ../lib resolves on the host and is absent in the
# guest. See docs/CAPABILITIES.md, "All guests".
#
# Protocol: print greppable "PHASE=<name> ok=true|false|SKIP" lines as you go,
# end with vmkit_result. The host-side series runner surfaces these verbatim.
# A script that ends WITHOUT a RESULT= line is reported as NO-RESULT, never as
# a pass -- so reaching vmkit_result is itself part of what a leg proves.
#
# Helper predicates are usually invoked indirectly via assert/assert_not;
# silence the resulting spurious shellcheck SC2317 "unreachable" info in your
# script with: # shellcheck disable=SC2317

VMKIT_FAILS=0

# assert <phase> <cmd...>: PHASE ok=true if the command succeeds.
assert() {
    local phase="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "PHASE=$phase ok=true"
    else echo "PHASE=$phase ok=false"; VMKIT_FAILS=$((VMKIT_FAILS + 1)); fi
}

# assert_not <phase> <cmd...>: PHASE ok=true if the command FAILS (absence checks).
assert_not() {
    local phase="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "PHASE=$phase ok=false"; VMKIT_FAILS=$((VMKIT_FAILS + 1))
    else echo "PHASE=$phase ok=true"; fi
}

# assert_or_skip <phase> <reason> <cmd...>: never counts as a failure -- ok=true
# when the predicate holds, else ok=SKIP with the reason. Reserve for RUNTIME
# states a headless guest genuinely cannot establish (see docs/CAPABILITIES.md:
# e.g. macOS System-keychain trust settings and `launchctl bootstrap system`
# both fail under headless prlctl exec) -- and make sure some OTHER test covers
# the skipped behavior for real.
assert_or_skip() {
    local phase="$1" reason="$2"; shift 2
    if "$@" >/dev/null 2>&1; then echo "PHASE=$phase ok=true"
    else echo "PHASE=$phase ok=SKIP reason=\"$reason\""; fi
}

# vmkit_result <description>: prints RESULT=PASS/FAIL and exits accordingly.
vmkit_result() {
    if [ "$VMKIT_FAILS" -eq 0 ]; then
        echo "RESULT=PASS ${1:-}"
        exit 0
    fi
    echo "RESULT=FAIL ${1:-} assertions failed=$VMKIT_FAILS"
    exit 1
}

# vmkit_skip <reason>: whole-script SKIP (e.g. a prerequisite artifact is
# unavailable). SKIP exits 0 -- never a false failure -- but always says why.
vmkit_skip() {
    echo "RESULT=SKIP ${1:-}"
    exit 0
}
