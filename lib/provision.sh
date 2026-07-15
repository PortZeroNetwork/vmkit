# shellcheck shell=bash
# vmkit provision: bake one-time guest OS-level config into a named checkpoint.
#
# The reusable form of the "reset -> run a provisioning script in the guest ->
# re-capture the checkpoint" dance. Anything a guest needs that must SURVIVE the
# per-test `vmkit reset` — Homebrew, a Windows Defender exclusion, a toolchain —
# has to live in the checkpoint itself, because every test reverts to that
# checkpoint first and discards whatever a per-run script did.
#
# Before this command, every consuming repo hand-rolled the dance in bespoke
# bash (reset; parse `prlctl snapshot-list` to test for a preservation snapshot;
# run; re-checkpoint). This encodes it once, with the safety rails built in.
#
# Semantics (see docs/PROVISIONING.md):
#   1. reset the VM to <checkpoint> (default: $VMKIT_TEST_SNAP, i.e. built)
#   2. preserve the pristine pre-provision state as a snapshot ONCE — only if it
#      doesn't already exist — so re-provisioning can never destroy the clean
#      baseline. Default name "<checkpoint>-pre-<label>"; --no-preserve skips it.
#   3. run <script> inside the guest, guarded by the usual host-side timeout
#   4. re-capture <checkpoint> with the provisioned state baked in
#   5. optionally also capture a permanent --anchor checkpoint: a durable anchor
#      the routine reset/re-provision flow never overwrites (the metered-link
#      cache of a one-time download — revert here if <checkpoint> is ever lost)
#
# On a guest-script failure the checkpoint is NOT re-captured: the VM is left at
# the failed state for inspection and the pristine preservation snapshot still
# holds the clean baseline, so a retry costs nothing.

cmd_provision() { # <vm> <script> [options...]  (see usage below)
    local vm="$1" script="$2"; shift 2
    local checkpoint="${VMKIT_TEST_SNAP:-built}"
    local label="" preserve_as="" anchor="" preserve=1
    local timeout="${VMKIT_RUN_TIMEOUT:-1800}"
    local -a script_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --checkpoint)  checkpoint="${2:?--checkpoint needs a name}"; shift 2 ;;
            --label)       label="${2:?--label needs a value}"; shift 2 ;;
            --preserve-as) preserve_as="${2:?--preserve-as needs a name}"; shift 2 ;;
            --no-preserve) preserve=0; shift ;;
            --anchor)      anchor="${2:?--anchor needs a name}"; shift 2 ;;
            --timeout)     timeout="${2:?--timeout needs seconds}"; shift 2 ;;
            --)            shift; script_args=("$@"); break ;;
            --*)           echo "vmkit provision: unknown option '$1'" >&2
                           echo "   valid: --checkpoint --label --preserve-as --no-preserve --anchor --timeout -- <args>" >&2
                           return 2 ;;
            *)             script_args=("$@"); break ;;
        esac
    done

    # Default preservation label: the script's basename without its extension.
    if [ -z "$label" ]; then
        label="$(basename "$script")"; label="${label%.*}"
    fi
    # Preservation snapshot's logical name: explicit override wins, else derived.
    local pre_logical="${preserve_as:-${checkpoint}-pre-${label}}"

    # Mutate the internal working copy (internal-disk-only policy); recover it
    # from the archive if missing, exactly like `vmkit test`.
    local effective_vm
    effective_vm="$(resolve_effective_vm "$vm")" || return 1

    echo "=== vmkit provision: '$effective_vm' <- $script ==="
    echo ">> reset to '$(resolve_snap "$effective_vm" "$checkpoint")' (pristine reset point)"
    cmd_reset "$effective_vm" "$checkpoint" || return 1

    if [ "$preserve" -eq 1 ]; then
        local pre_snap; pre_snap="$(resolve_snap "$effective_vm" "$pre_logical")"
        if snap_id_by_name "$effective_vm" "$pre_snap" >/dev/null 2>&1; then
            echo ">> preservation snapshot '$pre_snap' already exists — keeping the clean baseline, not re-taking it"
        else
            echo ">> preserving pristine pre-provision state as '$pre_snap' (one-time)"
            cmd_checkpoint "$effective_vm" "$pre_logical" >/dev/null
        fi
    fi

    echo ">> running provisioning script '$script' in the guest (timeout ${timeout}s)"
    local rc=0
    if [ "${#script_args[@]}" -gt 0 ]; then
        VMKIT_RUN_TIMEOUT="$timeout" cmd_run "$effective_vm" "$script" "${script_args[@]}" || rc=$?
    else
        VMKIT_RUN_TIMEOUT="$timeout" cmd_run "$effective_vm" "$script" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "vmkit provision: guest script '$script' failed (exit $rc)." >&2
        echo "   '$(resolve_snap "$effective_vm" "$checkpoint")' was NOT re-captured — the guest is left at the" >&2
        echo "   failed state so you can inspect it (vmkit screenshot / vmkit exec)." >&2
        [ "$preserve" -eq 1 ] && echo "   The pristine baseline is preserved as '$(resolve_snap "$effective_vm" "$pre_logical")'; fix the script and re-run." >&2
        return "$rc"
    fi

    echo ">> re-capturing '$(resolve_snap "$effective_vm" "$checkpoint")' with the provisioned state baked in"
    cmd_checkpoint "$effective_vm" "$checkpoint"

    if [ -n "$anchor" ]; then
        echo ">> capturing permanent anchor '$(resolve_snap "$effective_vm" "$anchor")' (never auto-overwritten)"
        cmd_checkpoint "$effective_vm" "$anchor"
    fi

    echo "=== vmkit provision: done — '$(resolve_snap "$effective_vm" "$checkpoint")' now includes '$script' ==="
}
