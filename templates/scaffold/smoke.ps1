# vmkit flavor script (Windows guests). Say here what this leg PROVES.
#
# THIS FILE IS ASCII ONLY, and that is load-bearing rather than a style choice.
# Windows PowerShell 5.1 reads a UTF-8 file with no BOM as CP1252, so an em
# dash (E2 80 94) arrives as three characters ending in a smart quote that
# PowerShell honours as a string delimiter: one of them inside a double-quoted
# message ends the string early, the rest of the file parses as code, and the
# parser reports a brace error on a line whose braces are balanced.
# `vmkit check-scripts` fails the build on it.
#
# The helpers live in lib\ INSIDE this directory: vmkit pushes this script's
# own directory into the guest and nothing above it, so a sibling ..\lib
# resolves on the host and is absent in the guest.
#
# prlctl exec runs this as NT AUTHORITY\SYSTEM -- no mapped drive letters (use
# UNC paths) and no user profile. See docs/CAPABILITIES.md.

$lib = Join-Path $PSScriptRoot 'lib\assert.ps1'
if (-not (Test-Path $lib)) {
    Write-Output "RESULT=FAIL the assertion helpers were not pushed with this script ($lib)"
    exit 1
}
. $lib

Phase 'guest-is-alive' $true

Vmkit-Result "smoke"
