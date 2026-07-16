# shellcheck shell=bash
# vmkit transport: getting scripts, binaries, and env into guests.
#
# Per-OS quirks this encodes (docs/CAPABILITIES.md has the full matrix):
#   - Windows/Linux guests read the repo LIVE off the Parallels shared folder
#     (which maps host $HOME). prlctl exec runs as SYSTEM on Windows, which
#     cannot see mapped drive letters -> always UNC (\\Mac\Home\...).
#   - macOS guests: /Volumes/SharedFolders is mounted by prl_fsd but TCC
#     returns EPERM ("Operation not permitted") for every reader under headless
#     prlctl exec (root and interactive user alike; SIP blocks seeding TCC.db).
#     When a share probe succeeds we use it; otherwise we PUSH via a binary
#     tar.gz stream over `prlctl exec` (same approach as Parallels' prlcopy —
#     ~6x faster than the old base64-over-heredoc path, which could silently
#     run for many minutes and kill the GitHub self-hosted runner heartbeat).
#   - Multi-line inline `prlctl exec bash -lc '...'` mangles arguments ->
#     always run script FILES, never long inline strings.

# Seconds between keepalive lines during a macOS push (override via env).
: "${VMKIT_PUSH_KEEPALIVE_SECS:=15}"

# --- keepalive ---------------------------------------------------------------
# Long silent `prlctl exec` transfers saturate the host and starve the GitHub
# runner's job-lock renewal. Emit a line every N seconds on stderr while a
# push is in flight so the runner stays reachable.
#
# PID is stored in a global (not printed via stdout) so callers can invoke
# push_file_macos inside `$(...)` without orphaning the keepalive subshell
# or racing command-substitution capture against the tar stream.
_VMKIT_KEEPALIVE_PID=""

_keepalive_start() { # <label>
    local label="$1" interval="${VMKIT_PUSH_KEEPALIVE_SECS:-15}"
    # Stop any previous keepalive from a nested/aborted push.
    _keepalive_stop
    (
        local elapsed=0
        # First line after `interval` so short pushes stay quiet.
        while sleep "$interval"; do
            elapsed=$((elapsed + interval))
            echo ">> still pushing ${label} (${elapsed}s elapsed)..." >&2
        done
    ) &
    _VMKIT_KEEPALIVE_PID=$!
}

_keepalive_stop() {
    local pid="${_VMKIT_KEEPALIVE_PID:-}"
    _VMKIT_KEEPALIVE_PID=""
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    # Reap without tripping `set -e` if the process already exited.
    wait "$pid" 2>/dev/null || true
}

# --- macOS shared-folder probe ----------------------------------------------
# Returns the guest path of host $HOME via the Parallels share when it is
# actually readable. Empty + nonzero when the share is mounted-but-TCC-blocked
# (the common case under headless prlctl exec) or not mounted at all.
#
# Evidence (macOS 15.7.7 guest, SIP enabled, prlctl exec as root):
#   mount shows //guest:@Shared%20Folders... on /Volumes/SharedFolders
#   but `ls /Volumes/SharedFolders` -> Operation not permitted
#   Host Shared Folders on/off does not change the EPERM.
#
# Result is cached per VM for the life of the process (one probe per run).
_VMKIT_MACOS_SHARE_CACHE_VM=""
_VMKIT_MACOS_SHARE_CACHE_VAL=""   # "none" | absolute guest path

macos_share_home() { # <vm>
    local vm="$1" found
    if [ "$vm" = "$_VMKIT_MACOS_SHARE_CACHE_VM" ]; then
        if [ -z "$_VMKIT_MACOS_SHARE_CACHE_VAL" ] || [ "$_VMKIT_MACOS_SHARE_CACHE_VAL" = none ]; then
            return 1
        fi
        printf '%s' "$_VMKIT_MACOS_SHARE_CACHE_VAL"
        return 0
    fi
    # Single guest round-trip: prefer .../Home, else the share root.
    # Paths with spaces must stay quoted inside the guest shell.
    found="$(prlctl exec "$vm" sh -c '
        for c in \
            /Volumes/SharedFolders/Home \
            "/Volumes/My Shared Files/Home" \
            /Volumes/SharedFolders \
            "/Volumes/My Shared Files"
        do
            if test -r "$c" 2>/dev/null; then
                printf %s "$c"
                exit 0
            fi
        done
        exit 1
    ' 2>/dev/null)" || found=""
    _VMKIT_MACOS_SHARE_CACHE_VM="$vm"
    if [ -n "$found" ]; then
        _VMKIT_MACOS_SHARE_CACHE_VAL="$found"
        printf '%s' "$found"
        return 0
    fi
    _VMKIT_MACOS_SHARE_CACHE_VAL=none
    return 1
}

# Guest-side path for a host path under $HOME via the macOS share, or empty.
# Only succeeds when the share is readable AND the host path is under $HOME.
macos_guest_path_via_share() { # <vm> <host-path>
    local vm="$1" host_path="$2" share_home rel
    case "$host_path" in
        "$HOME"/*) ;;
        *) return 1 ;;
    esac
    share_home="$(macos_share_home "$vm")" || return 1
    rel="${host_path#"$HOME"/}"
    # Confirm the specific file is visible (share may be partial).
    if prlctl exec "$vm" test -e "$share_home/$rel" >/dev/null 2>&1; then
        printf '%s/%s' "$share_home" "$rel"
        return 0
    fi
    return 1
}

# Repo path AS SEEN FROM THE GUEST via the shared folder (windows/linux only).
guest_repo() { # <vm>
    case "$VMKIT_REPO_ROOT" in
        "$HOME"/*) ;;
        *) echo "repo ($VMKIT_REPO_ROOT) is not under \$HOME — the guest shared folder can't reach it" >&2; return 1 ;;
    esac
    local rel="${VMKIT_REPO_ROOT#"$HOME"/}"
    case "$(vm_os "$1")" in
        windows) printf '\\\\Mac\\Home\\%s' "${rel//\//\\}" ;;
        linux)   printf '/media/psf/Home/%s' "$rel" ;;
        macos)   echo "macOS guests cannot use the shared folder — use push_dir_macos" >&2; return 1 ;;
    esac
}

# Guest-side path for anything under the repo root (windows/linux).
guest_path_under_repo() { # <vm> <host-path-under-repo>
    local vm="$1" host_path="$2"
    local rel="${host_path#"$VMKIT_REPO_ROOT"/}"
    if [ "$(vm_os "$vm")" = windows ]; then
        printf '%s\\%s' "$(guest_repo "$vm")" "${rel//\//\\}"
    else
        printf '%s/%s' "$(guest_repo "$vm")" "$rel"
    fi
}

# Stream a host path (file or directory) into a macOS guest via binary tar.gz
# over prlctl exec stdin. Much faster than base64-over-heredoc, and paired
# with keepalive so long transfers never go silent.
# Extracts under <guest-parent>; the archived entry keeps its basename.
_push_tar_macos() { # <vm> <host-path> <guest-parent> <label>
    local vm="$1" host_path="$2" guest_parent="$3" label="$4"
    local parent base rc=0
    parent="$(dirname "$host_path")"
    base="$(basename "$host_path")"

    prlctl exec "$vm" mkdir -p "$guest_parent" >&2 || return 1

    _keepalive_start "$label"
    # prlcopy-style binary stream. Host is always macOS (vmkit host contract).
    # stdout of prlctl is discarded (tar is quiet on success); keepalive and
    # diagnostics stay on stderr so `$(push_file_macos …)` only captures the path.
    if ! tar czf - --no-mac-metadata --no-xattrs --no-fflags \
            -C "$parent" "$base" 2>/dev/null \
        | prlctl exec "$vm" tar zxf - -C "$guest_parent" >/dev/null
    then
        rc=1
    fi
    _keepalive_stop
    return "$rc"
}

# Push <script>'s containing directory (so sibling files like lib/ helpers
# resolve) into a macOS guest, mirroring the repo-relative path under
# $VMKIT_GUEST_DIR. Prints the guest-side absolute script path.
#
# Prefer the live shared-folder path when TCC allows it (rare under headless
# exec); otherwise tar.gz-push the script directory. Tar is rooted at
# $VMKIT_REPO_ROOT so `vmtest/scripts/...` lands at
# $VMKIT_GUEST_DIR/vmtest/scripts/... (same layout the old base64 path used).
push_script_macos() { # <vm> <repo-relative-script>
    local vm="$1" script="$2" script_dir host_dir guest_path size label rc=0
    script_dir="$(dirname "$script")"
    host_dir="$VMKIT_REPO_ROOT/$script_dir"

    # Fast path: run the script straight off the share.
    if guest_path="$(macos_guest_path_via_share "$vm" "$VMKIT_REPO_ROOT/$script")"; then
        echo ">> using script via macOS shared folder: $script" >&2
        printf '%s' "$guest_path"
        return 0
    fi

    size="$(du -sk "$host_dir" 2>/dev/null | awk '{print $1}')"
    label="$script_dir (${size:-?}KB)"
    echo ">> pushing script dir into guest via tar.gz: $label" >&2

    prlctl exec "$vm" mkdir -p "$VMKIT_GUEST_DIR" >&2 || return 1
    _keepalive_start "$label"
    if ! tar czf - --no-mac-metadata --no-xattrs --no-fflags \
            -C "$VMKIT_REPO_ROOT" "$script_dir" 2>/dev/null \
        | prlctl exec "$vm" tar zxf - -C "$VMKIT_GUEST_DIR" >/dev/null
    then
        rc=1
    fi
    _keepalive_stop
    [ "$rc" -eq 0 ] || return 1
    printf '%s/%s' "$VMKIT_GUEST_DIR" "$script"
}

# Push a single host file into a macOS guest at a fixed guest path.
# Always copies (callers that only need a readable path should use
# macos_guest_path_via_share first). Prints the guest-side absolute path.
push_file_macos() { # <vm> <host-path> <guest-path> [chmod-mode]
    local vm="$1" host_file="$2" guest_file="$3" mode="${4:-}"
    local guest_parent guest_base host_base size label

    guest_parent="$(dirname "$guest_file")"
    guest_base="$(basename "$guest_file")"
    host_base="$(basename "$host_file")"
    size="$(stat -f%z "$host_file" 2>/dev/null || echo 0)"
    label="$host_base (${size} bytes)"

    echo ">> pushing $label into guest via tar.gz..." >&2
    _push_tar_macos "$vm" "$host_file" "$guest_parent" "$label" || return 1

    if [ "$host_base" != "$guest_base" ]; then
        prlctl exec "$vm" mv "$guest_parent/$host_base" "$guest_file" >&2 || return 1
    fi
    if [ -n "$mode" ]; then
        prlctl exec "$vm" chmod "$mode" "$guest_file" >&2 || return 1
    fi
    printf '%s' "$guest_file"
}
