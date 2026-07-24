# shellcheck shell=bash
# vmkit host resources: macOS memory / swap / load introspection so the
# one-VM-at-a-time handoff hands memory cleanly from one guest to the next
# instead of thrashing the host into an OOM (see docs/FAILURES.md, issues #3-#6).
#
# All memory values are MB (integers). On a host without the macOS tools these
# functions print nothing and callers treat that as "unknown -> skip the check"
# so vmkit stays usable off a Parallels host.

# Available host memory in MB: pages the kernel can hand to a booting guest
# without swapping — free + inactive + speculative + purgeable. (Active/wired
# are in use; counting them would over-promise and defeat the whole guard.)
host_free_mb() {
    command -v vm_stat >/dev/null 2>&1 || return 0
    vm_stat 2>/dev/null | awk '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) }
        /^Pages free:/         { free  = $3 }
        /^Pages inactive:/     { inact = $3 }
        /^Pages speculative:/  { spec  = $3 }
        /^Pages purgeable:/    { purge = $3 }
        END {
            if (ps == "") ps = 4096
            gsub(/\./, "", free); gsub(/\./, "", inact)
            gsub(/\./, "", spec); gsub(/\./, "", purge)
            printf "%d", (free + inact + spec + purge) * ps / 1048576
        }'
}

# Total physical RAM in MB.
host_total_mb() {
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null)" || return 0
    [ -n "$bytes" ] && printf '%d' "$(( bytes / 1048576 ))"
}

# Swap currently in use, MB (rounded). Empty if unavailable.
host_swap_used_mb() {
    sysctl -n vm.swapusage 2>/dev/null \
        | sed -nE 's/.*used = ([0-9]+)\.[0-9]+M.*/\1/p'
}

# 1-minute load average. Empty if unavailable.
host_loadavg() {
    sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'
}

# Configured RAM (MB) of a Parallels VM, parsed from `prlctl list -i`
# ("  memory size=4096Mb auto=off"). Empty if unknown.
vm_ram_mb() { # <vm>
    prlctl list -i "$1" 2>/dev/null \
        | sed -nE 's/.*memory size=([0-9]+)Mb.*/\1/p' | head -1
}

# One-line host resource snapshot at a phase boundary (issue #4). On by default;
# set VMKIT_HOST_SNAPSHOT=0 to silence. No-op when memory can't be read.
host_snapshot() {
    [ "${VMKIT_HOST_SNAPSHOT:-1}" = 0 ] && return 0
    local free total swap load line
    free="$(host_free_mb)"; [ -z "$free" ] && return 0
    total="$(host_total_mb)"; swap="$(host_swap_used_mb)"; load="$(host_loadavg)"
    line=">> host: free ${free} MB"
    [ -n "$total" ] && line="$line / ${total} MB"
    [ -n "$swap" ] && line="$line, swap ${swap} MB used"
    [ -n "$load" ] && line="$line, load ${load}"
    echo "$line"
}

# Memory needed (MB) to boot <vm>: its configured RAM plus host headroom for the
# test harness itself. Headroom is VMKIT_MEM_HEADROOM_MB (default 2048).
host_mem_need_mb() { # <vm>
    local ram; ram="$(vm_ram_mb "$1")"; [ -z "$ram" ] && ram=0
    printf '%d' "$(( ram + ${VMKIT_MEM_HEADROOM_MB:-2048} ))"
}

# Issue #3: after the sibling guest is stopped, block until host free memory has
# actually recovered enough to boot the target guest, so we don't snapshot-switch
# straight into an OOM. Loud heartbeat, hard timeout, and a diagnostic on failure
# instead of a silent multi-minute thrash. VMKIT_MEM_WAIT_TIMEOUT secs (default
# 180). Returns 1 (and prints the current reading) if memory never recovers.
host_mem_settle() { # <target-vm>
    local vm="$1" now need secs elapsed
    now="$(host_free_mb)"; [ -z "$now" ] && return 0   # non-macOS -> skip
    need="$(host_mem_need_mb "$vm")"
    secs="${VMKIT_MEM_WAIT_TIMEOUT:-180}"
    elapsed=0
    while [ "$elapsed" -lt "$secs" ]; do
        now="$(host_free_mb)"
        [ -z "$now" ] && return 0
        if [ "$now" -ge "$need" ]; then
            [ "$elapsed" -gt 0 ] \
                && echo ">> host memory recovered: ${now} MB free (needed ${need} MB) after ${elapsed}s"
            return 0
        fi
        if [ "$elapsed" -eq 0 ]; then
            echo ">> waiting for host memory to free for '$vm': ${now} MB free, need ${need} MB (${secs}s budget)..."
        elif [ $(( elapsed % 30 )) -eq 0 ]; then
            echo ">> still waiting for memory: ${now} MB free / ${need} MB needed (${elapsed}s/${secs}s)"
        fi
        sleep 5; elapsed=$(( elapsed + 5 ))
    done
    now="$(host_free_mb)"
    echo "vmkit: host still has only ${now} MB free after ${secs}s (need ${need} MB for '$vm') — refusing to boot into an OOM." >&2
    echo "       Free memory, or raise VMKIT_MEM_WAIT_TIMEOUT / lower VMKIT_MEM_HEADROOM_MB in host.conf." >&2
    return 1
}
