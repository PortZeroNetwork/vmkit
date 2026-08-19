# shellcheck shell=bash
# vmkit testing: run repo scripts in guests with env/artifact plumbing, run
# flavors, run platform series with a summary.

# Forward selected host env vars into the guest. Repo config lists them in
# VMKIT_ENV_FORWARD (space-separated). Returns KEY=VALUE lines for the set ones.
forwarded_env() {
    local var
    for var in ${VMKIT_ENV_FORWARD:-}; do
        [ -n "${!var:-}" ] && printf '%s=%s\n' "$var" "${!var}"
    done
    true
}

# Artifact auto-discovery: when $VMKIT_ARTIFACT_ENV is not already set in the
# host env, look for a per-platform artifact (CI-downloaded or host-built) and
# hand its guest-visible path to the test via that env var.
#   VMKIT_ARTIFACT_ENV       env var name the guest test reads (e.g. PORTZERO_EXE)
#   VMKIT_ARTIFACT_WINDOWS   repo-relative path (guest sees it via the share)
#   VMKIT_ARTIFACT_LINUX     repo-relative path (guest sees it via the share)
#   VMKIT_ARTIFACT_MACOS     repo-relative path; prefer the Parallels share when
#                            TCC allows it, otherwise tar.gz-push into the guest
#                            (base64-over-heredoc was retired — too slow/silent)

# Host-side path of the auto-discovered artifact for <vm>, or nothing when
# there is none to discover (no VMKIT_ARTIFACT_ENV, caller set it explicitly,
# no per-OS path configured, or the file isn't staged). Split out of
# artifact_env_for so the arch check below can run BEFORE anything is pushed —
# artifact_env_for is consumed through `< <(...)`, where a non-zero return is
# swallowed, so it can't refuse an artifact on its own.
artifact_host_path_for() { # <vm>  — prints host path or nothing
    local vm="$1" aenv="${VMKIT_ARTIFACT_ENV:-}"
    [ -z "$aenv" ] && return 0
    [ -n "${!aenv:-}" ] && return 0          # explicit env wins
    local os key rel
    os="$(vm_os "$vm")"
    key="VMKIT_ARTIFACT_$(echo "$os" | tr '[:lower:]' '[:upper:]')"
    rel="${!key:-}"
    [ -z "$rel" ] && return 0
    local host_path="$VMKIT_REPO_ROOT/$rel"
    [ -e "$host_path" ] || return 0
    printf '%s\n' "$host_path"
}

# Refuse an artifact the guest cannot execute, before pushing 16 MB of it and
# watching every assertion fail for reasons that never mention architecture.
#
# The artifact is built wherever CI felt like building it; the guest's arch is
# a property of the Mac hosting Parallels. Those used to coincide (the builder
# WAS the host) and no longer have to — a CI change that moves a macOS build
# to a GitHub-hosted (Apple Silicon) runner produces an arm64 binary that
# cannot exec in an x86_64 guest on an Intel host. Every phase then reports a
# bare `ok=false`; nothing anywhere prints "bad CPU type".
#
# macOS guests only: `lipo -archs` names architectures exactly as `uname -m`
# does, so the comparison is trustworthy. ELF/PE naming diverges from uname
# (x86-64, aarch64, ...) and would need a translation table to be more than
# guesswork, so linux/windows guests are deliberately not covered here.
assert_artifact_runnable() { # <vm> <host-path>  — 0 = ok/unknown, 1 = mismatch
    local vm="$1" host_path="$2" bin_archs guest_arch
    [ "$(vm_os "$vm")" = macos ] || return 0
    command -v lipo >/dev/null 2>&1 || return 0
    # Non-Mach-O (a script, a tarball) — nothing to compare, not an error.
    bin_archs="$(lipo -archs "$host_path" 2>/dev/null)" || return 0
    [ -z "$bin_archs" ] && return 0
    # Ask the guest rather than assuming it matches the host: it's one cheap
    # exec, and the guest is already up (ensure_running ran first).
    guest_arch="$(prlctl exec "$vm" uname -m 2>/dev/null | tr -d '\r' | tail -n1)"
    [ -z "$guest_arch" ] && return 0         # can't tell; let the test proceed
    case " $bin_archs " in
        *" $guest_arch "*) return 0 ;;
    esac
    echo "vmkit: artifact cannot run in guest '$vm'" >&2
    echo "  $host_path" >&2
    echo "  built for: $bin_archs" >&2
    echo "  guest is:  $guest_arch" >&2
    echo "  Build this artifact for ${guest_arch}-apple-darwin (or a universal binary)." >&2
    return 1
}

artifact_env_for() { # <vm>  — prints KEY=guestpath or nothing
    local vm="$1" os aenv="${VMKIT_ARTIFACT_ENV:-}"
    local host_path
    host_path="$(artifact_host_path_for "$vm")"
    [ -z "$host_path" ] && return 0
    os="$(vm_os "$vm")"
    local rel="${host_path#"$VMKIT_REPO_ROOT"/}"
    if [ "$os" = macos ]; then
        local share_path
        if share_path="$(macos_guest_path_via_share "$vm" "$host_path")"; then
            echo ">> using artifact via macOS shared folder as $aenv: $rel" >&2
            printf '%s=%s\n' "$aenv" "$share_path"
        else
            # Share is typically mounted-but-TCC-blocked under headless exec;
            # tar.gz-push with keepalive is the reliable path (see transport.sh).
            echo ">> pushing host artifact into the guest (macOS shared folder unusable under headless TCC)..." >&2
            printf '%s=%s\n' "$aenv" "$(push_file_macos "$vm" "$host_path" "$VMKIT_GUEST_DIR/bin/$(basename "$host_path")" +x)"
        fi
    else
        echo ">> using artifact as $aenv: $rel" >&2
        printf '%s=%s\n' "$aenv" "$(guest_path_under_repo "$vm" "$host_path")"
    fi
}

# Optional secrets push for macOS (windows/linux guests read secrets off their
# own share paths; macOS needs a push). Declarative:
#   VMKIT_SECRETS_ENV           env var the guest test reads (e.g. STAGING_SECRETS)
#   VMKIT_SECRETS_HOST_DEFAULT  host path pushed when the env var is unset
secrets_env_for_macos() { # <vm>  — prints KEY=guestpath or nothing
    local vm="$1" senv="${VMKIT_SECRETS_ENV:-}"
    [ -z "$senv" ] && return 0
    [ -n "${!senv:-}" ] && return 0
    local def="${VMKIT_SECRETS_HOST_DEFAULT:-}"
    { [ -z "$def" ] || [ ! -f "$def" ]; } && return 0
    printf '%s=%s\n' "$senv" "$(push_file_macos "$vm" "$def" "$VMKIT_GUEST_DIR/$(basename "$def")")"
}

# --- the guest verdict ------------------------------------------------------
# The flavor protocol says a guest script ends with `RESULT=PASS|FAIL|SKIP`.
# Reading that line — and the guest's exit status — is the whole difference
# between a test harness and a stopwatch.
#
# Until 0.4.6 the verdict was `prlctl exec`'s exit status and nothing else, so
# a script that could not source its helpers (every assertion `command not
# found`, no RESULT line, dead under `set -u`) was reported as `PASS (40s)`.
# Both available signals were thrown away; see docs/FAILURES.md #22.
#
# The outcomes are deliberately more than PASS/FAIL, because the first
# debugging step differs:
#
#   PASS       RESULT=PASS and the guest exited 0.
#   SKIP       RESULT=SKIP and the guest exited 0 — the script declined, loudly.
#   FAIL       RESULT=FAIL, or a non-zero exit: the script RAN and reported
#              something. Read its PHASE= lines.
#   NO-RESULT  no RESULT= line at all. The script never reached vmkit_result,
#              so whatever phases it did print prove nothing. Look at where its
#              output STOPS — most often a helper it could not source, because
#              only the script's own directory is pushed into the guest
#              (FAILURES.md #23).
#   NO-OUTPUT  ...and it printed nothing whatsoever: an interpreter that died
#              before the first statement, which still yields exit 0 through
#              `prlctl exec`.
#   TIMEOUT    run_guarded hit VMKIT_RUN_TIMEOUT (124); it has already said so.
#
# Set by guest_result_gate, read by cmd_test/cmd_series for their report lines.
VMKIT_RUN_OUTCOME=""

# Exit status for "the script never said anything". Distinct from 1 (the script
# reported a failure) and from 124 (timeout), so a caller — or a human reading
# a CI log — can tell "asserted a failure" from "never got that far" without
# re-reading the output.
VMKIT_RC_NO_RESULT=125

# Decide the outcome of one guest run. Returns the exit status cmd_run should
# return; the human-readable outcome lands in VMKIT_RUN_OUTCOME.
guest_result_gate() { # <vm> <script> <output-file> <guest-rc>
    local vm="$1" script="$2" out="$3" rc="$4"
    local line verdict

    if [ "$rc" -eq 124 ]; then
        VMKIT_RUN_OUTCOME="TIMEOUT"
        return 124
    fi

    # Guests print CRLF (Windows) or LF; strip the CR before matching so the
    # verdict word is the verdict word.
    line="$(tr -d '\r' < "$out" | grep -m1 '^RESULT=' || true)"
    verdict="$(printf '%s' "$line" | sed -n 's/^RESULT=\([A-Za-z-]*\).*/\1/p')"

    # Opt-out for anyone driving a script that predates the protocol. The exit
    # status is still honoured — that half is not negotiable.
    if [ "${VMKIT_REQUIRE_RESULT:-1}" = 0 ] && [ -z "$line" ]; then
        VMKIT_RUN_OUTCOME="$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
        return "$rc"
    fi

    if [ -z "$line" ]; then
        # No verdict at all. This is NOT a pass, whatever the exit status said:
        # the two ways to get here are a script that died part-way and a script
        # whose interpreter never started, and neither ran the assertions.
        # "Nothing at all" has to mean nothing from the GUEST. vmkit's own
        # progress lines (`>> pushing script dir into guest...`) share this
        # stream, and on a macOS guest there are always some, which would
        # otherwise turn every silent macOS run into the milder NO-RESULT.
        # Anything we cannot confidently attribute to vmkit counts as guest
        # output, so the stronger claim is only made when it is certain.
        if tr -d '\r' < "$out" | grep -qvE '^(>>|$)'; then
            VMKIT_RUN_OUTCOME="NO-RESULT"
        else
            VMKIT_RUN_OUTCOME="NO-OUTPUT"
        fi
        {
            if [ "$VMKIT_RUN_OUTCOME" = "NO-OUTPUT" ]; then
                echo "vmkit: guest script '$script' produced NO OUTPUT AT ALL (exit $rc)."
                echo "   It died before its first statement — a crashed interpreter still"
                echo "   yields exit 0 through prlctl exec."
            else
                echo "vmkit: guest script '$script' never printed RESULT= (exit $rc)."
                echo "   It stopped part-way through, so the phases above prove nothing."
                echo "   Most common cause: it could not source its helpers. vmkit pushes"
                echo "   the script's OWN directory into the guest and nothing above it, so"
                echo "   'lib/assert.sh' beside the script works and '../lib/assert.sh' does"
                echo "   not (it resolves on the host and is absent in the guest)."
            fi
            echo "   Reproduce in the guest with:"
            echo "     vmkit exec $(printf '%q' "$vm") <interpreter> <guest-path-to-script>"
        } >&2
        return "$VMKIT_RC_NO_RESULT"
    fi

    case "$verdict" in
        PASS|SKIP)
            if [ "$rc" -ne 0 ]; then
                # It said it passed and then died. `set -e`/`set -u` after the
                # verdict, a wedged cleanup, an interpreter crash on the way
                # out — all real failures, and all invisible if the sentinel
                # were allowed to win outright.
                VMKIT_RUN_OUTCOME="FAIL"
                {
                    echo "vmkit: guest script '$script' printed '$line' and then exited $rc."
                    echo "   The verdict is not trusted over a non-zero exit: the script did"
                    echo "   not finish cleanly, so anything after its last PHASE= line —"
                    echo "   teardown, cleanup, a trailing assertion — did not happen."
                } >&2
                return "$rc"
            fi
            VMKIT_RUN_OUTCOME="$verdict"
            return 0
            ;;
        FAIL)
            VMKIT_RUN_OUTCOME="FAIL"
            [ "$rc" -eq 0 ] && rc=1     # RESULT=FAIL at exit 0 is still a fail
            return "$rc"
            ;;
        *)
            VMKIT_RUN_OUTCOME="FAIL"
            echo "vmkit: guest script '$script' printed an unrecognized verdict: $line" >&2
            echo "   Expected RESULT=PASS, RESULT=FAIL or RESULT=SKIP." >&2
            [ "$rc" -eq 0 ] && rc=1
            return "$rc"
            ;;
    esac
}

# The exec half of cmd_run: get the script into the guest and run it, per OS.
# Split out so cmd_run can tee the guest's output and judge it (above) without
# the per-OS plumbing growing a second copy of the capture logic.
run_guest_script() { # <vm> <repo-relative-script> [args...]
    local vm="$1" script="$2"; shift 2
    local os; os="$(vm_os "$vm")"

    if [ "$os" = windows ]; then
        local win repo_path
        repo_path="$(guest_repo "$vm")" || return 1
        win="${repo_path}\\${script//\//\\}"
        # cmd-side `set NAME=VALUE&&` prefix carries the forwarded env; SYSTEM
        # has no profile to inherit from.
        local setpfx="" kv
        while IFS= read -r kv; do
            [ -z "$kv" ] && continue
            setpfx="${setpfx}set \"$kv\"&& "
        done < <({ forwarded_env; artifact_env_for "$vm"; })
        if [ -n "$setpfx" ]; then
            run_guarded "$vm" prlctl exec "$vm" cmd /c "${setpfx}powershell -NoProfile -ExecutionPolicy Bypass -File \"$win\""
        else
            run_guarded "$vm" prlctl exec "$vm" powershell -NoProfile -ExecutionPolicy Bypass -File "$win" "$@"
        fi
    else
        local envargs=() kv target
        while IFS= read -r kv; do
            [ -z "$kv" ] && continue
            envargs+=("$kv")
        done < <(forwarded_env)
        if [ "$os" = macos ]; then
            target="$(push_script_macos "$vm" "$script")" || return 1
            while IFS= read -r kv; do
                [ -z "$kv" ] && continue
                envargs+=("$kv")
            done < <({ artifact_env_for "$vm"; secrets_env_for_macos "$vm"; })
        else
            target="$(guest_repo "$vm")/${script}" || return 1
            while IFS= read -r kv; do
                [ -z "$kv" ] && continue
                envargs+=("$kv")
            done < <(artifact_env_for "$vm")
        fi
        # `env` with no assignments is a harmless passthrough. NEVER use
        # `$SUDO VAR=val cmd` in guest scripts (empty $SUDO runs VAR=val as a
        # command) — that lesson lives in the guest scripts themselves.
        run_guarded "$vm" prlctl exec "$vm" env "${envargs[@]}" bash "$target" "$@"
    fi
}

cmd_run() { # <vm> <repo-relative-script> [args...]
    local vm="$1" script="$2"; shift 2
    # Standalone `vmkit run` claims the host too (FAILURES.md #4). Re-entrant:
    # under `vmkit test`/`series`/`provision` this inherits the outer hold.
    self_hold "$(self_hold_ttl "${VMKIT_RUN_TIMEOUT:-1800}")" \
        "vmkit run $vm $script" || return 1
    ensure_running "$vm" || return 1

    # Fail here, not 8 minutes into the guest script, if the artifact was
    # built for the wrong architecture. Must happen before the env plumbing
    # in run_guest_script, which pushes the artifact from inside a `< <(...)`
    # that would discard the refusal.
    local artifact_path
    artifact_path="$(artifact_host_path_for "$vm")"
    if [ -n "$artifact_path" ]; then
        assert_artifact_runnable "$vm" "$artifact_path" || return 1
    fi

    # Capture as well as show. The exit status alone is not a verdict (a
    # crashed interpreter exits 0 through prlctl exec; a script that never
    # reached its assertions exits 1 with nothing to say), so the RESULT= line
    # has to be read — which means the stream has to be kept.
    local out rc=0
    out="$(mktemp)"
    # `set +e` rather than `|| true` on the pipeline: `|| true` runs a simple
    # command on failure, which RESETS PIPESTATUS to (0), so PIPESTATUS[0]
    # would read 0 for every failing script (the same trap provision hit).
    set +e
    run_guest_script "$vm" "$script" "$@" 2>&1 | tee "$out"
    rc="${PIPESTATUS[0]}"
    set -e
    local grc=0
    guest_result_gate "$vm" "$script" "$out" "$rc" || grc=$?
    rc="$grc"
    rm -f "$out"
    return "$rc"
}

# --- guest-script lint ------------------------------------------------------
# Refuse a guest script the guest cannot parse, before spending forty seconds
# booting a VM to find out. Every check here is a real first-run failure:
#
#   .ps1 non-ASCII   Windows PowerShell 5.1 reads a UTF-8 file with no BOM as
#                    CP1252, so an em dash (E2 80 94) arrives as three
#                    characters ending in U+201D -- a smart quote it honours as
#                    a string delimiter. One of them inside a double-quoted
#                    message ends the string early and the REST OF THE FILE
#                    parses as code; the parser then reports a brace error on
#                    an unrelated line whose braces are balanced.
#                    (FAILURES.md #24. The alternative fix, writing .ps1 with a
#                    UTF-8 BOM, was rejected downstream and here for the same
#                    reason: a BOM is invisible, an editor or a `sed` drops it
#                    silently, and the constraint then depends on a byte nobody
#                    can see.)
#   .sh syntax       the same failure one interpreter over, minutes into a run.
#   sibling source   only the script's OWN directory is pushed into the guest,
#                    so `../lib/assert.sh` resolves on the host and is absent
#                    in the guest (FAILURES.md #23). A warning, not a refusal:
#                    a script may legitimately mention `..` for something the
#                    host stages, and the verdict gate now catches the rest.
guest_script_lint() { # <host-path> [label]  -> 0 ok / 1 fatal
    local f="$1" label="${2:-$1}" rc=0
    [ -f "$f" ] || { echo "vmkit: flavor script not found: $label" >&2; return 1; }

    case "$f" in
        *.ps1)
            if LC_ALL=C grep -q '[^ -~\t]' "$f" 2>/dev/null; then
                {
                    echo "vmkit: $label contains non-ASCII characters."
                    echo "   Windows PowerShell 5.1 reads UTF-8 without a BOM as CP1252, and an"
                    echo "   em dash decodes to a smart quote it treats as a string delimiter --"
                    echo "   which ends a string early and makes the WHOLE FILE fail to parse,"
                    echo "   reporting a brace error on an unrelated line. Keep .ps1 ASCII-only."
                    LC_ALL=C grep -n '[^ -~\t]' "$f" | sed 's/^/     /'
                } >&2
                rc=1
            fi
            ;;
        *.sh)
            local errfile; errfile="$(mktemp)"
            if ! bash -n "$f" 2>"$errfile"; then
                {
                    echo "vmkit: $label is not valid bash."
                    sed 's/^/     /' "$errfile"
                } >&2
                rc=1
            fi
            rm -f "$errfile"
            ;;
    esac

    # Sourcing anything above the script's own directory.
    local sib
    sib="$(grep -nE '^[[:space:]]*(\.|source|Import-Module)[[:space:]].*\.\.[/\\]' "$f" 2>/dev/null || true)"
    if [ -n "$sib" ]; then
        {
            echo ">> WARNING: $label sources a path above its own directory:"
            printf '%s\n' "$sib" | sed 's/^/     /'
            echo "   vmkit pushes the script's OWN directory into the guest and nothing"
            echo "   above it, so a sibling '../lib' resolves on the host and is absent in"
            echo "   the guest. Put helpers in a 'lib/' INSIDE the script's directory."
        } >&2
    fi
    return "$rc"
}

# Lint every configured flavor script (all flavors, or just <flavor>).
cmd_check_scripts() { # [flavor]
    local want="${1:-}" var script rc=0 seen=0
    for var in $(compgen -v | grep '^VMKIT_FLAVOR_.*_\(WINDOWS\|LINUX\|MACOS\)$'); do
        if [ -n "$want" ]; then
            local upper; upper="$(printf '%s' "$want" | tr '[:lower:]-' '[:upper:]_')"
            case "$var" in VMKIT_FLAVOR_${upper}_*) ;; *) continue ;; esac
        fi
        script="${!var:-}"
        [ -n "$script" ] || continue
        seen=$(( seen + 1 ))
        guest_script_lint "$VMKIT_REPO_ROOT/$script" "$script" || rc=1
    done
    if [ "$seen" -eq 0 ]; then
        echo "vmkit: no flavor scripts configured${want:+ for flavor '$want'} in $VMKIT_REPO_CONF" >&2
        return 1
    fi
    [ "$rc" -eq 0 ] && echo "guest scripts: $seen checked, all parseable"
    return "$rc"
}

cmd_test() { # <platform> [flavor=local]
    local platform="$1" flavor="${2:-local}"
    local vm; vm="$(platform_vm "$platform")" || return 1
    local start rc=0; start="$(date +%s)"
    VMKIT_RUN_OUTCOME=""
    echo "=== $platform ($flavor): starting ==="
    local effective_vm
    effective_vm="$(resolve_effective_vm "$vm")" || return 1
    echo ">> using '$effective_vm'"

    # Claim the host for the whole leg (FAILURES.md #4): reset-then-run is not
    # atomic, and a second invocation's ensure_only would otherwise stop this
    # guest between the two. Re-entrant — the inner cmd_reset/cmd_run calls
    # inherit this token rather than taking their own.
    local script; script="$(flavor_script "$flavor" "$platform")" || return 1
    # Two seconds of grep before forty seconds of VM boot, and before claiming
    # the host: a script the guest cannot parse fails here instead of halfway
    # through a leg.
    guest_script_lint "$VMKIT_REPO_ROOT/$script" "$script" || return 1

    self_hold "$(self_hold_ttl "$(flavor_timeout "$flavor")")" \
        "vmkit test $platform $flavor" || return 1

    host_snapshot
    cmd_reset "$effective_vm" "$VMKIT_TEST_SNAP" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo ">> running $script on '$effective_vm'..."
        host_snapshot
        VMKIT_RUN_TIMEOUT="${VMKIT_RUN_TIMEOUT:-$(flavor_timeout "$flavor")}" \
            cmd_run "$effective_vm" "$script" || rc=$?
    else
        # The guest never reached the script: say so rather than reporting a
        # verdict the script never gave.
        VMKIT_RUN_OUTCOME="SETUP-FAILED"
    fi
    host_snapshot   # teardown boundary: capture the host state the run left behind
    local elapsed=$(( $(date +%s) - start ))
    if [ "$rc" -eq 0 ]; then
        echo "=== $platform ($flavor): ${VMKIT_RUN_OUTCOME:-PASS} (${elapsed}s) ==="
    else
        echo "=== $platform ($flavor): ${VMKIT_RUN_OUTCOME:-FAIL} (exit $rc, ${elapsed}s) — see output above ===" >&2
    fi
    return "$rc"
}

# Run a flavor on one platform, or on every configured platform in series.
# A failure on one platform never skips the rest; a summary prints at the end.
cmd_series() { # <flavor> [platform]
    local flavor="$1" platform="${2:-}"
    if [ -n "$platform" ]; then
        cmd_test "$platform" "$flavor"
        return $?
    fi
    local p rc overall=0
    declare -A results=()
    declare -A outcomes=()
    # One hold for the WHOLE series, not one per leg: a gap between legs is a
    # window for another invocation to take the host mid-series.
    local n; n="$(host_platforms | grep -c . || true)"
    [ "${n:-0}" -gt 0 ] || n=1
    self_hold "$(self_hold_ttl "$(( $(flavor_timeout "$flavor") * n ))")" \
        "vmkit series $flavor" || return 1
    for p in $(host_platforms); do
        rc=0; cmd_test "$p" "$flavor" || rc=$?
        results[$p]=$rc
        outcomes[$p]="${VMKIT_RUN_OUTCOME:-}"
    done
    echo ""
    echo "=== vmkit series ($flavor) summary ==="
    for p in $(host_platforms); do
        if [ "${results[$p]}" -eq 0 ]; then
            printf "  %-8s %s\n" "$p" "${outcomes[$p]:-PASS}"
        else
            printf "  %-8s %s (exit %s)\n" "$p" "${outcomes[$p]:-FAIL}" "${results[$p]}"
            overall=1
        fi
    done
    return "$overall"
}
