# vmkit

Parallels VM system-test control plane for macOS hosts. Test **real
installers, trust stores, network devices, and upgrade paths** on pristine
end-user guest VMs (Windows / Linux / macOS), with the operating discipline
that makes that reliable:

- **Golden-snapshot ladder** — `golden` (powered-off, human-made, pristine) →
  `ready` (booted once) → `built` (provisioned); every test starts from a
  revert, never from leftover state.
- **Internal-disk-only boot policy** — archive copies on an external drive are
  clone sources, never boot targets; CI hard-fails rather than silently
  booting off slow storage.
- **Guarded guest execution** — host-side timeouts, guest straggler cleanup,
  revert-collapse recovery, one-VM-at-a-time.
- **Cache-first provisioning** — downloads happen once into an offline cache;
  the test path only reverts snapshots (metered-link safe).
- **Encoded guest quirks** — SYSTEM/UNC on Windows, base64-push transport on
  macOS, headless-OS capability limits (docs/CAPABILITIES.md).

The division of labor is strict and documented: a human installs the OS +
Parallels Guest Tools and takes one golden snapshot per VM
([docs/HUMAN-SETUP.md](docs/HUMAN-SETUP.md)); vmkit owns everything after.
Every failure mode this harness has hit is cataloged with its guard in
[docs/FAILURES.md](docs/FAILURES.md).

## Install

```sh
brew install portzeronetwork/portzero/vmkit
vmkit init-host          # then edit ~/.config/vmkit/host.conf
vmkit doctor             # validate the machine against the contract
```

## Use in a repo

```sh
cd my-repo
vmkit init               # writes ./vmkit.conf — define flavors there
vmkit test linux smoke   # reset to "built", run one flavor on one platform
vmkit series lifecycle   # every configured platform in series + summary
```

### One-time guest provisioning

Some guest config must **survive** the per-test reset — a toolchain, Homebrew,
a Windows Defender exclusion for unsigned/network-sourced installers. It can't
live in a flavor script (every test reverts to `built` first); it has to be
baked into the checkpoint itself. `vmkit provision` is that
reset → run-a-guest-script → re-checkpoint dance as one reusable primitive,
with "preserve the pristine baseline once" built in:

```sh
vmkit provision windows vmtest/scripts/windows-add-defender-exclusions.ps1 \
    --checkpoint built --label defender    # bakes the exclusion into "built"
```

See [docs/PROVISIONING.md](docs/PROVISIONING.md) for the full model (anchors,
preservation, failure handling).

### Host-side desktop control (agent / manual UI)

Drive a running guest's interactive desktop from the host (no guest agent):

```sh
vmkit screenshot windows                 # PNG path printed on stdout
vmkit key windows win+r                  # combos: ctrl+c, alt+tab, enter, …
vmkit type windows "notepad"
vmkit key windows enter
vmkit mouse windows click                # buttons + relative nudge only
```

This is a vision loop substrate (screenshot → decide → key/type). Absolute
click-at-(x,y) and accessibility trees need a guest agent (planned next).

Run `vmkit init-agents` to generate `.instructions/vmkit.md` (VM inventory,
snapshot ladder, test flavors, archive drive) and wire it the same way
[agent-toolbox instruction modules](https://github.com/portzeronetwork/agent-toolbox)
do: one `@.instructions/vmkit.md` line in `AGENTS.md`, and `CLAUDE.md` as a
thin `@AGENTS.md` pointer. No marker blocks in the root agent files.

Flavor scripts live in your repo, run *inside* the guests, and speak a tiny
greppable protocol (`PHASE=… ok=true|false|SKIP`, final `RESULT=PASS|FAIL|SKIP`).
Copy the helpers from `$(vmkit guest-lib)/assert.sh|.ps1` into your repo's
`vmtest/scripts/lib/` and source them.

## Fleet management

```sh
vmkit adopt              # new/cleaned machine: clone archive VMs -> internal disk
vmkit sync macos         # mirror an internal VM bundle out to its archive copy
vmkit list               # VMs + snapshot ladders
```

## CI

Run the self-hosted runner **as a service** (never interactive `run.sh`), give
the workflow a `concurrency` group that queues (never cancels) VM jobs, stage
CI-built artifacts where `VMKIT_ARTIFACT_*` points, and call
`vmkit series <flavor>`. Split triggers so PRs run a fast smoke and pushes run
the full pristine-machine suite.

## Docs

- [HUMAN-SETUP.md](docs/HUMAN-SETUP.md) — the human/machine contract, new-machine
  bootstrap (including Apple Silicon arch migration)
- [CAPABILITIES.md](docs/CAPABILITIES.md) — what guest scripts can/can't do per OS
- [FAILURES.md](docs/FAILURES.md) — failure catalog: every known failure class → its guard
- [PROVISIONING.md](docs/PROVISIONING.md) — bake one-time guest OS config into a checkpoint (`vmkit provision`)
