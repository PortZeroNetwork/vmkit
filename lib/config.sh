# shellcheck shell=bash
# vmkit config loading: host inventory + per-repo test config.
# Both files are shell-sourced (zero parser dependencies, greppable, and repo
# config may define hook functions). Templates in templates/ document every key.

# --- host config --------------------------------------------------------------
# Machine inventory: which Parallels VMs exist, where they live, where the
# archive drive and download cache are. Written once per machine (vmkit
# init-host), validated by vmkit doctor.
vmkit_load_host_conf() {
    local conf="${VMKIT_HOST_CONF:-$HOME/.config/vmkit/host.conf}"
    if [ ! -f "$conf" ]; then
        echo "vmkit: no host config at $conf" >&2
        echo "       Run 'vmkit init-host' to create one (see docs/HUMAN-SETUP.md)." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$conf"

    # Required keys — fail fast and name the missing knob.
    : "${VMKIT_ARCH:?host.conf must set VMKIT_ARCH (x86_64|arm64)}"
    : "${VMKIT_INTERNAL_DIR:?host.conf must set VMKIT_INTERNAL_DIR (e.g. \$HOME/Parallels)}"
    : "${VMKIT_SNAP_PREFIX:?host.conf must set VMKIT_SNAP_PREFIX (snapshot name prefix)}"
    # Optional: VMKIT_ARCHIVE_DRIVE, VMKIT_ARCHIVE_VM_DIR, VMKIT_CACHE_DIR.
    # Per-platform VM names: VMKIT_VM_<PLATFORM> and VMKIT_VM_<PLATFORM>_ARCHIVE.
}

# Return the platform (windows|linux|macos) for a VM name, from host config.
vm_os() { # <vm-name>
    local p
    for p in windows linux macos; do
        local vn av
        vn="$(platform_var "$p")"; av="$(platform_var "$p" _ARCHIVE)"
        if [ "$1" = "$vn" ] || { [ -n "$av" ] && [ "$1" = "$av" ]; }; then
            echo "$p"; return 0
        fi
    done
    echo "vmkit: unknown VM: $1 (not in host.conf)" >&2; return 1
}

# Internal working-copy name -> its archive name (empty if none configured).
archive_vm() { # <vm-name>
    local p; p="$(vm_os "$1")" || return 1
    platform_var "$p" _ARCHIVE
}

# Platform shorthand -> internal working-copy VM name.
platform_vm() { # <windows|linux|macos>
    local v; v="$(platform_var "$1")"
    if [ -z "$v" ]; then
        echo "vmkit: platform '$1' has no VM on this host (host.conf VMKIT_VM_$(echo "$1" | tr '[:lower:]' '[:upper:]') unset)" >&2
        return 1
    fi
    echo "$v"
}

# Read VMKIT_VM_<PLATFORM><suffix> indirectly.
platform_var() { # <platform> [suffix]
    local key
    key="VMKIT_VM_$(echo "$1" | tr '[:lower:]' '[:upper:]')${2:-}"
    printf '%s' "${!key:-}"
}

# Platforms that actually have a VM configured on this host, in canonical order.
host_platforms() {
    local p out=()
    for p in windows linux macos; do
        [ -n "$(platform_var "$p")" ] && out+=("$p")
    done
    printf '%s\n' "${out[@]}"
}

# Commands accept either a platform shorthand or a literal VM name.
resolve_vm_arg() { # <platform|vm-name>
    case "$1" in
        windows|linux|macos) platform_vm "$1" ;;
        *) echo "$1" ;;
    esac
}

# Uniform snapshot naming: "<prefix>-<logical>". Cloning an archive carries its
# snapshot tree along, so fresh internal copies inherit these names for free.
#
# Legacy escape hatch: Parallels cannot rename snapshots, so hosts with
# pre-vmkit snapshot names can override per VM+logical in host.conf:
#     VMKIT_VM_MACOS_SNAP_GOLDEN="MacOS 15.7.7"
#
# Logical names may contain hyphens (provision preserves as e.g.
# "built-pre-defender", "pre-brew"). Those are not valid in bash variable
# names, so for the override-key lookup hyphens become underscores
# (VMKIT_VM_WINDOWS_SNAP_BUILT_PRE_DEFENDER). The actual snapshot name still
# uses the original logical string with hyphens.
resolve_snap() { # <vm> <logical>
    local p override_key logical_key
    if p="$(vm_os "$1" 2>/dev/null)"; then
        # Uppercase + map non-identifier chars to _ so hyphenated logical names
        # (built-pre-defender, pre-brew) don't blow up ${!override_key}.
        logical_key="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
        override_key="VMKIT_VM_$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')_SNAP_${logical_key}"
        if [ -n "${!override_key:-}" ]; then
            printf '%s' "${!override_key}"; return 0
        fi
    fi
    echo "${VMKIT_SNAP_PREFIX}-$2"
}

# --- repo config ----------------------------------------------------------------
# Per-repo test config: project name, flavors (script per OS + timeout),
# env forwarding, artifact discovery, guest cleanup process names.
# Searched upward from $PWD: ./vmkit.conf then ./vmtest/vmkit.conf per level.
vmkit_load_repo_conf() {
    local dir="$PWD" conf=""
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/vmkit.conf" ]; then conf="$dir/vmkit.conf"; break; fi
        if [ -f "$dir/vmtest/vmkit.conf" ]; then conf="$dir/vmtest/vmkit.conf"; break; fi
        dir="$(dirname "$dir")"
    done
    if [ -z "$conf" ]; then
        echo "vmkit: no repo config (vmkit.conf or vmtest/vmkit.conf) found from $PWD upward" >&2
        echo "       Run 'vmkit init' in the repo root to create one." >&2
        exit 1
    fi
    VMKIT_REPO_CONF="$conf"
    VMKIT_REPO_ROOT="$(cd "$(dirname "$conf")" && pwd)"
    [ "$(basename "$VMKIT_REPO_ROOT")" = vmtest ] && VMKIT_REPO_ROOT="$(dirname "$VMKIT_REPO_ROOT")"
    # shellcheck source=/dev/null
    . "$conf"
    : "${VMKIT_PROJECT:?$conf must set VMKIT_PROJECT (short name; used for guest scratch dirs)}"
    # Guest scratch dir (macOS push target); derived, overridable.
    VMKIT_GUEST_DIR="${VMKIT_GUEST_DIR:-/tmp/${VMKIT_PROJECT}-vmkit}"
    # Which snapshot `vmkit test` resets to before each run.
    VMKIT_TEST_SNAP="${VMKIT_TEST_SNAP:-built}"
}

# Flavor lookup: repo config defines VMKIT_FLAVOR_<NAME>_<OS>=<repo-relative
# script> and optional VMKIT_FLAVOR_<NAME>_TIMEOUT=<seconds>.
flavor_script() { # <flavor> <platform>
    local key
    key="VMKIT_FLAVOR_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')_$(echo "$2" | tr '[:lower:]' '[:upper:]')"
    local v="${!key:-}"
    if [ -z "$v" ]; then
        echo "vmkit: flavor '$1' has no script for $2 (set $key in $VMKIT_REPO_CONF)" >&2
        return 1
    fi
    echo "$v"
}

flavor_timeout() { # <flavor> — echoes seconds (default 360)
    local key
    key="VMKIT_FLAVOR_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')_TIMEOUT"
    printf '%s' "${!key:-360}"
}

# --- init templates -------------------------------------------------------------
init_host_conf() {
    local conf="${VMKIT_HOST_CONF:-$HOME/.config/vmkit/host.conf}"
    if [ -f "$conf" ] && [ "${1:-}" != "--force" ]; then
        echo "vmkit: $conf already exists (use --force to overwrite)" >&2; exit 1
    fi
    mkdir -p "$(dirname "$conf")"
    sed -e "s|@ARCH@|$(uname -m)|" "$VMKIT_SHARE/templates/host.conf" > "$conf"
    echo "wrote $conf — edit the VM names, then run: vmkit doctor"
}

init_repo_conf() {
    if [ -f vmkit.conf ] && [ "${1:-}" != "--force" ]; then
        echo "vmkit: ./vmkit.conf already exists (use --force to overwrite)" >&2; exit 1
    fi
    cp "$VMKIT_SHARE/templates/vmkit.conf" vmkit.conf
    echo "wrote ./vmkit.conf — define your flavors, then run: vmkit test <platform> <flavor>"
}
