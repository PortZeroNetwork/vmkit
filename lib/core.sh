# shellcheck shell=bash
# vmkit core: prlctl orchestration — snapshot ladder, readiness, guards.
#
# Failure classes encoded here (see docs/FAILURES.md for the full catalog):
#   revert-collapse   snapshot-switch to a RUNNING snapshot occasionally leaves
#                     the guest powered off moments later -> ensure_running
#   wedged guest      a hung guest process outlives its host-side prlctl exec
#                     -> run_guarded timeout + guest_kill_stragglers
#   external boot     booting a VM off the archive drive is slow/flaky/wearing
#                     -> internal-disk-only policy in resolve_effective_vm
#   contention        two harness invocations fight over the single VM host
#                     -> ensure_only (one-VM-at-a-time), callers must serialize
#                     runs (CI concurrency group; don't run local tests during CI)

# --- snapshot helpers ---------------------------------------------------------
snap_id_by_name() { # <vm> <snapshot-name>
    local vm="$1" name="$2" id
    for id in $(prlctl snapshot-list "$vm" 2>/dev/null | grep -oE '\{[0-9a-f-]+\}'); do
        if prlctl snapshot-list "$vm" -i "$id" 2>/dev/null | grep -qiE "^Name: ${name}$"; then
            echo "$id"; return 0
        fi
    done
    return 1
}

is_running() { prlctl status "$1" 2>/dev/null | grep -q running; }

# Block until the guest answers a trivial exec, per OS. Heartbeat every ~10s so
# a slow boot/revert never looks hung.
wait_ready() { # <vm>
    local vm="$1" i elapsed
    echo ">> waiting for guest '$vm' to become ready..."
    for i in $(seq 1 90); do
        elapsed=$(( (i - 1) * 2 ))
        if [ "$(vm_os "$vm")" = windows ]; then
            prlctl exec "$vm" cmd /c "echo READY" 2>/dev/null | grep -q READY \
                && { echo ">> guest '$vm' ready (${elapsed}s)"; return 0; }
        else
            prlctl exec "$vm" echo READY 2>/dev/null | grep -q READY \
                && { echo ">> guest '$vm' ready (${elapsed}s)"; return 0; }
        fi
        if [ "$elapsed" -gt 0 ] && [ $(( elapsed % 10 )) -eq 0 ]; then
            echo ">> still waiting for guest '$vm'... (${elapsed}s/180s)"
        fi
        sleep 2
    done
    echo "guest '$vm' did not become ready after 180s" >&2; return 1
}

# Revert-collapse guard: make sure <vm> is actually running and answering,
# starting it if needed. Called right before running anything in the guest.
ensure_running() { # <vm>
    local vm="$1"
    if ! is_running "$vm"; then
        echo ">> guest '$vm' is not running (revert-collapse?); starting it..." >&2
        prlctl start "$vm" >/dev/null 2>&1 || true
    fi
    wait_ready "$vm"
}

# One-VM-at-a-time: stop every OTHER running VM (memory/disk contention on a
# single host makes concurrent guests flaky).
ensure_only() { # <vm>
    local keep="$1" name
    prlctl list -o name --no-header 2>/dev/null | while IFS= read -r name; do
        [ -z "$name" ] && continue
        if [ "$name" != "$keep" ]; then
            echo ">> stopping other running VM: $name"
            prlctl stop "$name" --fast >/dev/null 2>&1 || true
        fi
    done
}

# --- internal-disk-only recovery ------------------------------------------------
# POLICY: VMs boot only from the internal disk. Archive copies (slow external
# drive) are clone SOURCES, never boot targets. If the internal working copy is
# missing: interactive -> offer clone-to-internal or abort; non-interactive
# (CI) -> hard-fail with recovery guidance (a silent ~100GB clone mid-job is
# worse than a loud failure).
resolve_effective_vm() { # <working-vm-name>  (prints the vm to use, or fails)
    local vm="$1"
    if prlctl list -i "$vm" >/dev/null 2>&1; then
        echo "$vm"; return 0
    fi

    echo "!! '$vm' not found on internal disk." >&2
    local archive; archive="$(archive_vm "$vm")"
    if [ -z "$archive" ]; then
        echo "   no archive configured for '$vm' in host.conf — nothing to recover from" >&2
        return 1
    fi

    local drive="${VMKIT_ARCHIVE_DRIVE:-}"
    if [ -n "$drive" ] && [ ! -d "$drive" ] && [ ! -t 0 ]; then
        echo "archive drive not mounted at $drive and no terminal to prompt — aborting '$vm'" >&2
        return 1
    fi
    while [ -n "$drive" ] && [ ! -d "$drive" ]; do
        echo "!! archive drive not mounted at $drive." >&2
        read -r -p "   Plug it in, then press Enter to check again (Ctrl-C to abort)... " _ < /dev/tty
    done

    prlctl list -i "$archive" >/dev/null 2>&1 || {
        echo "archive '$archive' not registered either — nothing to recover '$vm' from" >&2
        return 1
    }

    if ! snap_id_by_name "$archive" "$(resolve_snap "$archive" "${VMKIT_TEST_SNAP:-built}")" >/dev/null; then
        echo "!! WARNING: archive '$archive' lacks the test snapshot (stale/never-provisioned mirror)." >&2
    fi

    if [ ! -t 0 ]; then
        echo "!! '$vm' is missing from the internal disk and this is a non-interactive session." >&2
        echo "   Refusing to boot '$archive' in place off the archive drive:" >&2
        echo "   VMs must run on the internal disk only. Restore the internal working copy first:" >&2
        echo "       vmkit adopt        # or: prlctl clone \"$archive\" --name \"$vm\" --dst \"$VMKIT_INTERNAL_DIR\"" >&2
        return 1
    fi

    echo "   found archive '$archive'. VMs boot from the internal disk only," >&2
    echo "   so the archive is cloned in — never booted in place." >&2
    echo "   [1] clone to internal now (one-time, slow: tens of minutes, ~100GB)" >&2
    echo "   [2] abort" >&2
    local choice
    read -r -p "   choice [1/2]: " choice < /dev/tty
    case "$choice" in
        1)
            echo ">> cloning '$archive' -> '$vm' on internal disk..." >&2
            prlctl clone "$archive" --name "$vm" --dst "$VMKIT_INTERNAL_DIR" >&2
            echo ">> clone complete." >&2
            echo "$vm"
            ;;
        *)
            echo "aborted: '$vm' not available (internal-only policy)" >&2
            return 1
            ;;
    esac
}

# --- lifecycle commands -----------------------------------------------------------
cmd_up() { # <vm>
    local vm="$1" rsnap; rsnap="$(resolve_snap "$vm" ready)"
    ensure_only "$vm"
    local ready; ready="$(snap_id_by_name "$vm" "$rsnap" || true)"
    if [ -n "$ready" ]; then
        echo ">> reverting to existing running snapshot '$rsnap'"
        prlctl snapshot-switch "$vm" -i "$ready" >/dev/null
        ensure_running "$vm"; echo "ready"; return 0
    fi
    local gsnap gid; gsnap="$(resolve_snap "$vm" golden)"
    gid="$(snap_id_by_name "$vm" "$gsnap")" \
        || { echo "golden snapshot '$gsnap' not found on '$vm' (see docs/HUMAN-SETUP.md)" >&2; return 1; }
    echo ">> reverting to golden '$gsnap' and booting"
    prlctl snapshot-switch "$vm" -i "$gid" >/dev/null
    prlctl start "$vm" >/dev/null
    wait_ready "$vm"
    prlctl snapshot "$vm" -n "$rsnap" -d "Booted + guest tools. Per-test reset point." >/dev/null
    echo "up; captured '$rsnap'"
}

cmd_checkpoint() { # <vm> <name>
    local vm="$1" name="$2" snap; snap="$(resolve_snap "$vm" "$name")"
    is_running "$vm" || { echo "VM '$vm' is not running" >&2; return 1; }
    local old; old="$(snap_id_by_name "$vm" "$snap" || true)"
    [ -n "$old" ] && prlctl snapshot-delete "$vm" -i "$old" >/dev/null 2>&1 || true
    prlctl snapshot "$vm" -n "$snap" -d "vmkit checkpoint: $name" >/dev/null
    echo "checkpoint '$snap' taken"
}

cmd_reset() { # <vm> [name=ready]
    local vm="$1" name="${2:-ready}" snap id; snap="$(resolve_snap "$vm" "$name")"
    id="$(snap_id_by_name "$vm" "$snap")" \
        || { echo "no snapshot '$snap' (run: vmkit up / vmkit checkpoint)" >&2; return 1; }
    ensure_only "$vm"
    prlctl snapshot-switch "$vm" -i "$id" >/dev/null
    wait_ready "$vm"
    echo "reset to '$snap'"
}

cmd_list() {
    prlctl list --all
    local p vn
    for p in $(host_platforms); do
        for vn in "$(platform_var "$p")" "$(platform_var "$p" _ARCHIVE)"; do
            [ -z "$vn" ] && continue
            echo "--- $vn"
            prlctl snapshot-list "$vn" 2>/dev/null | grep -oE '\{[0-9a-f-]+\}|Name:.*' || true
        done
    done
}

# --- guarded execution ----------------------------------------------------------
# Kill lingering test/daemon processes inside the guest. Killing a host-side
# prlctl exec does NOT kill the process it launched in the VM; a wedged process
# would linger (holding TUN devices/ports) into the next test. Process names
# come from repo config: VMKIT_KILL_WINDOWS / VMKIT_KILL_UNIX (space-separated).
guest_kill_stragglers() { # <vm>
    local vm="$1" names
    if [ "$(vm_os "$vm")" = windows ]; then
        names="${VMKIT_KILL_WINDOWS:-}"
        [ -z "$names" ] && return 0
        local cmdline="" n
        for n in $names; do cmdline="${cmdline}taskkill /F /IM $n /T 2>nul & "; done
        prlctl exec "$vm" cmd /c "${cmdline}exit 0" >/dev/null 2>&1 || true
    else
        names="${VMKIT_KILL_UNIX:-}"
        [ -z "$names" ] && return 0
        local script="" n
        for n in $names; do script="${script}pkill -9 -f $n >/dev/null 2>&1; "; done
        prlctl exec "$vm" bash -lc "${script}true" >/dev/null 2>&1 || true
    fi
}

# Run a command with a hard host-side timeout (macOS has no `timeout`). On
# expiry, kill the host process AND clean up guest stragglers, then return 124
# (GNU timeout convention) so callers can distinguish a wedge from a failure.
# VMKIT_RUN_TIMEOUT seconds; default 1800.
run_guarded() { # <vm> <cmd...>
    local vm="$1"; shift
    local secs="${VMKIT_RUN_TIMEOUT:-1800}"
    local marker; marker="$(mktemp)"
    local start; start="$(date +%s)"
    "$@" &
    local pid=$!
    ( sleep "$secs"; echo 1 > "$marker"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
    local killer=$!
    # Host-side heartbeat so a guest script that goes quiet never looks hung.
    ( while kill -0 "$pid" 2>/dev/null; do
          sleep 30
          kill -0 "$pid" 2>/dev/null \
              && echo ">> still running on '$vm'... ($(( $(date +%s) - start ))s elapsed, ${secs}s budget)" >&2
      done ) &
    local heartbeat=$!
    wait "$pid" 2>/dev/null; local rc=$?
    kill "$heartbeat" 2>/dev/null; wait "$heartbeat" 2>/dev/null
    if [ -s "$marker" ]; then
        rm -f "$marker"; kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
        echo "vmkit: TIMEOUT after ${secs}s — killing guest stragglers" >&2
        guest_kill_stragglers "$vm"
        return 124
    fi
    kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null; rm -f "$marker"
    return "$rc"
}
