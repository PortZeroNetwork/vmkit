# One-time guest provisioning (`vmkit provision`)

Bake OS-level config that a per-test `vmkit reset` would otherwise throw away
into the checkpoint the tests revert to — once — and keep the clean baseline.

## Why this exists

Every test run starts with a revert:

```
golden (powered-off) -> ready (booted) -> built (provisioned)  <- tests reset here
```

`vmkit test` / `vmkit series` revert to `built` before **every** run, on
purpose: that is what makes runs pristine and repeatable. The cost is that
anything you do inline in a per-run flavor script is gone at the next reset. So
config that must *persist* — a toolchain, Homebrew, a **Windows Defender
exclusion** — cannot live in the test script. It has to be baked into `built`
itself.

Doing that by hand means: reset to `built`, run a provisioning script in the
guest, then re-snapshot `built` over the top — plus enough care to not destroy
the clean pre-provision state the first time you do it. That dance was copied,
as bespoke bash, into every consuming repo (parsing `prlctl snapshot-list` to
test whether a preservation snapshot already exists, etc.). `vmkit provision`
is that dance, encoded once, with the safety rails built in.

## What it does

```
vmkit provision <platform|vm> <script> [options] [-- <script args>]
```

1. **Reset** the VM to `<checkpoint>` (default `built`, i.e. `$VMKIT_TEST_SNAP`).
2. **Preserve** the pristine pre-provision state as a snapshot — **once**, only
   if it doesn't already exist — so re-provisioning can never destroy the clean
   baseline. Default name `<checkpoint>-pre-<label>`.
3. **Run** `<script>` inside the guest (a repo-relative path, exactly like
   `vmkit run`), guarded by the usual host-side timeout.
4. **Re-capture** `<checkpoint>` with the provisioned state baked in.
5. Optionally **anchor**: also capture a second, permanent checkpoint that the
   routine reset/re-provision flow never overwrites — the durable cache of a
   one-time (often metered-link) download. If `<checkpoint>` is ever clobbered,
   revert to the anchor and re-capture `<checkpoint>` — no re-download.

If the guest script **fails**, `<checkpoint>` is *not* re-captured: the guest is
left at the failed state for inspection (`vmkit screenshot`, `vmkit exec`) and
the preservation snapshot still holds the clean baseline, so a retry is free.

Provisioning always runs on the **internal working copy** (internal-disk-only
boot policy); a missing internal copy is recovered from the archive exactly as
`vmkit test` does.

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `--checkpoint <name>` | `built` (`$VMKIT_TEST_SNAP`) | Checkpoint to reset from and re-capture. |
| `--label <label>` | script basename, no extension | Names the preservation snapshot `<checkpoint>-pre-<label>`. |
| `--preserve-as <name>` | — | Override the preservation snapshot's logical name outright (e.g. a legacy `pre-brew`). |
| `--no-preserve` | preserve on | Skip the preservation snapshot entirely. |
| `--anchor <name>` | — | Also capture a second permanent checkpoint after provisioning. |
| `--timeout <secs>` | `$VMKIT_RUN_TIMEOUT` or 1800 | Guest-script timeout. |
| `-- <args>` | — | Everything after `--` is passed to the guest script. |

Snapshot names follow the usual `<prefix>-<logical>` convention
(`VMKIT_SNAP_PREFIX` from host.conf), so `--checkpoint built --label defender`
on a host with prefix `portzero` produces `portzero-built` (re-captured) and
`portzero-built-pre-defender` (preserved once).

## Examples

**Windows Defender exclusion** — an intentionally unsigned MSI installed off the
`\\Mac\Home` share inherits Mark-of-the-Web, and Defender's heuristic engine
blocks the installed binary from launching (`… the file contains a virus or
potentially unwanted software`). Bake the exclusion into `built` once:

```sh
vmkit provision windows vmtest/scripts/windows-add-defender-exclusions.ps1 \
    --checkpoint built --label defender
# built now carries the exclusion; every `vmkit test windows` reset inherits it.
```

**Homebrew, with a permanent anchor** — install Homebrew (a metered-link,
not-file-cacheable download) once and keep a durable anchor of it:

```sh
vmkit provision macos vmtest/scripts/macos-install-homebrew.sh \
    --checkpoint built --preserve-as pre-brew --anchor toolchain --timeout 2400
# -> <prefix>-pre-brew   (pristine baseline, preserved once)
#    <prefix>-built      (CLT + Homebrew, the reset point; churns)
#    <prefix>-toolchain  (CLT + Homebrew, permanent anchor; never auto-overwritten)
```

## After provisioning macOS

macOS runs poorly off the external archive drive, so provisioning happens on the
internal copy; mirror the result out afterwards so the snapshot cache survives a
machine wipe:

```sh
vmkit stop macos
vmkit sync macos     # or the repo's mirror recipe
```

## Guest-script contract

The `<script>` is an ordinary repo guest script (same rules as `vmkit run` /
flavor scripts — see [CAPABILITIES.md](CAPABILITIES.md)): it runs as
SYSTEM/root, must be **idempotent** (provisioning may re-run), and should emit
greppable `KEY=value` / `PHASE=… ok=…` lines rather than prose so a failure is
named. A non-zero exit aborts the re-capture and leaves the guest for
inspection.
