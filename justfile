# vmkit development tasks

# Syntax + lint every shell source.
check:
    bash -n bin/vmkit lib/*.sh
    shellcheck -S warning bin/vmkit lib/*.sh guest-lib/assert.sh

# Run the host doctor using this checkout (not an installed vmkit).
doctor:
    ./bin/vmkit doctor
