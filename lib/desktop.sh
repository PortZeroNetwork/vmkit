# shellcheck shell=bash
# vmkit desktop: host-side guest UI observation and input (no guest agent).
#
# Uses Parallels host APIs only:
#   prlctl capture          → PNG screenshot of the VM framebuffer
#   prlctl send-key-event   → keyboard (and limited mouse-button / relative-
#                             move) events into the virtual input devices
#
# This is enough for a vision-driven agent loop (screenshot → decide → key/type).
# Not available host-side (planned via guest agent next):
#   - absolute mouse position / click-at-(x,y)
#   - accessibility trees (UIA / AX / AT-SPI)
#   - reliable video capture CLI
#
# Input hits the virtual console. For GUI work the guest should be at a
# logged-in interactive desktop (auto-login); headless SYSTEM/root exec
# context is a different path (vmkit run/exec/test).

# Default inter-key delay for type / multi-key sequences (ms).
VMKIT_KEY_DELAY="${VMKIT_KEY_DELAY:-40}"

# --- running-VM guard ---------------------------------------------------------
_desktop_require_running() { # <vm>
    local vm="$1"
    if ! is_running "$vm"; then
        echo "vmkit: VM '$vm' is not running — start it first (vmkit up|reset)" >&2
        return 1
    fi
}

# --- key name → Parallels virtual key code ------------------------------------
# Codes from Parallels Desktop send-key-event key table (PRL_KEY_*).
# Case-insensitive names; also accepts bare decimals and "code:N".
_desktop_key_code() { # <name> → prints code, or fails
    local n
    n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$n" in
        code:*) n="${n#code:}" ;;
    esac
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        printf '%s' "$n"; return 0
    fi
    case "$n" in
        # modifiers
        ctrl|control|lctrl|left-ctrl|left_ctrl|leftcontrol) echo 37 ;;
        rctrl|right-ctrl|right_ctrl|rightcontrol)           echo 109 ;;
        alt|option|lalt|left-alt|left_alt|leftalt)          echo 64 ;;
        ralt|right-alt|right_alt|rightalt|altgr)            echo 113 ;;
        shift|lshift|left-shift|left_shift|leftshift)       echo 50 ;;
        rshift|right-shift|right_shift|rightshift)          echo 62 ;;
        win|meta|cmd|command|super|lwin|left-win|left_win|gui)
                                                            echo 115 ;;
        rwin|right-win|right_win)                           echo 116 ;;
        # navigation / editing
        esc|escape)          echo 9 ;;
        backspace|bksp|bs)   echo 22 ;;
        tab)                 echo 23 ;;
        enter|return|ret)    echo 36 ;;
        space|spc)           echo 65 ;;
        caps|capslock|caps-lock|caps_lock) echo 66 ;;
        print|printscreen|prtsc) echo 92 ;;
        home)                echo 97 ;;
        up|arrow-up|arrow_up)       echo 98 ;;
        pageup|page-up|pgup) echo 99 ;;
        left|arrow-left|arrow_left) echo 100 ;;
        right|arrow-right|arrow_right) echo 102 ;;
        end)                 echo 103 ;;
        down|arrow-down|arrow_down) echo 104 ;;
        pagedown|page-down|pgdn|pgdown) echo 105 ;;
        insert|ins)          echo 106 ;;
        delete|del)          echo 107 ;;
        menu|app|apps)       echo 117 ;;
        # letters
        a) echo 38 ;; b) echo 56 ;; c) echo 54 ;; d) echo 40 ;;
        e) echo 26 ;; f) echo 41 ;; g) echo 42 ;; h) echo 43 ;;
        i) echo 31 ;; j) echo 44 ;; k) echo 45 ;; l) echo 46 ;;
        m) echo 58 ;; n) echo 57 ;; o) echo 32 ;; p) echo 33 ;;
        q) echo 24 ;; r) echo 27 ;; s) echo 39 ;; t) echo 28 ;;
        u) echo 30 ;; v) echo 55 ;; w) echo 25 ;; x) echo 53 ;;
        y) echo 29 ;; z) echo 52 ;;
        # digits (top row)
        1) echo 10 ;; 2) echo 11 ;; 3) echo 12 ;; 4) echo 13 ;; 5) echo 14 ;;
        6) echo 15 ;; 7) echo 16 ;; 8) echo 17 ;; 9) echo 18 ;; 0) echo 19 ;;
        # function keys
        f1) echo 67 ;; f2) echo 68 ;; f3) echo 69 ;; f4) echo 70 ;;
        f5) echo 71 ;; f6) echo 72 ;; f7) echo 73 ;; f8) echo 74 ;;
        f9) echo 75 ;; f10) echo 76 ;; f11) echo 95 ;; f12) echo 96 ;;
        f13) echo 152 ;; f14) echo 153 ;; f15) echo 154 ;; f16) echo 155 ;;
        f17) echo 156 ;; f18) echo 157 ;; f19) echo 158 ;; f20) echo 159 ;;
        f21) echo 160 ;; f22) echo 161 ;; f23) echo 162 ;; f24) echo 163 ;;
        # symbols by name
        minus|hyphen|dash)   echo 20 ;;
        equal|equals)        echo 21 ;;
        leftbracket|lbracket|left-bracket)   echo 34 ;;
        rightbracket|rbracket|right-bracket) echo 35 ;;
        semicolon)           echo 47 ;;
        quote|apostrophe)    echo 48 ;;
        tilda|tilde|grave|backtick) echo 49 ;;
        backslash)           echo 51 ;;
        comma)               echo 59 ;;
        dot|period)          echo 60 ;;
        slash|forwardslash)  echo 61 ;;
        # mouse (virtual device events exposed via the same key table)
        click|lbutton|left-button|left_button|mouse1)
                                                            echo 178 ;;
        middle-click|mbutton|middle-button|middle_button|mouse2)
                                                            echo 179 ;;
        right-click|rbutton|right-button|right_button|mouse3)
                                                            echo 180 ;;
        move-up-left|move_up_left)     echo 181 ;;
        move-up|move_up)               echo 182 ;;
        move-up-right|move_up_right)   echo 183 ;;
        move-left|move_left)           echo 184 ;;
        move-right|move_right)         echo 185 ;;
        move-down-left|move_down_left) echo 186 ;;
        move-down|move_down)           echo 187 ;;
        move-down-right|move_down_right) echo 188 ;;
        wheel-up|wheel_up|scroll-up)   echo 189 ;;
        wheel-down|wheel_down|scroll-down) echo 190 ;;
        wheel-left|wheel_left)         echo 191 ;;
        wheel-right|wheel_right)       echo 192 ;;
        *)
            echo "vmkit: unknown key '$1' (see docs/CAPABILITIES.md host desktop)" >&2
            return 1
            ;;
    esac
}

# --- JSON event stream → prlctl -----------------------------------------------
# Send a JSON array of events on stdin to the VM. Empty array is a no-op.
_desktop_send_json() { # <vm>
    local vm="$1" payload compact
    payload="$(cat)"
    compact="$(printf '%s' "$payload" | tr -d '[:space:]')"
    if [ -z "$compact" ] || [ "$compact" = "[]" ]; then
        return 0
    fi
    printf '%s\n' "$payload" | prlctl send-key-event "$vm" --json
}

# Append one JSON object line into a temp builder file (one object per line).
# Final assembly wraps them in [...]. Avoids fragile string concat for commas.
_desktop_events_begin() { # sets DESKTOP_EVENTS_FILE
    DESKTOP_EVENTS_FILE="$(mktemp)"
}

_desktop_events_add() { # <json-object-without-trailing-comma>
    printf '%s\n' "$1" >> "$DESKTOP_EVENTS_FILE"
}

_desktop_events_send() { # <vm>
    local vm="$1" first=1 line
    {
        printf '['
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            if [ "$first" -eq 1 ]; then
                first=0
            else
                printf ','
            fi
            printf '%s' "$line"
        done < "$DESKTOP_EVENTS_FILE"
        printf ']\n'
    } | _desktop_send_json "$vm"
    rm -f "$DESKTOP_EVENTS_FILE"
    unset DESKTOP_EVENTS_FILE
}

_desktop_events_abort() {
    [ -n "${DESKTOP_EVENTS_FILE:-}" ] && rm -f "$DESKTOP_EVENTS_FILE"
    unset DESKTOP_EVENTS_FILE
}

# Full press+release (default prlctl behavior when event is omitted).
_desktop_ev_tap() { # <code> [delay-ms]
    local code="$1" delay="${2:-$VMKIT_KEY_DELAY}"
    _desktop_events_add "{\"key\": ${code}, \"delay\": ${delay}}"
}

_desktop_ev_press() { # <code> [delay-ms]
    local code="$1" delay="${2:-$VMKIT_KEY_DELAY}"
    _desktop_events_add "{\"key\": ${code}, \"event\": \"press\", \"delay\": ${delay}}"
}

_desktop_ev_release() { # <code> [delay-ms]
    local code="$1" delay="${2:-$VMKIT_KEY_DELAY}"
    _desktop_events_add "{\"key\": ${code}, \"event\": \"release\", \"delay\": ${delay}}"
}

# Expand one token: "enter", "ctrl+c", "shift+tab", "win+r", "code:36"
_desktop_add_spec() { # <spec>
    local spec="$1" part code i
    local -a parts=()

    IFS='+' read -r -a parts <<< "$spec"
    if [ "${#parts[@]}" -eq 0 ]; then
        echo "vmkit: empty key spec" >&2
        return 1
    fi
    for i in "${!parts[@]}"; do
        parts[$i]="$(printf '%s' "${parts[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    done

    if [ "${#parts[@]}" -eq 1 ]; then
        code="$(_desktop_key_code "${parts[0]}")" || return 1
        _desktop_ev_tap "$code"
        return 0
    fi

    # mods = all but last; primary = last
    local -a mods=("${parts[@]:0:${#parts[@]}-1}")
    local primary="${parts[${#parts[@]}-1]}"
    [ -n "$primary" ] || { echo "vmkit: key spec '$spec' has no primary key" >&2; return 1; }

    for part in "${mods[@]}"; do
        code="$(_desktop_key_code "$part")" || return 1
        _desktop_ev_press "$code"
    done
    code="$(_desktop_key_code "$primary")" || return 1
    _desktop_ev_tap "$code"
    for (( i=${#mods[@]}-1; i>=0; i-- )); do
        code="$(_desktop_key_code "${mods[$i]}")" || return 1
        _desktop_ev_release "$code"
    done
}

# --- character → events (US QWERTY) -------------------------------------------
_desktop_add_char() { # <single-char>
    local c="$1" code shift=0

    case "$c" in
        [[:lower:]])
            code="$(_desktop_key_code "$c")" || return 1
            _desktop_ev_tap "$code"
            return 0
            ;;
        [[:upper:]])
            code="$(_desktop_key_code "$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')")" || return 1
            _desktop_ev_press 50   # left shift
            _desktop_ev_tap "$code"
            _desktop_ev_release 50
            return 0
            ;;
        [0-9])
            code="$(_desktop_key_code "$c")" || return 1
            _desktop_ev_tap "$code"
            return 0
            ;;
        ' ')   _desktop_ev_tap 65; return 0 ;;
        $'\t') _desktop_ev_tap 23; return 0 ;;
        $'\n'|$'\r') _desktop_ev_tap 36; return 0 ;;
        # unshifted punctuation
        '-') code=20 ;;
        '=') code=21 ;;
        '[') code=34 ;;
        ']') code=35 ;;
        ';') code=47 ;;
        \')  code=48 ;;
        '`') code=49 ;;
        '\\') code=51 ;;
        ',') code=59 ;;
        '.') code=60 ;;
        '/') code=61 ;;
        # shifted punctuation
        '!') code=10; shift=1 ;;
        '@') code=11; shift=1 ;;
        '#') code=12; shift=1 ;;
        '$') code=13; shift=1 ;;
        '%') code=14; shift=1 ;;
        '^') code=15; shift=1 ;;
        '&') code=16; shift=1 ;;
        '*') code=17; shift=1 ;;
        '(') code=18; shift=1 ;;
        ')') code=19; shift=1 ;;
        '_') code=20; shift=1 ;;
        '+') code=21; shift=1 ;;
        '{') code=34; shift=1 ;;
        '}') code=35; shift=1 ;;
        ':') code=47; shift=1 ;;
        '"') code=48; shift=1 ;;
        '~') code=49; shift=1 ;;
        '|') code=51; shift=1 ;;
        '<') code=59; shift=1 ;;
        '>') code=60; shift=1 ;;
        '?') code=61; shift=1 ;;
        *)
            printf 'vmkit: cannot type character %q (US ASCII only in host type)\n' "$c" >&2
            return 1
            ;;
    esac

    if [ "$shift" -eq 1 ]; then
        _desktop_ev_press 50
        _desktop_ev_tap "$code"
        _desktop_ev_release 50
    else
        _desktop_ev_tap "$code"
    fi
}

# --- public commands ----------------------------------------------------------

# Capture the VM framebuffer to a PNG. Prints the absolute path on stdout.
# Usage: vmkit screenshot <platform|vm> [path.png]
cmd_screenshot() { # <vm> [outfile]
    local vm="$1" out="${2:-}"
    _desktop_require_running "$vm" || return 1

    if [ -z "$out" ]; then
        local dir="${VMKIT_SCREENSHOT_DIR:-${TMPDIR:-/tmp}/vmkit-screenshots}"
        mkdir -p "$dir"
        local safe
        safe="$(printf '%s' "$vm" | tr -c 'A-Za-z0-9._-' '_')"
        out="${dir}/${safe}-$(date +%Y%m%d-%H%M%S).png"
    else
        mkdir -p "$(dirname "$out")"
    fi

    case "$out" in
        /*) ;;
        *) out="$(pwd)/$out" ;;
    esac

    echo ">> capturing screenshot of '$vm' → $out" >&2
    prlctl capture "$vm" --file "$out" || {
        echo "vmkit: prlctl capture failed" >&2
        return 1
    }
    if [ ! -f "$out" ]; then
        echo "vmkit: capture reported success but file missing: $out" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# Send one or more key specs to the VM.
# Usage: vmkit key <platform|vm> <spec> [spec...]
#   specs: enter | tab | ctrl+c | win+r | shift+tab | code:36 | click
#   --down <name> / --up <name>  hold or release a key
#   --json   read a raw JSON event array from stdin (prlctl format)
cmd_key() { # <vm> [opts] <specs...>
    local vm="$1"; shift
    _desktop_require_running "$vm" || return 1

    if [ "${1:-}" = "--json" ]; then
        _desktop_send_json "$vm"
        return $?
    fi

    if [ $# -eq 0 ]; then
        echo "usage: vmkit key <platform|vm> <spec> [spec...]" >&2
        echo "       vmkit key <platform|vm> --down|--up <name>" >&2
        echo "       vmkit key <platform|vm> --json   # JSON array on stdin" >&2
        return 2
    fi

    if [ "$1" = "--down" ] || [ "$1" = "--up" ]; then
        local mode="$1" name="${2:-}" code
        [ -n "$name" ] || { echo "vmkit: $mode requires a key name" >&2; return 2; }
        code="$(_desktop_key_code "$name")" || return 1
        _desktop_events_begin
        if [ "$mode" = "--down" ]; then
            _desktop_ev_press "$code"
        else
            _desktop_ev_release "$code"
        fi
        _desktop_events_send "$vm"
        return $?
    fi

    _desktop_events_begin
    local spec
    for spec in "$@"; do
        if ! _desktop_add_spec "$spec"; then
            _desktop_events_abort
            return 1
        fi
    done
    _desktop_events_send "$vm"
}

# Type a string into the VM (US QWERTY, printable ASCII + tab/newline).
# Usage: vmkit type <platform|vm> <text...>
#   Remaining args are joined with spaces.
cmd_type() { # <vm> <text...>
    local vm="$1"; shift
    _desktop_require_running "$vm" || return 1

    if [ $# -eq 0 ]; then
        echo "usage: vmkit type <platform|vm> <text...>" >&2
        return 2
    fi

    local text="$*"
    local i c
    _desktop_events_begin
    for (( i=0; i<${#text}; i++ )); do
        c="${text:i:1}"
        if ! _desktop_add_char "$c"; then
            _desktop_events_abort
            return 1
        fi
    done
    _desktop_events_send "$vm"
}

# Limited host-side mouse via Parallels virtual mouse key codes.
# Absolute positioning is NOT available without a guest agent.
#
# Usage:
#   vmkit mouse <platform|vm> click|right-click|middle-click
#   vmkit mouse <platform|vm> wheel up|down|left|right [count]
#   vmkit mouse <platform|vm> nudge up|down|left|right|up-left|... [count]
cmd_mouse() { # <vm> <action> [args...]
    local vm="$1"; shift
    _desktop_require_running "$vm" || return 1

    local action="${1:-}"
    [ $# -gt 0 ] && shift
    local count=1 i dir code code_name

    case "$action" in
        click|left-click|left)
            cmd_key "$vm" click
            ;;
        right-click|right)
            cmd_key "$vm" right-click
            ;;
        middle-click|middle)
            cmd_key "$vm" middle-click
            ;;
        wheel)
            dir="${1:-}"; count="${2:-1}"
            case "$dir" in
                up)    code_name=wheel-up ;;
                down)  code_name=wheel-down ;;
                left)  code_name=wheel-left ;;
                right) code_name=wheel-right ;;
                *)
                    echo "usage: vmkit mouse <vm> wheel up|down|left|right [count]" >&2
                    return 2
                    ;;
            esac
            if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
                echo "vmkit: wheel count must be a positive integer" >&2
                return 2
            fi
            _desktop_events_begin
            for (( i=0; i<count; i++ )); do
                code="$(_desktop_key_code "$code_name")" || { _desktop_events_abort; return 1; }
                _desktop_ev_tap "$code"
            done
            _desktop_events_send "$vm"
            ;;
        nudge|move)
            dir="${1:-}"; count="${2:-1}"
            case "$dir" in
                up) code_name=move-up ;;
                down) code_name=move-down ;;
                left) code_name=move-left ;;
                right) code_name=move-right ;;
                up-left|upleft) code_name=move-up-left ;;
                up-right|upright) code_name=move-up-right ;;
                down-left|downleft) code_name=move-down-left ;;
                down-right|downright) code_name=move-down-right ;;
                *)
                    echo "usage: vmkit mouse <vm> nudge <dir> [count]" >&2
                    echo "  dir: up down left right up-left up-right down-left down-right" >&2
                    echo "note: relative only — absolute click-at-(x,y) needs the guest agent" >&2
                    return 2
                    ;;
            esac
            if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
                echo "vmkit: nudge count must be a positive integer" >&2
                return 2
            fi
            _desktop_events_begin
            for (( i=0; i<count; i++ )); do
                code="$(_desktop_key_code "$code_name")" || { _desktop_events_abort; return 1; }
                _desktop_ev_tap "$code" 10
            done
            _desktop_events_send "$vm"
            ;;
        at|click-at|move-to)
            echo "vmkit: absolute mouse positioning is not available host-side" >&2
            echo "       (Parallels exposes relative move / buttons only)." >&2
            echo "       Guest agent will provide click-at-(x,y) and a11y hit-testing." >&2
            return 2
            ;;
        ""|-h|--help)
            echo "usage: vmkit mouse <platform|vm> click|right-click|middle-click" >&2
            echo "       vmkit mouse <platform|vm> wheel up|down|left|right [count]" >&2
            echo "       vmkit mouse <platform|vm> nudge <dir> [count]" >&2
            echo "absolute click-at-(x,y): not available without guest agent" >&2
            return 2
            ;;
        *)
            echo "vmkit: unknown mouse action '$action'" >&2
            echo "       try: click | right-click | middle-click | wheel | nudge" >&2
            return 2
            ;;
    esac
}
