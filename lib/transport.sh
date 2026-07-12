# shellcheck shell=bash
# vmkit transport: getting scripts, binaries, and env into guests.
#
# Per-OS quirks this encodes (docs/CAPABILITIES.md has the full matrix):
#   - Windows/Linux guests read the repo LIVE off the Parallels shared folder
#     (which maps host $HOME). prlctl exec runs as SYSTEM on Windows, which
#     cannot see mapped drive letters -> always UNC (\\Mac\Home\...).
#   - macOS guests: the SharedFolders SMB mount requires an authenticated GUI
#     login the guest never has after a snapshot revert -> everything is
#     PUSHED over `prlctl exec ... bash -s` as base64 payloads instead.
#   - Multi-line inline `prlctl exec bash -lc '...'` mangles arguments ->
#     always run script FILES, never long inline strings.

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

# Push <script>'s containing directory (so sibling files like lib/ helpers
# resolve) into a macOS guest, mirroring the repo-relative path under
# $VMKIT_GUEST_DIR. Prints the guest-side absolute script path.
push_script_macos() { # <vm> <repo-relative-script>
    local vm="$1" script="$2" script_dir; script_dir="$(dirname "$script")"
    {
        printf 'mkdir -p %q\n' "$VMKIT_GUEST_DIR"
        printf 'base64 -d > %q/payload.tar <<'"'"'VMKEOF'"'"'\n' "$VMKIT_GUEST_DIR"
        ( cd "$VMKIT_REPO_ROOT" && tar -cf - "$script_dir" ) | base64
        printf 'VMKEOF\n'
        printf 'cd %q && tar -xf payload.tar && rm -f payload.tar\n' "$VMKIT_GUEST_DIR"
    } | prlctl exec "$vm" bash -s >&2
    printf '%s/%s' "$VMKIT_GUEST_DIR" "$script"
}

# Push a single host file into a macOS guest at a fixed guest path.
# Prints the guest-side absolute path.
push_file_macos() { # <vm> <host-path> <guest-path> [chmod-mode]
    local vm="$1" host_file="$2" guest_file="$3" mode="${4:-}"
    {
        printf 'mkdir -p %q\n' "$(dirname "$guest_file")"
        printf 'base64 -d > %q <<'"'"'VMKEOF'"'"'\n' "$guest_file"
        base64 -i "$host_file"
        printf 'VMKEOF\n'
        [ -n "$mode" ] && printf 'chmod %s %q\n' "$mode" "$guest_file"
    } | prlctl exec "$vm" bash -s >&2
    printf '%s' "$guest_file"
}
