#!/usr/bin/env bash
# vmkit's self-test.
#
# WHY THIS EXISTS
# vmkit reported `PASS (40s)` for a leg in which every assertion was
# `command not found` (docs/FAILURES.md #22). A guard that cannot fail is not a
# guard, so the fix ships with fixtures that are deliberately broken in each of
# the ways that used to go green, and this asserts the verdict for every one.
#
# It runs anywhere: `prlctl` is a fake (tests/fake-bin/prlctl) whose `exec`
# runs the guest script on the host with guest paths translated. That makes the
# script's exit status, its missing helper and its missing RESULT= line REAL,
# which is what the verdict gate reads.
#
# WHAT IT CANNOT COVER, and why (these need a real guest, ~40s each):
#   - `prlctl exec` returning 0 for a guest whose interpreter died. The silent
#     fixture models the OUTPUT (none) but a fake cannot lie about exit status
#     the way Parallels does. NO-OUTPUT is asserted; the 0-status half is not.
#   - The macOS shared folder's TCC refusal, SYSTEM identity on Windows,
#     revert-collapse, and any PowerShell behaviour at all.
#   - Whether a hold survives a real 40-minute provision (the TTL arithmetic is
#     asserted; the wall clock is not).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
vmkit="$repo/bin/vmkit"

pass=0; fail=0; skipped=0
failed_names=()

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); failed_names+=("$1"); }
skip() { printf '  \033[33mskip\033[0m %s (%s)\n' "$1" "$2"; skipped=$((skipped+1)); }

# --- one sandboxed vmkit host ------------------------------------------------
# The fixture repo has to live under $HOME: the Parallels share maps host $HOME
# into the guest, and guest_repo refuses anything outside it.
WORK=""
setup() {
    WORK="$(mktemp -d "$HOME/.vmkit-selftest.XXXXXX")"
    cp -R "$here/fixtures/." "$WORK/"
    mkdir -p "$WORK/.state" "$WORK/.fake/vms/linuxvm" "$WORK/.fake/vms/macosvm" "$WORK/.fake/vms/othervm"
    local n=1
    for vm in linuxvm macosvm othervm; do
        echo stopped > "$WORK/.fake/vms/$vm/state"
        # The id must be hex: snap_id_by_name greps `\{[0-9a-f-]+\}` out of the
        # snapshot listing, so a non-hex placeholder is silently invisible.
        printf '{aaaa111%s-0000-0000-0000-000000000000} vmkit-built\n' "$n" \
            > "$WORK/.fake/vms/$vm/snapshots"
        n=$((n+1))
    done
    cat > "$WORK/host.conf" <<EOF
VMKIT_ARCH=$(uname -m)
VMKIT_INTERNAL_DIR="$WORK"
VMKIT_SNAP_PREFIX="vmkit"
VMKIT_VM_LINUX="linuxvm"
VMKIT_VM_MACOS="macosvm"
EOF
}
teardown() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap teardown EXIT

# Run vmkit against the sandbox. Everything that could touch the real machine
# — the hold state dir, the VM inventory, prlctl itself — is redirected here.
run_vmkit() { # <args...>  -> prints combined output, returns vmkit's status
    (
        cd "$WORK" || exit 99
        PATH="$here/fake-bin:$PATH" \
        VMKIT_HOST_CONF="$WORK/host.conf" \
        VMKIT_STATE_DIR="$WORK/.state" \
        VMKIT_FAKE_ROOT="$WORK/.fake" \
        VMKIT_MEM_HEADROOM_MB=0 \
        VMKIT_HOST_SNAPSHOT=0 \
        VMKIT_STOP_TIMEOUT=5 \
        "$vmkit" "$@" 2>&1
    )
}

# assert_run <name> <expect-rc> <expect-substring> -- <vmkit args...>
assert_run() {
    local name="$1" want_rc="$2" want_txt="$3"; shift 4   # the 4th is the literal --
    local out rc=0
    out="$(run_vmkit "$@")" || rc=$?
    if [ "$rc" != "$want_rc" ]; then
        bad "$name" "expected exit $want_rc, got $rc$(printf '\n     ---\n%s' "$out" | sed 's/^/     /')"
        return
    fi
    if ! printf '%s' "$out" | grep -qF "$want_txt"; then
        bad "$name" "output did not contain: $want_txt$(printf '\n     ---\n%s' "$out" | sed 's/^/     /')"
        return
    fi
    ok "$name"
}

echo
echo "== #7  the verdict gate: a leg that did nothing must not report PASS =="
setup
assert_run "control: a well-formed script reports PASS" \
    0 "linux (good): PASS" -- test linux good
assert_run "no RESULT= line, exit 1 -> NO-RESULT" \
    125 "linux (noresult): NO-RESULT" -- test linux noresult
assert_run "no RESULT= line names the missing-helper cause" \
    125 "could not source its helpers" -- test linux noresult
assert_run "cannot source its lib -> NO-RESULT, not PASS" \
    125 "linux (missinglib): NO-RESULT" -- test linux missinglib
assert_run "RESULT=PASS then exit 1 -> FAIL" \
    1 "linux (passthenexit1): FAIL" -- test linux passthenexit1
assert_run "RESULT=PASS then exit 1 says the script did not finish" \
    1 "and then exited 1" -- test linux passthenexit1
assert_run "no output at all -> NO-OUTPUT" \
    125 "linux (silent): NO-OUTPUT" -- test linux silent
assert_run "an unrecognized verdict is not a pass" \
    1 "unrecognized verdict" -- test linux badverdict
assert_run "RESULT=FAIL -> FAIL" \
    1 "linux (resultfail): FAIL" -- test linux resultfail
assert_run "RESULT=SKIP -> SKIP, and exit 0" \
    0 "linux (skipflavor): SKIP" -- test linux skipflavor
assert_run "CRLF line endings still parse as PASS" \
    0 "linux (crlf): PASS" -- test linux crlf
# A guest that never reached the script has no verdict to report, and saying
# FAIL would send the reader looking at assertions that never ran.
: > "$WORK/.fake/vms/linuxvm/snapshots"
assert_run "a guest that never reached the script reports SETUP-FAILED" \
    1 "linux (good): SETUP-FAILED" -- test linux good
teardown

# run_guarded's timers must let go of the output stream when the guest command
# finishes. While they did not, teeing the guest's output (which reading
# RESULT= requires, and which cmd_provision already did) made every run sit
# silent for the REST of its timeout after the script had finished.
setup
started="$(date +%s)"
run_vmkit test linux good >/dev/null 2>&1 || true
elapsed=$(( $(date +%s) - started ))
if [ "$elapsed" -lt 15 ]; then
    ok "a finished run returns immediately, not at the end of its timeout (${elapsed}s)"
else
    bad "a finished run returns immediately, not at the end of its timeout" \
        "took ${elapsed}s against a 30s flavor timeout — run_guarded is holding the pipe"
fi
teardown

echo
echo "== regressions: one VM at a time (FAILURES.md #4) =="
setup
echo running > "$WORK/.fake/vms/othervm/state"
assert_run "a run still stops the other running VM" \
    0 "stopping other running VM: othervm" -- test linux good
if [ "$(cat "$WORK/.fake/vms/othervm/state")" = stopped ]; then
    ok "the sibling VM is actually stopped"
else
    bad "the sibling VM is actually stopped" "state is $(cat "$WORK/.fake/vms/othervm/state")"
fi
teardown

echo
echo "== #7  the escape hatch still honours the exit status =="
setup
out="$(cd "$WORK" && PATH="$here/fake-bin:$PATH" VMKIT_HOST_CONF="$WORK/host.conf" \
    VMKIT_STATE_DIR="$WORK/.state" VMKIT_FAKE_ROOT="$WORK/.fake" \
    VMKIT_MEM_HEADROOM_MB=0 VMKIT_HOST_SNAPSHOT=0 VMKIT_REQUIRE_RESULT=0 \
    "$vmkit" test linux noresult 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "linux (noresult): FAIL"; then
    ok "VMKIT_REQUIRE_RESULT=0 drops the RESULT check but not the exit status"
else
    bad "VMKIT_REQUIRE_RESULT=0 drops the RESULT check but not the exit status" "exit $rc: $out"
fi
teardown

echo
echo "== #8  only the script's own directory reaches a macOS guest =="
if [ "$(uname -s)" != Darwin ]; then
    skip "sibling ../shared is absent in the guest" "macOS push uses BSD tar flags; host is $(uname -s)"
    skip "a silent macOS guest is still NO-OUTPUT" "macOS push uses BSD tar flags; host is $(uname -s)"
    skip "the script's own lib/ does arrive" "macOS push uses BSD tar flags; host is $(uname -s)"
else
    setup
    assert_run "sibling ../shared is absent in the guest -> NO-RESULT" \
        125 "macos (siblinglib): NO-RESULT" -- test macos siblinglib
    # vmkit's own push chatter shares the captured stream on macOS; it must not
    # be mistaken for the guest having said something.
    assert_run "a silent macOS guest is still NO-OUTPUT, not NO-RESULT" \
        125 "macos (silent): NO-OUTPUT" -- test macos silent
    if [ -f "$WORK/.fake/guest/tmp/vmkitselftest-vmkit/vmtest/scripts/lib/assert.sh" ] \
       && [ ! -e "$WORK/.fake/guest/tmp/vmkitselftest-vmkit/vmtest/shared" ]; then
        ok "the script's own lib/ arrives and its sibling ../shared does not"
    else
        bad "the script's own lib/ arrives and its sibling ../shared does not" \
            "$(find "$WORK/.fake/guest" -maxdepth 6 2>/dev/null | sed 's|.*/guest||')"
    fi
    teardown
fi

echo
echo "== #9/#8 a script the guest cannot parse is refused before any VM boots =="
setup
assert_run "a .ps1 with a non-ASCII character is refused" \
    1 "contains non-ASCII characters" -- check-scripts badascii
assert_run "...and the refusal names the CP1252 cause, not a brace" \
    1 "reads UTF-8 without a BOM as CP1252" -- check-scripts badascii
assert_run "a .sh that does not parse is refused" \
    1 "is not valid bash" -- check-scripts badsyntax
assert_run "sourcing a sibling ../ directory is warned about" \
    0 "sources a path above its own directory" -- check-scripts siblingsource
assert_run "well-formed scripts pass the check" \
    0 "all parseable" -- check-scripts good
assert_run "a broken script is refused by 'vmkit test' too" \
    1 "is not valid bash" -- test linux badsyntax
if ! grep -qE '^(snapshot-switch|start|exec) ' "$WORK/.fake/calls.log" 2>/dev/null; then
    ok "the refusal happened before the VM was touched"
else
    bad "the refusal happened before the VM was touched" "$(cat "$WORK/.fake/calls.log")"
fi
teardown

echo
echo "== #11 the host hold is taken by the run, not by the caller =="
setup
assert_run "a run holds the host for the duration of the guest script" \
    0 "linux (holdcheck): PASS" -- test linux holdcheck
if [ ! -e "$WORK/.state/hold" ]; then
    ok "the self-hold is released when the run finishes"
else
    bad "the self-hold is released when the run finishes" "$(cat "$WORK/.state/hold")"
fi
# A failing run must release too, or one red leg wedges the host until the TTL.
run_vmkit test linux resultfail >/dev/null 2>&1 || true
if [ ! -e "$WORK/.state/hold" ]; then
    ok "the self-hold is released when the run FAILS"
else
    bad "the self-hold is released when the run FAILS" "$(cat "$WORK/.state/hold")"
fi
teardown

setup
# Someone else's hold: the refusal wording and the non-zero exit are both part
# of the contract downstream CI relies on (FAILURES.md #4).
mkdir -p "$WORK/.state"
cat > "$WORK/.state/hold" <<EOF
VMKIT_HOLD_REASON=a human is using the guest
VMKIT_HOLD_VM=
VMKIT_HOLD_TOKEN=not-our-token
VMKIT_HOLD_USER=someone
VMKIT_HOLD_PID=1
VMKIT_HOLD_ACQUIRED=$(date +%s)
VMKIT_HOLD_EXPIRES=$(( $(date +%s) + 3600 ))
EOF
assert_run "a held host refuses a test before touching a VM" \
    1 "the VM host is HELD by another session" -- test linux good
if grep -q 'not-our-token' "$WORK/.state/hold" 2>/dev/null; then
    ok "a refused run leaves the other session's hold intact"
else
    bad "a refused run leaves the other session's hold intact" "hold file was modified or removed"
fi
if ! grep -q '^stop ' "$WORK/.fake/calls.log" 2>/dev/null; then
    ok "a refused run never stopped a VM"
else
    bad "a refused run never stopped a VM" "$(grep '^stop ' "$WORK/.fake/calls.log")"
fi
teardown

setup
mkdir -p "$WORK/.state"
cat > "$WORK/.state/hold" <<EOF
VMKIT_HOLD_REASON=stale
VMKIT_HOLD_TOKEN=not-our-token
VMKIT_HOLD_USER=someone
VMKIT_HOLD_PID=1
VMKIT_HOLD_ACQUIRED=$(( $(date +%s) - 7200 ))
VMKIT_HOLD_EXPIRES=$(( $(date +%s) - 60 ))
EOF
assert_run "an EXPIRED hold does not block a run" \
    0 "linux (good): PASS" -- test linux good
teardown

setup
out="$(cd "$WORK" && PATH="$here/fake-bin:$PATH" VMKIT_HOST_CONF="$WORK/host.conf" \
    VMKIT_STATE_DIR="$WORK/.state" VMKIT_FAKE_ROOT="$WORK/.fake" \
    VMKIT_MEM_HEADROOM_MB=0 VMKIT_HOST_SNAPSHOT=0 VMKIT_NO_SELF_HOLD=1 \
    "$vmkit" test linux holdcheck 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "PHASE=host-is-held ok=false"; then
    ok "VMKIT_NO_SELF_HOLD=1 restores the unheld behaviour"
else
    bad "VMKIT_NO_SELF_HOLD=1 restores the unheld behaviour" "exit $rc: $out"
fi
teardown

echo
echo "== #11 hold primitives =="
setup
# Two invocations racing for an unheld host: `ln` is atomic, so exactly one wins.
probe="$WORK/probe.sh"
cat > "$probe" <<EOF
VMKIT_STATE_DIR="$WORK/.state"
. "$repo/lib/hold.sh"
hold_acquire "first" "" 600 0 >/dev/null && echo FIRST-OK || echo FIRST-FAIL
hold_acquire "second" "" 600 0 >/dev/null && echo SECOND-OK || echo SECOND-FAIL
EOF
got="$(bash "$probe" 2>&1 | tr '\n' ' ')"
if [ "$got" = "FIRST-OK SECOND-FAIL " ]; then
    ok "hold_acquire refuses a second holder (atomic create)"
else
    bad "hold_acquire refuses a second holder (atomic create)" "got: $got"
fi
rm -f "$WORK/.state/hold"

# The TTL a caller would otherwise have to guess at.
ttl="$(bash -c ". '$repo/lib/hold.sh'; self_hold_ttl 360")"
if [ "$ttl" = "$(( 360 + 900 ))" ]; then
    ok "self_hold_ttl adds the boot/stop/settle margin to the flavor timeout"
else
    bad "self_hold_ttl adds the boot/stop/settle margin to the flavor timeout" "got $ttl"
fi
ttl="$(bash -c ". '$repo/lib/hold.sh'; self_hold_ttl 99999")"
if [ "$ttl" = 14400 ]; then
    ok "self_hold_ttl caps at VMKIT_SELF_HOLD_MAX so a killed run cannot wedge the host"
else
    bad "self_hold_ttl caps at VMKIT_SELF_HOLD_MAX so a killed run cannot wedge the host" "got $ttl"
fi
teardown

echo
echo "== regressions: FAILURES.md #18 (a typo'd flag must not claim the host) =="
setup
assert_run "'vmkit hold --list' reports instead of acquiring" \
    0 "no active hold" -- hold --list
assert_run "'vmkit hold --bogus' is refused, not treated as reason text" \
    2 "unknown option" -- hold --bogus
if [ ! -e "$WORK/.state/hold" ]; then
    ok "neither typo left a hold behind"
else
    bad "neither typo left a hold behind" "$(cat "$WORK/.state/hold")"
fi
teardown

echo
echo "== #9  guest-lib must be ASCII: PowerShell 5.1 reads UTF-8-without-BOM as CP1252 =="
bad_files=""
for f in "$repo"/guest-lib/*; do
    if LC_ALL=C grep -qn '[^ -~	]' "$f" 2>/dev/null; then
        bad_files="$bad_files $(basename "$f")"
    fi
done
if [ -z "$bad_files" ]; then
    ok "every file in guest-lib/ is ASCII-only"
else
    bad "every file in guest-lib/ is ASCII-only" "non-ASCII in:$bad_files"
fi

echo
printf '%s\n' "-----"
printf 'ok %d, failed %d, skipped %d\n' "$pass" "$fail" "$skipped"
if [ "$fail" -gt 0 ]; then
    printf 'failed:\n'
    for n in "${failed_names[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
