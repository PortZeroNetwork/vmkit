# vmkit development tasks

# Syntax + lint every shell source.
#
# The guest-lib ASCII check is not style. Windows PowerShell 5.1 reads a UTF-8
# file with no BOM as CP1252, so one em dash in a .ps1 ends a string early and
# the whole file fails to parse, reporting a brace error on an unrelated line.
# guest-lib is the directory every consuming repo copies from, so it holds to
# ASCII across the board rather than to a per-extension rule nobody applies
# reliably while writing prose in a comment. (docs/FAILURES.md #24.)
check:
    bash -n bin/vmkit lib/*.sh guest-lib/assert.sh templates/scaffold/smoke.sh tests/run.sh tests/check-ascii.sh tests/fake-bin/prlctl
    shellcheck -S warning bin/vmkit lib/*.sh guest-lib/assert.sh
    ./tests/check-ascii.sh

# Run vmkit's self-test (no Parallels, no guests; ~30s).
test:
    ./tests/run.sh

# Everything CI runs.
ci: check test

# Install this checkout so `vmkit` is on PATH.
#
# NOT via Homebrew, deliberately. vmkit is a private, internal tool; publishing
# a formula for it meant a PUBLIC tap (portzeronetwork/homebrew-portzero)
# advertising its name, description, homepage and a license it doesn't have,
# in the product's own namespace. Distribution is now: clone, `just install`.
#
# PREFIX overrides the target (default /usr/local). The wrapper is a script,
# not a symlink: vmkit locates lib/ relative to its own realpath.
install prefix="/usr/local":
    #!/usr/bin/env bash
    set -euo pipefail
    share="{{prefix}}/share/vmkit"
    mkdir -p "$share" "{{prefix}}/bin"
    rm -rf "$share/bin" "$share/lib" "$share/guest-lib" "$share/templates" "$share/docs"
    cp -R bin lib guest-lib templates docs VERSION "$share/"
    printf '#!/bin/sh\nexec "%s/bin/vmkit" "$@"\n' "$share" > "{{prefix}}/bin/vmkit"
    chmod +x "{{prefix}}/bin/vmkit"
    # A stale Homebrew-installed copy earlier on PATH would silently win.
    if brewpath="$(brew --prefix vmkit 2>/dev/null)" && [ -e "$brewpath/bin/vmkit" ]; then
        echo "!! a Homebrew vmkit is still installed at $brewpath — remove it: brew uninstall vmkit" >&2
    fi
    echo "installed $(vmkit version) -> {{prefix}}/bin/vmkit"

# Remove an installed vmkit.
uninstall prefix="/usr/local":
    rm -rf "{{prefix}}/share/vmkit" "{{prefix}}/bin/vmkit"

# Run the host doctor using this checkout (not an installed vmkit).
doctor:
    ./bin/vmkit doctor
