# shellcheck shell=bash
# vmkit fleet: archive <-> internal VM management (adopt on a new/cleaned
# machine, sync backups out to the archive drive).

# Clone archive VMs to the internal disk for any platform whose working copy
# is missing. This is the "new machine" (or "reclaimed disk space") story:
# plug in the archive drive, `vmkit adopt`, wait.
cmd_adopt() { # [platform...]
    local platforms=("$@")
    [ ${#platforms[@]} -eq 0 ] && mapfile -t platforms < <(host_platforms)
    local p vm archive missing=0 failed=0
    for p in "${platforms[@]}"; do
        vm="$(platform_vm "$p")" || { failed=1; continue; }
        if prlctl list -i "$vm" >/dev/null 2>&1; then
            echo "== $p: '$vm' already present on internal disk"
            continue
        fi
        missing=1
        archive="$(archive_vm "$vm")"
        if [ -z "$archive" ] || ! prlctl list -i "$archive" >/dev/null 2>&1; then
            echo "== $p: '$vm' missing and no registered archive to clone from" >&2
            echo "   (mount the archive drive and register the archive VM in Parallels first)" >&2
            failed=1; continue
        fi
        echo "== $p: cloning '$archive' -> '$vm' on internal disk (slow, one-time)..."
        if prlctl clone "$archive" --name "$vm" --dst "$VMKIT_INTERNAL_DIR"; then
            echo "== $p: adopted."
        else
            echo "== $p: clone FAILED" >&2; failed=1
        fi
    done
    [ "$missing" -eq 0 ] && echo "nothing to adopt — all configured platforms present"
    return "$failed"
}

# Mirror an internal VM bundle out to its registered archive VM's bundle
# directory. Both VMs must be powered off. rsync-based so re-syncs are
# incremental. Pass --dry-run to preview, --delete to prune files that no
# longer exist internally.
cmd_sync() { # <platform> [--dry-run] [--delete]
    local platform="" dry="" del="" arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry="--dry-run" ;;
            --delete)  del="--delete" ;;
            windows|linux|macos) platform="$arg" ;;
            *) echo "vmkit sync: unknown arg '$arg'" >&2; return 2 ;;
        esac
    done
    [ -z "$platform" ] && { echo "usage: vmkit sync <platform> [--dry-run] [--delete]" >&2; return 2; }

    local vm archive
    vm="$(platform_vm "$platform")" || return 1
    archive="$(archive_vm "$vm")"
    [ -z "$archive" ] && { echo "no archive configured for '$vm'" >&2; return 1; }

    is_running "$vm" && { echo "'$vm' is running — power it off before syncing" >&2; return 1; }
    is_running "$archive" && { echo "'$archive' is running (?!) — archives must never run" >&2; return 1; }

    local src dst
    src="$(prlctl list -i "$vm" 2>/dev/null | awk -F': ' '/^Home:/{print $2}')"
    dst="$(prlctl list -i "$archive" 2>/dev/null | awk -F': ' '/^Home:/{print $2}')"
    { [ -z "$src" ] || [ -z "$dst" ]; } && { echo "could not resolve VM Home dirs" >&2; return 1; }

    echo ">> sync '$vm' -> '$archive'"
    echo "   $src -> $dst"
    # shellcheck disable=SC2086
    rsync -a --info=progress2 $dry $del "$src" "$dst"
    echo ">> sync complete${dry:+ (dry run)}"
}
