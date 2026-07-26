# vmkit development tasks

# Syntax + lint every shell source.
check:
    bash -n bin/vmkit lib/*.sh
    shellcheck -S warning bin/vmkit lib/*.sh guest-lib/assert.sh

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
