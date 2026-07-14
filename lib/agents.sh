# shellcheck shell=bash
# vmkit init-agents: seed AGENTS.md / CLAUDE.md with an include pointing at
# .rules/vmkit.md, and generate that file so AI coding agents working in a
# vmkit-tested repo know the VM inventory, snapshot ladder, and test flavors
# without having to reverse-engineer vmkit.conf/host.conf themselves.

# Best-effort per-platform VM inventory line, read from host.conf. Silent if
# the platform has no VM configured.
_agents_vm_line() { # <platform> (host.conf already sourced by caller)
    local p="$1" key akey
    key="VMKIT_VM_$(echo "$p" | tr '[:lower:]' '[:upper:]')"
    akey="${key}_ARCHIVE"
    [ -n "${!key:-}" ] || return 0
    if [ -n "${!akey:-}" ]; then
        printf -- '- **%s**: `%s` (archive: `%s`)\n' "$p" "${!key}" "${!akey}"
    else
        printf -- '- **%s**: `%s`\n' "$p" "${!key}"
    fi
}

_agents_vm_section() {
    local host_conf="${VMKIT_HOST_CONF:-$HOME/.config/vmkit/host.conf}"
    if [ ! -f "$host_conf" ]; then
        echo "- No \`host.conf\` on this machine yet. Run \`vmkit init-host\` then \`vmkit doctor\`;" \
             "VM names live in \`~/.config/vmkit/host.conf\` (machine-specific, never committed)."
        return
    fi
    (
        # shellcheck source=/dev/null
        . "$host_conf"
        local p line any=0
        for p in windows linux macos; do
            line="$(_agents_vm_line "$p")"
            if [ -n "$line" ]; then printf '%s\n' "$line"; any=1; fi
        done
        if [ "$any" -eq 0 ]; then echo "- \`host.conf\` exists but no platforms are configured yet."; fi
    )
}

_agents_snapshot_section() {
    local host_conf="${VMKIT_HOST_CONF:-$HOME/.config/vmkit/host.conf}"
    local prefix="vmkit"
    if [ -f "$host_conf" ]; then
        prefix="$(
            # shellcheck source=/dev/null
            . "$host_conf"
            printf '%s' "${VMKIT_SNAP_PREFIX:-vmkit}"
        )"
    fi
    printf -- '- Prefix on this machine: `%s` (set by `VMKIT_SNAP_PREFIX` in host.conf)\n' "$prefix"
    printf -- '- Ladder: `%s-golden` (human-made, powered off, pristine) -> `%s-ready` (booted once) -> `%s-built` (provisioned; what `vmkit test` reverts to)\n' "$prefix" "$prefix" "$prefix"
    printf -- '- Additional checkpoints via `vmkit checkpoint <platform> <name>` -> `%s-<name>`\n' "$prefix"
}

_agents_archive_section() {
    local host_conf="${VMKIT_HOST_CONF:-$HOME/.config/vmkit/host.conf}"
    if [ ! -f "$host_conf" ]; then
        echo "- Not known from this checkout; see \`~/.config/vmkit/host.conf\` on the test machine."
        return
    fi
    (
        # shellcheck source=/dev/null
        . "$host_conf"
        if [ -n "${VMKIT_ARCHIVE_DRIVE:-}" ]; then
            printf -- '- Archive drive: `%s` (clone source only — never a boot target)\n' "$VMKIT_ARCHIVE_DRIVE"
        else
            echo "- Not configured on this machine (optional; see \`VMKIT_ARCHIVE_DRIVE\` in host.conf)."
        fi
        if [ -n "${VMKIT_CACHE_DIR:-}" ]; then printf -- '- Offline download cache: `%s`\n' "$VMKIT_CACHE_DIR"; fi
    )
}

# Find this repo's vmkit.conf the same way vmkit_load_repo_conf does, without
# the hard failure — init-agents must work before a repo has one.
_agents_find_repo_conf() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/vmkit.conf" ] && { echo "$dir/vmkit.conf"; return 0; }
        [ -f "$dir/vmtest/vmkit.conf" ] && { echo "$dir/vmtest/vmkit.conf"; return 0; }
        dir="$(dirname "$dir")"
    done
    return 1
}

_agents_flavor_section() {
    local conf
    if ! conf="$(_agents_find_repo_conf)"; then
        echo "- No \`vmkit.conf\` in this repo yet. Run \`vmkit init\` to create one, then define flavors there."
        return
    fi
    (
        # shellcheck source=/dev/null
        . "$conf"
        printf -- '- Config: `%s`\n' "${conf#"$PWD"/}"
        printf -- '- Project: `%s`\n' "${VMKIT_PROJECT:-unset}"
        grep -oE '^VMKIT_FLAVOR_[A-Z0-9_]+_(WINDOWS|LINUX|MACOS)=' "$conf" \
            | sed -E 's/^VMKIT_FLAVOR_(.*)_(WINDOWS|LINUX|MACOS)=$/\1/' \
            | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u \
            | while read -r f; do printf -- '- Flavor `%s`: `vmkit test <platform> %s`\n' "$f" "$f"; done
        true
    )
}

init_agent_docs() {
    local force="${1:-}"
    mkdir -p .rules
    if [ -f .rules/vmkit.md ] && [ "$force" != "--force" ]; then
        echo "vmkit: .rules/vmkit.md already exists — leaving it as-is (use --force to regenerate)" >&2
        _agents_ensure_include AGENTS.md "See [.rules/vmkit.md](.rules/vmkit.md) for how vmkit (Parallels VM system testing) is used in this repo."
        _agents_ensure_include CLAUDE.md "@.rules/vmkit.md"
        return
    fi

    local vm_section snap_section archive_section flavor_section
    vm_section="$(_agents_vm_section)"
    snap_section="$(_agents_snapshot_section)"
    archive_section="$(_agents_archive_section)"
    flavor_section="$(_agents_flavor_section)"

    cat > .rules/vmkit.md <<EOF
# vmkit in this repo

This repo uses [vmkit](https://github.com/portzeronetwork/vmkit) — a
Parallels VM system-test control plane — to test real installers, agents,
and upgrade paths on pristine guest VMs (Windows / Linux / macOS) instead of
mocking OS behavior. Test scripts run *inside* the guests via \`prlctl exec\`,
resetting to a known-good snapshot before every run.

Two config files, two lifetimes:
- **Host inventory** (per test machine, NOT committed):
  \`~/.config/vmkit/host.conf\` — VM names, arch, snapshot prefix, archive
  drive.
- **Repo test config** (committed): \`./vmkit.conf\` or
  \`./vmtest/vmkit.conf\` — project name, test flavors, env/artifact
  plumbing.

## VM inventory (this machine)

$vm_section

## Snapshot ladder

$snap_section

## Software installed in each guest

<!-- Document what's provisioned on the "-built" snapshot per platform, e.g.
     runtimes, browsers, agents under test, trust store state. vmkit doesn't
     track this — it's whatever your provisioning scripts installed before
     \`vmkit checkpoint <platform> built\` was taken. Keep this in sync when
     provisioning changes. -->

- windows:
- linux:
- macos:

## External / archive drive

$archive_section

## Test flavors defined in this repo

$flavor_section

## Common commands

\`\`\`
vmkit doctor                       # validate this host against the contract
vmkit list                         # VMs + snapshot ladders
vmkit up <platform>                # golden -> boot -> snapshot "-ready"
vmkit test <platform> <flavor>     # reset to "-built", run one flavor
vmkit series <flavor>              # every configured platform + summary
vmkit run <platform> <script>      # run a repo script inside the guest
vmkit exec <platform> <cmd...>     # raw command in the guest
\`\`\`

## Notes for AI agents working in this repo

- Guest scripts speak a greppable protocol: \`PHASE=<name> ok=true|false|SKIP\`
  lines, ending with \`RESULT=PASS|FAIL|SKIP\`.
- Never hand-edit or assume \`~/.config/vmkit/host.conf\` state in repo code —
  it's machine-specific and never committed; repo code should only depend on
  \`vmkit.conf\`.
- One VM runs at a time (vmkit enforces this) — don't add code that boots or
  reverts VMs outside vmkit's commands.
- After changing a flavor script, re-run with \`vmkit test <platform>
  <flavor>\` — vmkit reverts to the \`-built\` snapshot automatically, so
  there's no leftover state between runs.
- See vmkit's own \`docs/CAPABILITIES.md\` (in the vmkit repo) for the guest
  capability matrix (what \`prlctl exec\` can/can't do per OS) before writing
  new guest-side logic.
EOF
    echo "wrote .rules/vmkit.md"

    _agents_ensure_include AGENTS.md "See [.rules/vmkit.md](.rules/vmkit.md) for how vmkit (Parallels VM system testing) is used in this repo."
    _agents_ensure_include CLAUDE.md "@.rules/vmkit.md"
}

# Idempotently point an agent-instructions file at .rules/vmkit.md: create the
# file with just that line if it doesn't exist, append if it exists and
# doesn't already reference .rules/vmkit.md, otherwise leave it alone.
_agents_ensure_include() { # <file> <line-to-add>
    local file="$1" line="$2"
    if [ ! -f "$file" ]; then
        printf '%s\n' "$line" > "$file"
        echo "wrote $file"
        return
    fi
    if grep -qF '.rules/vmkit.md' "$file"; then
        echo "$file already references .rules/vmkit.md — left unchanged"
        return
    fi
    { echo; printf '%s\n' "$line"; } >> "$file"
    echo "updated $file"
}
