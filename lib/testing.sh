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
artifact_env_for() { # <vm>  — prints KEY=guestpath or nothing
    local vm="$1" os aenv="${VMKIT_ARTIFACT_ENV:-}"
    [ -z "$aenv" ] && return 0
    [ -n "${!aenv:-}" ] && return 0          # explicit env wins
    os="$(vm_os "$vm")"
    local key
    key="VMKIT_ARTIFACT_$(echo "$os" | tr '[:lower:]' '[:upper:]')"
    local rel="${!key:-}"
    [ -z "$rel" ] && return 0
    local host_path="$VMKIT_REPO_ROOT/$rel"
    [ -e "$host_path" ] || return 0
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

cmd_run() { # <vm> <repo-relative-script> [args...]
    local vm="$1" script="$2"; shift 2
    ensure_running "$vm" || return 1
    local os; os="$(vm_os "$vm")"

    if [ "$os" = windows ]; then
        local win; win="$(guest_repo "$vm")\\${script//\//\\}"
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
            target="$(push_script_macos "$vm" "$script")"
            while IFS= read -r kv; do
                [ -z "$kv" ] && continue
                envargs+=("$kv")
            done < <({ artifact_env_for "$vm"; secrets_env_for_macos "$vm"; })
        else
            target="$(guest_repo "$vm")/${script}"
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

cmd_test() { # <platform> [flavor=local]
    local platform="$1" flavor="${2:-local}"
    local vm; vm="$(platform_vm "$platform")" || return 1
    local start rc=0; start="$(date +%s)"
    echo "=== $platform ($flavor): starting ==="
    local effective_vm
    effective_vm="$(resolve_effective_vm "$vm")" || return 1
    echo ">> using '$effective_vm'"
    host_snapshot
    local script; script="$(flavor_script "$flavor" "$platform")" || return 1
    cmd_reset "$effective_vm" "$VMKIT_TEST_SNAP" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo ">> running $script on '$effective_vm'..."
        host_snapshot
        VMKIT_RUN_TIMEOUT="${VMKIT_RUN_TIMEOUT:-$(flavor_timeout "$flavor")}" \
            cmd_run "$effective_vm" "$script" || rc=$?
    fi
    host_snapshot   # teardown boundary: capture the host state the run left behind
    local elapsed=$(( $(date +%s) - start ))
    if [ "$rc" -eq 0 ]; then
        echo "=== $platform ($flavor): PASS (${elapsed}s) ==="
    else
        echo "=== $platform ($flavor): FAIL (exit $rc, ${elapsed}s) — see output above ===" >&2
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
    for p in $(host_platforms); do
        rc=0; cmd_test "$p" "$flavor" || rc=$?
        results[$p]=$rc
    done
    echo ""
    echo "=== vmkit series ($flavor) summary ==="
    for p in $(host_platforms); do
        if [ "${results[$p]}" -eq 0 ]; then
            printf "  %-8s PASS\n" "$p"
        else
            printf "  %-8s FAIL (exit %s)\n" "$p" "${results[$p]}"
            overall=1
        fi
    done
    return "$overall"
}
