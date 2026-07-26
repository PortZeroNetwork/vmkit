# shellcheck shell=bash
# vmkit host hold: a cooperative lock over the whole VM host.
#
# WHY THIS EXISTS
# ensure_only() enforces one-VM-at-a-time by STOPPING every other running VM.
# That is correct for a queue of harness runs, and destructive for anything
# else sharing the machine — most obviously a self-hosted CI runner and a human
# using a guest interactively at the same time. A GitHub `concurrency:` group
# serializes CI jobs against each other; it knows nothing about a local
# session, so a push landing mid-session silently powers off the guest a human
# is working in (docs/FAILURES.md, issue #12).
#
# A hold is the missing half: whoever is using the host says so, and every
# implicit VM-stopping path refuses instead of stomping. It is COOPERATIVE —
# it guards vmkit's own ensure_only, not `prlctl stop` typed by hand.
#
# Holds always expire. A forgotten hold that wedged CI until someone noticed
# would be a worse failure than the one this prevents, so the record carries a
# deadline and any reader reaps it once past.

hold_dir()  { printf '%s' "${VMKIT_STATE_DIR:-$HOME/.local/state/vmkit}"; }
hold_file() { printf '%s/hold' "$(hold_dir)"; }

# Default hold lifetime: long enough for a working session, short enough that
# forgetting one costs an afternoon of CI rather than a week.
VMKIT_HOLD_TTL_DEFAULT="${VMKIT_HOLD_TTL_DEFAULT:-14400}"   # 4h

now_epoch() { date +%s; }

# Print a live hold's record on stdout (key=value lines) and return 0.
# Returns 1 when no hold exists, or when the one on disk has expired — an
# expired record is reaped here so every reader converges on the same answer.
hold_read() {
    local f exp
    f="$(hold_file)"
    [ -f "$f" ] || return 1
    exp="$(sed -n 's/^VMKIT_HOLD_EXPIRES=//p' "$f" | head -1)"
    # A record with no parseable deadline is corrupt, not eternal: reap it.
    case "$exp" in
        ''|*[!0-9]*) rm -f "$f"; return 1 ;;
    esac
    if [ "$(now_epoch)" -ge "$exp" ]; then
        rm -f "$f"
        return 1
    fi
    cat "$f"
}

# Read one field out of a live hold. Empty when there is no live hold.
hold_field() { # <field-suffix>   e.g. hold_field VM
    hold_read 2>/dev/null | sed -n "s/^VMKIT_HOLD_$1=//p" | head -1
}

# Human-readable "3h51m" style remaining time for a live hold.
hold_remaining() {
    local exp left
    exp="$(hold_field EXPIRES)"; [ -z "$exp" ] && return 1
    left=$(( exp - $(now_epoch) ))
    [ "$left" -lt 0 ] && left=0
    printf '%dh%02dm' "$(( left / 3600 ))" "$(( left % 3600 / 60 ))"
}

# Print the current hold to stdout in human form. Used by `vmkit hold` with no
# arguments, by doctor, and inside the refusal message.
hold_describe() { # [indent]
    local ind="${1:-}" rec
    rec="$(hold_read)" || { echo "${ind}no active hold"; return 1; }
    local reason vm user pid acq
    reason="$(printf '%s' "$rec" | sed -n 's/^VMKIT_HOLD_REASON=//p' | head -1)"
    vm="$(printf '%s' "$rec"     | sed -n 's/^VMKIT_HOLD_VM=//p'     | head -1)"
    user="$(printf '%s' "$rec"   | sed -n 's/^VMKIT_HOLD_USER=//p'   | head -1)"
    pid="$(printf '%s' "$rec"    | sed -n 's/^VMKIT_HOLD_PID=//p'    | head -1)"
    acq="$(printf '%s' "$rec"    | sed -n 's/^VMKIT_HOLD_ACQUIRED=//p' | head -1)"
    echo "${ind}reason:  ${reason:-(none given)}"
    echo "${ind}held vm: ${vm:-<entire host>}"
    echo "${ind}since:   $(date -r "$acq" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$acq") (expires in $(hold_remaining))"
    echo "${ind}held by: ${user:-?} (pid ${pid:-?})"
}

# THE GUARD. Called from ensure_only before it stops anything.
#
# Authorization is by TOKEN, never by VM name.
#
# The first version keyed on the VM name: a hold naming a VM permitted work on
# THAT VM, so the holder could still reset and boot their own guest. That is
# exactly backwards, and it cost a 20-minute provisioning run on 2026-07-26. A
# CI vm-test job targeting the very same guest matched `held == keep` and sailed
# through, reverting the guest to its own baseline snapshot mid-provision. The
# rule protected every VM EXCEPT the one actually in use.
#
# So: a live hold blocks every VM-stopping path, for everybody, unless the
# caller carries VMKIT_HOLD_TOKEN matching the record. The holder exports it
# (see cmd_hold); CI has no idea it exists and is refused. `--vm` survives only
# as documentation of what the host is being used for.
#
# Blocking ALL VMs rather than just the held one is deliberate: ensure_only
# stops the others to boot its target, so "CI may use a different guest" is not
# a thing that exists on a one-VM-at-a-time host.
hold_guard() { # <vm-we-are-about-to-keep>
    local keep="$1"
    hold_read >/dev/null 2>&1 || return 0            # no live hold, carry on

    # The holder passes; nobody else does.
    if [ -n "${VMKIT_HOLD_TOKEN:-}" ] && [ "${VMKIT_HOLD_TOKEN}" = "$(hold_field TOKEN)" ]; then
        return 0
    fi

    if [ "${VMKIT_IGNORE_HOLD:-}" = 1 ]; then
        echo ">> WARNING: VMKIT_IGNORE_HOLD=1 — proceeding through an active hold:" >&2
        hold_describe "   " >&2
        return 0
    fi

    {
        echo "vmkit: the VM host is HELD by another session — refusing to touch '$keep'."
        hold_describe "       "
        echo "       Release it with:  vmkit unhold"
        echo "       Or wait for it to expire, or override with: VMKIT_IGNORE_HOLD=1 vmkit ..."
    } >&2
    return 1
}

hold_usage() {
    echo "usage: vmkit hold [reason words] [--vm <platform|name>] [--ttl <seconds>] [--steal]"
    echo "       vmkit hold                 show the current hold"
    echo "       vmkit hold --status        show the current hold"
    echo "       vmkit hold --print-token … acquire, print only the token (for scripts)"
    echo "       vmkit unhold               release it"
}

cmd_hold() {
    local reason="" vm="" ttl="$VMKIT_HOLD_TTL_DEFAULT" steal=0 report=0 print_token=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --vm|--ttl)
                # Neither ever takes a leading-dash value, so a missing one
                # would otherwise swallow the NEXT flag (`--vm --ttl 60` held
                # a VM literally named "--ttl") or shift past the end.
                case "${2:-}" in
                    ''|-*) echo "vmkit: $1 needs a value" >&2; hold_usage >&2; return 2 ;;
                esac
                case "$1" in
                    --vm)  vm="$(resolve_vm_arg "$2")" ;;
                    --ttl) ttl="$2" ;;
                esac
                shift 2 ;;
            --steal)        steal=1; shift ;;
            --print-token)  print_token=1; shift ;;
            --status|--list) report=1; shift ;;
            # Everything after `--` is reason text, however it is spelled.
            --)      shift
                     while [ $# -gt 0 ]; do reason="${reason:+$reason }$1"; shift; done ;;
            # An unrecognized FLAG is a typo, not a reason. Falling through to
            # the catch-all below made `vmkit hold --list` claim the entire
            # host for four hours with the reason "--list" — every subsequent
            # ensure_only refused, i.e. a CI outage, and the confirmation it
            # printed back read like success. Reasons are still free text; they
            # just may not masquerade as options.
            -*)      { echo "vmkit: unknown option '$1'"
                       hold_usage
                       echo "       (to use it as reason text: vmkit hold -- '$1')"
                     } >&2
                     return 2 ;;
            *)       reason="${reason:+$reason }$1"; shift ;;
        esac
    done

    # Reporting is never an acquisition, so it may not carry acquire-only args.
    if [ "$report" = 1 ]; then
        if [ -n "$reason" ] || [ -n "$vm" ] || [ "$steal" = 1 ]; then
            echo "vmkit: --status only reports; it takes no reason, --vm, --ttl or --steal" >&2
            return 2
        fi
        hold_describe || true
        return 0
    fi

    # No arguments at all: report rather than acquire. Acquiring an unexplained
    # hold by typo is exactly the forgotten-hold failure we are guarding.
    if [ -z "$reason" ] && [ -z "$vm" ]; then
        hold_describe || return 0
        return 0
    fi
    case "$ttl" in ''|*[!0-9]*) echo "vmkit: --ttl must be seconds" >&2; return 2 ;; esac

    if hold_read >/dev/null 2>&1 && [ "$steal" != 1 ]; then
        {
            echo "vmkit: a hold is already active."
            hold_describe "       "
            echo "       Take it over with: vmkit hold --steal ..."
        } >&2
        return 1
    fi

    local f tok; f="$(hold_file)"
    # Ownership token: the ONLY thing that distinguishes the holder from any
    # other process on this machine. Everyone here runs as the same unix user,
    # so pid/user/VM-name can't tell a session apart from a CI job.
    tok="$(uuidgen 2>/dev/null || od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    mkdir -p "$(hold_dir)"
    rm -f "$f"
    {
        echo "VMKIT_HOLD_REASON=$reason"
        echo "VMKIT_HOLD_VM=$vm"
        echo "VMKIT_HOLD_TOKEN=$tok"
        echo "VMKIT_HOLD_USER=$(id -un)"
        echo "VMKIT_HOLD_PID=$PPID"
        echo "VMKIT_HOLD_ACQUIRED=$(now_epoch)"
        echo "VMKIT_HOLD_EXPIRES=$(( $(now_epoch) + ttl ))"
    } > "$f"
    chmod 600 "$f"

    if [ "$print_token" = 1 ]; then
        # Machine-readable: the caller captures this and exports it, so its own
        # vmkit invocations are recognized as the holder's.
        printf '%s\n' "$tok"
        return 0
    fi
    echo ">> host held${vm:+ for $vm} ($(hold_remaining) left): ${reason:-(none given)}"
    echo "   Your own vmkit commands need the ownership token — export it:"
    echo "     export VMKIT_HOLD_TOKEN=$tok"
}

cmd_unhold() {
    local f; f="$(hold_file)"
    if ! hold_read >/dev/null 2>&1; then
        # Covers both "never held" and "expired and just reaped".
        echo "no active hold"
        rm -f "$f"
        return 0
    fi
    rm -f "$f"
    echo ">> hold released"
}
