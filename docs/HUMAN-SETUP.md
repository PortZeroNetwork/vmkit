# The human-setup contract

vmkit automates everything about VM system testing **except the parts that
genuinely need a human**. This page is the complete list of those parts. If a
step isn't on this page, it belongs in a script — never do it by hand.

Validate any machine against this contract with `vmkit doctor`.

## One-time, per machine

1. **Install Parallels Desktop Pro** (Pro: the `prlctl` CLI requires it) and
   license it.
2. **Check the default VM home** (Parallels → Preferences → General). It should
   be on the internal disk. If it must point elsewhere, know that any manual
   `prlctl clone`/`create` without `--dst` lands there — vmkit always passes
   `--dst`, and `vmkit doctor` warns about this footgun.
3. **Install vmkit** (clone the repo, `just install` — not Homebrew; see the
   README's Install section for why), then `vmkit init-host` and
   edit `~/.config/vmkit/host.conf` (arch, VM names, archive drive, cache dir).
4. If this machine is a CI runner: install the GitHub Actions runner **as a
   service** (`./svc.sh install && ./svc.sh start`), never interactive
   `run.sh`. An interactive runner has a TTY, and anything that prompts on it
   (or phishes on it) reaches you; a service has no TTY, so prompt attempts
   fail fast. Never type credentials into a runner terminal.

## One-time, per guest VM

1. **Create the VM in Parallels and install the OS** from installation media.
   Keep it a plain default install — the value of this VM is that it looks
   like an end user's machine, not a developer's.
2. **Install Parallels Guest Tools** in the guest (Actions → Install Parallels
   Tools). This is what makes `prlctl exec` work; nothing works without it.
3. Guest-specific accounts/settings:
   - **Windows**: one local admin account, auto-login enabled.
   - **macOS**: one admin account, auto-login enabled, **passwordless sudo**
     for it (`echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/vmkit`).
     Do NOT sign into iCloud. Do NOT install a toolchain.
   - **Linux**: default user; prlctl exec runs as root, nothing extra needed.
4. **Power the VM off and take the golden snapshot**, named
   `<VMKIT_SNAP_PREFIX>-golden` (see host.conf). This powered-off, pristine,
   guest-tools-installed state is the root of the snapshot ladder and is
   *never* modified again. Re-golden only for OS upgrades.

Everything after golden — booting, capturing the `-ready` running snapshot,
provisioning toolchains/caches, capturing `-built` — is scripted:

```
vmkit up <platform>              # golden -> boot -> capture "-ready"
<your provisioning scripts>      # cache-first; never re-download on the test path
vmkit checkpoint <platform> built
```

## Ongoing human duties (rare)

- Plug in the archive drive when `vmkit adopt`/`vmkit sync` asks for it.
- Re-golden after intentional guest OS upgrades (then re-run provisioning).
- Buy disk space before the internal drive fills; vmkit refuses to boot VMs
  from external storage rather than degrade.

## New machine bootstrap (including a different architecture)

1. Do "One-time, per machine" above.
2. Same-arch machine: plug in the archive drive, register the archive VMs in
   Parallels (double-click the .pvm bundles), run `vmkit adopt` — it clones
   them to the internal disk. Snapshot ladders travel with the clone.
3. **Different-arch machine (e.g. Apple Silicon after an Intel host): the old
   VMs cannot run.** Parallels on ARM runs only ARM guests. Redo "per guest
   VM" with ARM installation media (Windows 11 ARM, macOS ARM, Ubuntu ARM) and
   re-run the provisioning scripts. Windows 11 ARM executes x64 binaries under
   emulation — that *is* the real experience of end users on ARM Windows, so
   testing x64 artifacts there is coverage, not a shortcut.
