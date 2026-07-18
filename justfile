# vmkit development tasks

# Syntax + lint every shell source.
check:
    bash -n bin/vmkit lib/*.sh
    shellcheck -S warning bin/vmkit lib/*.sh guest-lib/assert.sh

# Install this checkout into Homebrew's vmkit prefix so the self-hosted runner
# uses local fixes before the tap is updated.
install:
    #!/usr/bin/env bash
    set -euo pipefail
    if prefix="$(brew --prefix vmkit 2>/dev/null)"; then
        :
    else
        prefix="$(brew --prefix)/opt/vmkit"
    fi
    mkdir -p "$prefix/libexec"
    rm -rf "$prefix/libexec/bin" "$prefix/libexec/lib" "$prefix/libexec/guest-lib" "$prefix/libexec/templates" "$prefix/libexec/docs"
    cp -R bin lib guest-lib templates docs VERSION "$prefix/libexec/"
    mkdir -p "$prefix/bin"
    [ ! -e "$prefix/bin/vmkit" ] || chmod u+w "$prefix/bin/vmkit"
    printf '#!/bin/sh\nexec "%s/libexec/bin/vmkit" "$@"\n' "$prefix" > "$prefix/bin/vmkit"
    chmod +x "$prefix/bin/vmkit"
    vmkit version

# Run the host doctor using this checkout (not an installed vmkit).
doctor:
    ./bin/vmkit doctor
