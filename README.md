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
- **Encoded guest quirks** — SYSTEM/UNC on Windows, tar.gz-push (+ keepalive)
  transport on macOS (shared folder is TCC-blocked under headless exec),
  headless-OS capability limits (docs/CAPABILITIES.md).

The division of labor is strict and documented: a human installs the OS +
Parallels Guest Tools and takes one golden snapshot per VM
([docs/HUMAN-SETUP.md](docs/HUMAN-SETUP.md)); vmkit owns everything after.
Every failure mode this harness has hit is cataloged with its guard in
[docs/FAILURES.md](docs/FAILURES.md).

## Install

vmkit is internal and **not distributed through Homebrew** — it is not part of
the Port Zero product and must not appear in the product's public tap. Clone
and install:

```sh
git clone git@github.com:PortZeroNetwork/vmkit.git && cd vmkit
just install             # -> /usr/local/bin/vmkit (override: just install ~/.local)
vmkit init-host          # then edit ~/.config/vmkit/host.conf
vmkit doctor             # validate the machine against the contract
```

To update: `git pull && just install`.

## Use in a repo

```sh
cd my-repo
vmkit init               # ./vmkit.conf + vmtest/scripts/{lib,smoke.sh,smoke.ps1}
vmkit check-scripts      # parse-check the flavor scripts — no VM, ~2s
vmkit test linux smoke   # reset to "built", run one flavor on one platform
vmkit series lifecycle   # every configured platform in series + summary
```

`vmkit init` scaffolds the script layout as well as the config, because the
layout is not arbitrary: **only the flavor script's own directory is pushed
into the guest.** The helpers therefore live in `vmtest/scripts/lib/`, inside
it — a sibling `../lib` resolves on the host and is absent in the guest.

### The flavor protocol, and what counts as a pass

Flavor scripts live in your repo, run *inside* the guests, and speak a tiny
greppable protocol: `PHASE=<name> ok=true|false|SKIP` lines as they go, and a
final `RESULT=PASS|FAIL|SKIP`.

vmkit reads **both** that line and the guest's exit status, and reports one of:

| Outcome | Means | First thing to look at |
|---|---|---|
| `PASS` / `SKIP` | verdict printed, guest exited 0 | — |
| `FAIL` | `RESULT=FAIL`, or a non-zero exit | the `PHASE=` lines |
| `NO-RESULT` | the script never reached its verdict | where its output *stops* — usually a helper it could not source |
| `NO-OUTPUT` | not one byte printed | a crashed interpreter (still exits 0 through `prlctl exec`) |
| `SETUP-FAILED` | the guest never reached the script | the reset/boot above it |
| `TIMEOUT` | `VMKIT_FLAVOR_<NAME>_TIMEOUT` elapsed | the last phase printed |

A missing `RESULT=` line is a **failure**, never a pass, and `RESULT=PASS`
followed by a non-zero exit is a failure too: everything after the last
`PHASE=` line did not happen. `VMKIT_REQUIRE_RESULT=0` opts out of the first
half for a script that predates the protocol; the exit status is not
negotiable. (docs/FAILURES.md #22 — this used to report `PASS (40s)` for a leg
in which every assertion was `command not found`.)

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

### Claiming the host

`ensure_only` enforces one-VM-at-a-time by **stopping every other running VM**.
That is right for a queue of harness runs and destructive for anything else on
the machine: a CI job landing mid-session powers off the guest a human is
working in, and two CI jobs landing together stop each other's guests mid-test.
A GitHub `concurrency:` group serializes one workflow in one repository and
knows nothing about your local session, a second self-hosted runner on the same
host, or another organization's jobs.

**Every VM-mutating command now claims the host for its own duration** —
`test`, `series`, `run`, `reset`, `up`, `provision` — and releases on exit and
on signal. One VM at a time is a property of the host, not of one invocation.
The TTL is derived from the flavor timeout plus a margin for the sibling stop,
the memory settle and the boot (capped at 4h, so a killed run cannot wedge the
host), which is information vmkit has and a caller would have to guess at.
`VMKIT_NO_SELF_HOLD=1` restores the old behaviour.

`vmkit hold` is the same lock, taken by hand for an interactive session:

```sh
export VMKIT_HOLD_TOKEN=$(vmkit hold --print-token "debugging the installer" --vm windows)
vmkit hold            # who has it, until when
vmkit unhold          # release
```

**Authorization is by token, never by VM name.** A live hold blocks every
VM-stopping path for everybody; only a caller carrying `VMKIT_HOLD_TOKEN` from
the record gets through. Export it, or your own `vmkit reset` is refused by your
own hold. `--vm` is documentation of what the host is being used for, nothing
more.

That distinction is the whole point. An earlier version keyed on the VM name —
holding a VM permitted work on *that* VM, so the holder could reset their own
guest. It protected every VM except the one actually in use: a CI job targeting
the same guest matched and reverted it mid-provision. Everyone on this host runs
as the same unix user, so pid/user/VM-name cannot tell a session from a CI job;
a token can.

Holds **always expire** (`--ttl`, default 4h) — a forgotten hold that wedged CI
until someone noticed would be worse than the failure this prevents.
`VMKIT_IGNORE_HOLD=1` overrides, `vmkit doctor` surfaces an active one, and
`vmkit hold --steal` takes over.

For a long session on a machine that is also a CI runner, stop the runner
service too: a hold makes the job **fail** with the reason, whereas an offline
runner makes it **queue** until you're done.

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


## Fleet management

```sh
vmkit adopt              # new/cleaned machine: clone archive VMs -> internal disk
vmkit sync macos         # mirror an internal VM bundle out to its archive copy
vmkit list               # VMs + snapshot ladders
```

## CI

Run the self-hosted runner **as a service** (never interactive `run.sh`), stage
CI-built artifacts where `VMKIT_ARTIFACT_*` points, and call
`vmkit series <flavor>`. Split triggers so PRs run a fast smoke and pushes run
the full pristine-machine suite.

A `concurrency` group that queues (never cancels) VM jobs is still worth having
— queueing beats a refusal — but it is no longer what makes one-VM-at-a-time
true: vmkit claims the host itself, so a second runner, another repository, an
agent session or a person is serialized too. A leg that arrives while the host
is busy fails with the reason rather than going green having tested nothing.

vmkit's own CI needs neither a Mac nor Parallels: `just test` runs the verdict
gate, the script lint and the hold against a fake `prlctl` in about 30 seconds.

## Docs

- [SPEC.md](docs/SPEC.md) — v1 specification: runtime primitives + the Vmkitfile,
  written as acceptance criteria for the Rust port
- [HUMAN-SETUP.md](docs/HUMAN-SETUP.md) — the human/machine contract, new-machine
  bootstrap (including Apple Silicon arch migration)
- [CAPABILITIES.md](docs/CAPABILITIES.md) — what guest scripts can/can't do per OS
- [FAILURES.md](docs/FAILURES.md) — failure catalog: every known failure class → its guard
- [PROVISIONING.md](docs/PROVISIONING.md) — bake one-time guest OS config into a checkpoint (`vmkit provision`)
