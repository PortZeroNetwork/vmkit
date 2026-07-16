# Guest capability matrix

What test scripts can and cannot do inside each guest under `prlctl exec`.
Every row here was learned the hard way; consult this BEFORE writing a flavor
script, and prefer `assert_or_skip` (with a pointer to the covering test) over
fighting an OS limit.

## Who am I in the guest?

| Guest   | `prlctl exec` identity | Notes |
|---------|------------------------|-------|
| Windows | `NT AUTHORITY\SYSTEM`  | Matches how MSI deferred custom actions run — good CI parity. |
| Linux   | `root`                 | |
| macOS   | `root`                 | Headless: no GUI session, no securityd user interaction. |

## Windows (as SYSTEM)

- **No mapped drive letters.** SYSTEM can't see `Y:`/`Z:` — always UNC paths
  (`\\Mac\Home\...`, `\\Mac\<share>\...`).
- **`schtasks /Create /SC ONLOGON` fails as SYSTEM** with "No mapping between
  account names and security IDs" unless you pass an explicit `/RU SYSTEM`.
  Detect SYSTEM by SID (`whoami /user` → `S-1-5-18`), not by account name
  (localized).
- MSI custom actions with `Return="ignore"` swallow failures — lifecycle tests
  must assert the *artifacts* (task exists, cert in store, NRPT rule present),
  never trust the installer exit code alone.
- `| Out-Null` on native commands can hang via pipe inheritance; PowerShell
  `Start-Process -Wait` + explicit log files is safer for installers.
- Anything that can wedge (msiexec, certutil, service stop) runs under
  `Invoke-Guarded` (guest-lib/assert.ps1) with a timeout.

## macOS (headless root)

- **System-keychain trust settings cannot be set headlessly**:
  `security add-trusted-cert -d -r trustRoot` fails with "authorization was
  denied since no user interaction was possible". The cert IS imported
  (find-certificate sees it); only the *trust settings* step fails. Product
  code must therefore treat trust-install failure as non-fatal-but-reported,
  and lifecycle tests assert cert presence, `assert_or_skip` trust state.
- **`launchctl bootstrap system` AND legacy `load -w` fail with EIO** under
  headless prlctl exec (no bootstrap context). Assert the plist file lands;
  `assert_or_skip` the loaded state; cover daemon-run behavior with a test
  that starts the daemon directly.
- **SIP-protected system binaries (`/usr/bin/perl`, python, sh) hide their
  environment from every reader** — `ps -E` and `KERN_PROCARGS2` alike, even
  as root. If a test tags a service via env vars, run it from a *copy* of the
  interpreter at an unrestricted path.
- **The Parallels shared folder is unusable under headless `prlctl exec`.**
  `prl_fsd` still mounts `//guest:@Shared Folders` at `/Volumes/SharedFolders`,
  but every reader (root and the interactive user) gets TCC
  `Operation not permitted`. Host Shared Folders on/off does not change this;
  SIP blocks seeding TCC.db from the headless path. vmkit therefore:
  1. Probes the share and uses it if a future guest/snapshot ever grants access.
  2. Otherwise **tar.gz-pushes** scripts/binaries over `prlctl exec` stdin
     (same approach as Parallels' `prlcopy`) with a 15s keepalive line so the
     GitHub self-hosted runner never goes silent mid-transfer.
  Never rely on `/Volumes/SharedFolders` from flavor scripts.
- macOS guests are slow off external storage; expect flakiness if the bundle
  is not on the internal disk (vmkit's boot policy enforces this).

## Linux (root)

- `/proc/<pid>/environ` is readable as root — env-tag discovery just works.
- `systemctl --user` needs a user D-Bus session that prlctl exec (as root)
  does not have; test user units via `machinectl shell user@` or assert unit
  files + enablement state instead of live user-manager state.

## All guests

- **Multi-line inline `prlctl exec bash -lc '...'` mangles arguments.** Run
  script FILES (pushed or via the share); pipe scripts to `bash -s` for
  ad-hoc multi-line work.
- **Killing a host-side `prlctl exec` does NOT kill the guest process.**
  Anything long-running needs guest-side cleanup (vmkit's straggler kill).
- **`$SUDO VAR=val cmd` breaks when `$SUDO` is empty** (bash runs `VAR=val` as
  the command): always `$SUDO env VAR=val cmd`.
- `prlctl exec` gives you `HOME=/` on Unix guests — set `HOME` explicitly for
  anything that reads dotfiles or state directories.

## Host-side desktop control (no guest agent)

vmkit can observe and drive the guest **interactive console** from the host
using Parallels APIs only (`prlctl capture`, `prlctl send-key-event`). This is
orthogonal to `prlctl exec` / flavor scripts.

| Command | What it does | Limits |
|---------|--------------|--------|
| `vmkit screenshot <vm> [file]` | PNG of the VM framebuffer; path on stdout | Needs VM running |
| `vmkit key <vm> <spec...>` | Named keys and combos (`enter`, `ctrl+c`, `win+r`, `code:36`) | US-layout key names |
| `vmkit type <vm> <text...>` | Types printable US-ASCII (+ tab/newline) | No non-ASCII IME |
| `vmkit mouse <vm> click\|…` | Left/right/middle click; wheel; relative `nudge` | **No absolute (x,y)** |

Useful agent loop:

```sh
shot=$(vmkit screenshot windows)
# inspect $shot (vision), then:
vmkit key windows tab enter
vmkit type windows "some text"
```

### What still needs a guest agent

- **Absolute pointer** (`click-at x y`, move-to) — Parallels only exposes
  relative move + buttons via the key table.
- **Accessibility trees** (UIA / AX / AT-SPI) — hypervisor sees pixels, not
  widget roles/names/bounds.
- **Video recording** — no reliable host CLI; record host-side of the VM
  window or stitch screenshots as a workaround.

### Session context

Desktop input goes to the **virtual console**, not into a headless
SYSTEM/root `prlctl exec` session. For UI work, guests should use the
auto-login interactive user from [HUMAN-SETUP.md](HUMAN-SETUP.md). Scripted
system tests (`vmkit test` / `run` / `exec`) remain the headless path.

Env knobs:

- `VMKIT_SCREENSHOT_DIR` — default directory for auto-named screenshots
  (`$TMPDIR/vmkit-screenshots` if unset).
- `VMKIT_KEY_DELAY` — inter-key delay in ms (default `40`).
