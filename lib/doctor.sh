# shellcheck shell=bash
# vmkit doctor: validate this host against the vmkit contract. Never mutates.
# Exit 0 = healthy, 1 = problems found. Each check prints ok/WARN/FAIL.

doctor_run() {
    local fails=0 warns=0

    _ok()   { echo "  ok    $*"; }
    _warn() { echo "  WARN  $*"; warns=$((warns + 1)); }
    _fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }

    echo "== vmkit doctor =="

    # --- host tooling ---
    if command -v prlctl >/dev/null 2>&1; then
        _ok "prlctl on PATH ($(prlctl --version 2>/dev/null | head -1))"
    else
        _fail "prlctl not found — install Parallels Desktop (Pro, for CLI control)"
    fi
    command -v prlsrvctl >/dev/null 2>&1 || _warn "prlsrvctl not found"

    # --- host arch sanity ---
    local harch; harch="$(uname -m)"
    if [ "$harch" = "$VMKIT_ARCH" ]; then
        _ok "host arch $harch matches host.conf"
    else
        _fail "host arch is $harch but host.conf says VMKIT_ARCH=$VMKIT_ARCH — guests of the wrong arch cannot run"
    fi

    # --- the external-boot footgun ---
    # Parallels' GLOBAL default VM home decides where `prlctl clone/create`
    # WITHOUT --dst lands. If it points at the archive drive, a manual clone
    # boots off external storage. vmkit always passes --dst, but warn anyway.
    local vmhome
    vmhome="$(prlsrvctl info 2>/dev/null | awk -F': ' '/^VM home/{print $2}')"
    if [ -n "$vmhome" ]; then
        case "$vmhome" in
            /Volumes/*) _warn "Parallels default VM home is on external storage ($vmhome) — manual 'prlctl clone' without --dst will land (and boot) there" ;;
            *)          _ok "Parallels default VM home: $vmhome" ;;
        esac
    fi

    # --- disk layout ---
    [ -d "$VMKIT_INTERNAL_DIR" ] && _ok "internal VM dir: $VMKIT_INTERNAL_DIR" \
        || _fail "internal VM dir missing: $VMKIT_INTERNAL_DIR"
    if [ -n "${VMKIT_ARCHIVE_DRIVE:-}" ]; then
        [ -d "$VMKIT_ARCHIVE_DRIVE" ] && _ok "archive drive mounted: $VMKIT_ARCHIVE_DRIVE" \
            || _warn "archive drive not mounted: $VMKIT_ARCHIVE_DRIVE (recovery/sync unavailable)"
    fi
    if [ -n "${VMKIT_CACHE_DIR:-}" ]; then
        [ -d "$VMKIT_CACHE_DIR" ] && _ok "download cache: $VMKIT_CACHE_DIR" \
            || _warn "download cache missing: $VMKIT_CACHE_DIR (provisioning will need network)"
    fi

    # --- per-platform VM inventory ---
    local p vm archive home snap missing_snap
    for p in $(host_platforms); do
        vm="$(platform_var "$p")"
        echo "-- $p: '$vm'"
        if ! prlctl list -i "$vm" >/dev/null 2>&1; then
            _fail "internal VM '$vm' not registered (run 'vmkit adopt' or see docs/HUMAN-SETUP.md)"
            continue
        fi
        home="$(prlctl list -i "$vm" 2>/dev/null | awk -F': ' '/^Home:/{print $2}')"
        case "$home" in
            "$VMKIT_INTERNAL_DIR"/*) _ok "bundle on internal disk" ;;
            *) _fail "bundle NOT under $VMKIT_INTERNAL_DIR (at: $home) — internal-only boot policy violated" ;;
        esac
        # golden is the human contract; built is what `vmkit test` resets to.
        # (ready is an optional intermediate — not checked.)
        missing_snap=0
        for snap in golden built; do
            if ! snap_id_by_name "$vm" "$(resolve_snap "$vm" "$snap")" >/dev/null; then
                if [ "$snap" = golden ]; then
                    _fail "snapshot '$(resolve_snap "$vm" "$snap")' missing — the human-setup contract requires it (or set a legacy-name override, see templates/host.conf)"
                else
                    _warn "snapshot '$(resolve_snap "$vm" "$snap")' missing (provision, then 'vmkit checkpoint $p built')"
                fi
                missing_snap=1
            fi
        done
        [ "$missing_snap" -eq 0 ] && _ok "snapshot ladder complete (golden + built)"

        archive="$(platform_var "$p" _ARCHIVE)"
        if [ -n "$archive" ]; then
            if prlctl list -i "$archive" >/dev/null 2>&1; then
                if is_running "$archive"; then
                    _fail "archive VM '$archive' is RUNNING — archives are clone sources, never boot targets"
                else
                    _ok "archive '$archive' registered, stopped"
                fi
            else
                _warn "archive '$archive' not registered (recovery unavailable until the drive is mounted + VM registered)"
            fi
        fi
    done

    echo "== doctor: $fails problem(s), $warns warning(s) =="
    [ "$fails" -eq 0 ]
}
