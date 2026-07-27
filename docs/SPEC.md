# vmkit v1 specification

Target for the Rust rewrite. Written **before** the port, deliberately: a
rewrite that reproduces the current code faithfully would also reproduce the
failures the current code has already paid for. `FAILURES.md` row 5 is the
in-house version of that lesson; this file is the acceptance criteria that
prevents it.

Scope of the port: `config`, `core`, `host`, `transport`, `testing`,
`provision`, `hold`, `doctor` (~1,800 lines). `desktop.sh` (key-code tables)
and `agents.sh` (doc generation) stay in bash — low churn, not where bugs live.

## Where the bugs actually come from

Twelve failures were catalogued while building the Windows demo guest
(2026-07-26/27). Sorted by root cause:

| Cause | Count | Fixed by |
|---|---|---|
| Hand-written guest scripts | ~6 | **the Vmkitfile** (§2) — delete the file type |
| vmkit design gaps | ~4 | **runtime primitives** (§1) |
| Bash-specific footgun | 1 | the port itself |

The port is not the fix. §1 and §2 are the fix; Rust is the vehicle.

---

# §1 Runtime primitives

## 1.1 Guarded exec — stop on sentinel, never wait for EOF

**The failure.** `prlctl exec` returns when the guest's stdout reaches EOF, not
when the script exits. Any process the script leaves running (a service, a
daemon, an installer's background task) inherits that handle and holds the pipe
open. Twice a guest printed `RESULT=PASS` and vmkit then sat for 14 and 19
minutes; the checkpoint step was never reached, and the state had to be
captured by hand.

**Required behavior.** The exec supervisor watches for the flavor protocol's
terminal line and stops there:

- On reading a line matching `^RESULT=(PASS|FAIL|SKIP)`, **return immediately**
  with that verdict. Do not wait for EOF. Do not wait for the child.
- Then terminate the guest-side process tree (best effort) and reap.
- Exit status is advisory only. `RESULT=` is authoritative when present.
- Absent any `RESULT=` line, the run FAILS regardless of exit status — with a
  distinct message when output was empty, because a crashed interpreter still
  yields exit 0 through `prlctl exec` and that is what silently baked an
  unprovisioned guest into both a checkpoint and a permanent anchor.

**Tests**
| # | Given | Expect |
|---|---|---|
| E1 | script prints `RESULT=PASS`, leaks a handle, never exits | returns PASS in < 5s |
| E2 | script exits 0, prints nothing | FAIL, message names "no output at all" |
| E3 | script exits 0, prints phases but no `RESULT=` | FAIL, message names the truncation |
| E4 | script prints `RESULT=FAIL`, exits 0 | FAIL |
| E5 | script exits 3, prints `RESULT=PASS` | PASS (sentinel wins) |
| E6 | script exits 3, prints nothing | FAIL, exit status preserved in the message |

## 1.2 Silence watchdog

**The failure.** `git clone` of a private repo prompts for credentials; there is
no TTY under `prlctl exec`; it blocked forever. Two runs sat on that prompt, one
for twenty minutes, while every network check passed — because nothing was wrong
with the network. The only guard was a 1,800–5,400s host timeout.

**Required behavior.** Track time since the last output line.

- After `VMKIT_SILENCE_WARN` (default 60s) with no output: emit a warning naming
  the last phase seen.
- After `VMKIT_SILENCE_FAIL` (default 600s): fail with a diagnostic that
  includes the last phase, elapsed time, and the guest-side process list.
- Steps legitimately silent for long periods (a large install) opt out per-step,
  not globally.

**Tests**: W1 silent 70s → warning, run continues. W2 silent past fail
threshold → fails with last-phase named. W3 output every 30s for 10 min → no
warning.

## 1.3 Preflight before any boot or revert

**The failures.** (a) The memory check only ran after stopping a sibling VM, so
with no sibling it never ran and Parallels refused a snapshot switch with
"performance problems and its hard disk is busy" — which reads like disk
corruption. (b) The check then double-counted a **running** target's own RAM,
demanding 14 GB while the 12 GB guest already held 12 GB, and blocked the
ordinary path for the full wait budget. (c) **Free disk was never checked at
all**, though Parallels needs free disk ≈ guest RAM for its memory state file;
this produced two separate confusing failures.

**Required behavior.** Before every boot/revert, unconditionally:

- **RAM**: need = headroom, plus the guest's configured RAM **only if the target
  is not already running**. A running target's allocation is reused.
- **Disk**: need ≥ guest RAM on the volume holding the bundle. Fail with the
  actual figures, never let Parallels report it.
- **Hardware assertion**: snapshot reverts silently restore vCPU count, RAM, and
  nested-virtualization. After a revert, compare against expected values from
  host config and fail loudly on drift. Enabling nested virt then reverting to
  an older rung silently disables it, and Docker Desktop then fails to install
  for no visible reason.

**Tests**: P1 stopped target, RAM < need → refuse with figures. P2 **running**
target, free RAM < guest RAM but > headroom → **allow**. P3 free disk < guest
RAM → refuse before calling prlctl. P4 revert restores 4 vCPU where 8 expected →
fail naming both.

## 1.4 Guest hygiene, applied by vmkit

Each consuming repo currently re-solves these, and gets them wrong
independently. vmkit applies them once per guest:

- `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never` machine-wide — no credential
  prompt can hang a run that has no TTY.
- **Windows console delegation → conhost.** Windows 11 delegates to Windows
  Terminal, which draws a *visible window per console*. vmkit itself opens one
  per `prlctl exec` and polls with exec while waiting for readiness: one session
  buried the guest desktop under ~200 stacked terminal windows. This is vmkit's
  mess to clean up, not the repo's.
- Readiness polling must not spawn a console per attempt.

## 1.5 Script validation before push

**The failure.** `.ps1` files were UTF-8 with no BOM. PowerShell 5.1 decodes
those as Windows-1252, where an em dash's `E2 80 94` becomes three characters —
and `0x94` is `”`, a right double quote. A dash inside a double-quoted string
silently terminated it; the file failed to parse entirely, reported as an
unterminated string ten lines past the real cause.

**Required behavior.** Before pushing or executing guest code:

- `.ps1` must be UTF-8 **with BOM**, or vmkit adds one in transit.
- Parse-check with the target interpreter (`Parser::ParseFile`, `bash -n`) and
  refuse with file:line rather than executing a broken script.
- These checks are vmkit's, so every repo gets them.

---

# §2 The Vmkitfile

Replaces hand-written provisioning **and** per-session refresh scripts — the
file type that produced half of all failures. Test flavors stay hand-written:
they assert product behavior, which does not belong in a DSL.

## 2.1 Two stages

```
# ── BUILD: rare, baked into snapshots ────────────────────────────
FROM        windows:golden
USER        auto
CACHE       /Volumes/MBP-Sidecar/loumtech/vm-toolchain-cache/windows

DEFENDER-EXCLUDE %TEMP% C:\ProgramData\chocolatey "C:\Program Files\Docker"
INSTALL     git      cache:git-64-bit.exe    ARGS /VERYSILENT /NORESTART
INSTALL     dotnet   cache:dotnet-sdk-10.exe ARGS /install /quiet
INSTALL     docker   cache:DockerDesktop.exe ARGS install --quiet  OPTIONAL
INSTALL     portzero cache:portzero.msi      MSI
INSTALL     sshd     cache:OpenSSH-Win64.msi MSI ADDLOCAL=Server
SERVICE     sshd ENABLE START
ASSERT      portzero --version
CHECKPOINT  demo ANCHOR demo-base

# ── SESSION: every `vmkit session`, never checkpointed ───────────
SESSION
COPY        . ~/portzero-full-example EXCLUDE obj bin node_modules .vs
FILE        ~/.ssh/authorized_keys FROM env:PZ_DEMO_SSHKEY MODE 600 OWNER user
FILE        ~/.portzero/auth.json  FROM env:PZ_DEMO_AUTH   MODE 600 OPTIONAL
SERVICE     portzero ENSURE-RUNNING
REPORT      ssh-endpoint
```

`SESSION` divides the file. Everything above it may be cached; everything below
runs every time and never produces a snapshot.

## 2.2 Caching

Layers form **only at declared `CHECKPOINT` lines** (chosen over per-step
snapshots: the host hit 100% disk during this work, and per-step layers are
expensive).

- Each `CHECKPOINT` records a hash of every instruction since the previous one.
- On re-run, unchanged prefixes are skipped by reverting to that checkpoint.
- The first changed instruction invalidates its checkpoint and everything after.
- `ANCHOR` marks a checkpoint as never-auto-overwritten (the metered-download
  cache); it is re-captured only on an explicit successful rebuild.
- `--no-cache` forces from `FROM`.

**Tests**: C1 unchanged file → reverts to last checkpoint, runs nothing. C2 edit
an instruction → re-runs from there. C3 edit a SESSION line → no build
invalidation. C4 build fails → **no checkpoint captured, anchor untouched**
(a failed run must never poison either — this happened).

## 2.3 Instructions

| Instruction | Behavior, and the bug it exists to prevent |
|---|---|
| `FROM <platform>:<rung>` | Starting snapshot. |
| `USER auto` | Resolve the interactive account via WMI/`dscl`/uid-1000. **Never `Get-LocalGroupMember`** — it kills the PowerShell session outright on Win11 26100 with no exception and no stderr. |
| `CACHE <path>` | Offline installer cache; `cache:` refs resolve here. Fails loudly if declared and absent, rather than silently falling back to network downloads. |
| `INSTALL <name> <src> [ARGS…] [MSI] [OPTIONAL]` | Runs installers with **redirected stdio** so no child inherits the pipe (§1.1). `OPTIONAL` records a skip instead of failing (Docker without nested virt). |
| `COPY <src> <dst> [EXCLUDE …]` | Host→guest copy over the share. **Never fetches from a remote**: `git clone` of a private repo hangs on a credential prompt with no TTY. |
| `FILE <path> FROM env:VAR [MODE] [OWNER] [OPTIONAL]` | Write forwarded content (auth tokens, SSH keys). Handles Windows' `administrators_authorized_keys` ACL rules. |
| `SERVICE <name> [ENABLE] [START] [ENSURE-RUNNING]` | **Never blocks on a foreground daemon.** `portzero start` execs `portzero.exe start --foreground`, which by design never exits; `Start-Process -Wait` on it hung until the host timeout. Start without waiting, then poll a bounded readiness deadline. |
| `DEFENDER-EXCLUDE <paths…>` | Must be emitted **before the first install**. Unmitigated, Defender burned **1,261 CPU-seconds** scanning installs; with exclusions first, 17s. Largest single speed factor found — 35 min → 4.5 min. |
| `ASSERT <cmd>` | Non-zero fails the build. |
| `REPORT ssh-endpoint` | Emits `DEMO_SSH_USER=`/`DEMO_SSH_IP=` using the address on the interface owning the **default route** — not the first non-loopback, which on a guest with Docker's vEthernet and portzero's TUN returned an unroutable `172.20.0.1`. |
| `RUN <script>` | Escape hatch. Same guards as everything else. Expected to cover ~10% of cases; if it's covering more, the instruction set is wrong. |
| `CHECKPOINT <name> [ANCHOR <name>]` | Capture. Only on `RESULT=PASS` (§1.1). |
| `SESSION` | Stage divider. |

## 2.4 Non-goals

- Not a general config-management system. If it grows conditionals and loops,
  that is a signal to use `RUN`.
- Does not replace `host.conf` (machine inventory) or `vmkit.conf` (what a repo
  tests). Those stay flat and typed.
- Does not replace test flavors.

---

# §3 Sequencing

1. **Implement §1 primitives in the current bash**, with the tests above. They
   are the reliability win and they are language-neutral — no reason to wait for
   the port. (1.1's sentinel behavior and 1.3's disk check are the two that
   would have saved the most time.)
2. **Freeze the test suite** as executable acceptance criteria.
3. **Port core to Rust** against that suite.
4. **Vmkitfile last** — it is the largest piece and depends on §1 being solid.

Status: 1.3's RAM rules and the `RESULT=PASS` gate for `provision` are already
in bash (v0.4.3–0.4.5). Everything else in §1 is unimplemented.
