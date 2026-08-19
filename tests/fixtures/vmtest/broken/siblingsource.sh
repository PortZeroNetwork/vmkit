#!/usr/bin/env bash
# Parses fine, but sources a helper the guest will never see.
. "$(dirname "$0")/../shared/assert.sh"
vmkit_result "unreachable in a real guest"
