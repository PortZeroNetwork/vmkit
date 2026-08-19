# vmkit guest-side assertion helpers (PowerShell; Windows guests).
#
# Copy this file into a lib\ directory INSIDE your flavor script's own
# directory and dot-source it:
#     . (Join-Path $PSScriptRoot 'lib\assert.ps1')
#
# `vmkit init` scaffolds exactly that layout, and it is not a preference:
# vmkit pushes the flavor script's OWN directory into the guest and nothing
# above it, so a sibling ..\lib resolves on the host and is absent in the
# guest. See docs/CAPABILITIES.md, "All guests".
#
# THIS FILE IS ASCII ONLY, deliberately. Windows PowerShell 5.1 reads a UTF-8
# file with no BOM as CP1252, so an em dash (E2 80 94) arrives as three
# characters ending in U+201D -- a smart quote PowerShell honours as a string
# delimiter. One of them inside a double-quoted message ends the string early,
# the rest of the file parses as code, and the parser reports a brace error on
# a line whose braces are balanced. `vmkit check-scripts` fails on it.
#
# Protocol: emit "PHASE=<name> ok=true|false|SKIP" lines, finish with
# Vmkit-Result. A script that ends WITHOUT a RESULT= line is reported as
# NO-RESULT, never as a pass. Run under a hard step timeout where a child can
# wedge (see Invoke-Guarded below) -- prlctl exec runs you as SYSTEM, and a
# hung msiexec/service call would otherwise stall the whole harness.
#
# DIAGNOSTICS GO TO [Console]::Error.WriteLine, NOT Write-Output.
# Anything a PowerShell function writes to the success stream becomes part of
# its RETURN VALUE. Adding one Write-Output diagnostic to a wrapper made it
# return @(message, bool); `Phase` then failed to bind its [bool] parameter,
# threw, and the phase VANISHED FROM THE REPORT -- a helper reporting a failure
# by deleting it. (docs/FAILURES.md #25.)

$script:VmkitFails = 0

function Phase {
    param([string] $Name, [bool] $Ok)
    if ($Ok) { "PHASE=$Name ok=true" }
    else     { "PHASE=$Name ok=false"; $script:VmkitFails++ }
}

function Phase-Skip {
    param([string] $Name, [string] $Reason)
    "PHASE=$Name ok=SKIP reason=`"$Reason`""
}

function Vmkit-Result {
    param([string] $Description = "")
    if ($script:VmkitFails -eq 0) { "RESULT=PASS $Description"; exit 0 }
    "RESULT=FAIL $Description assertions failed=$($script:VmkitFails)"
    exit 1
}

function Vmkit-Skip {
    param([string] $Reason = "")
    "RESULT=SKIP $Reason"
    exit 0
}

# Run a native program and get its EXIT CODE and its output back.
#
# This is what most assertions want. Use it, not Invoke-Guarded, whenever the
# question is "did this command succeed".
#
# Returns a hashtable: @{ Completed; ExitCode; Out; Err }.
#
#   $r = Invoke-Native -Exe $exe -Arguments @('--version')
#   Phase 'version' (Ran-Ok $r)
#
# `-Wait` is required, not incidental. `Start-Process -PassThru` WITHOUT it
# hands back a process object whose ExitCode is NEVER POPULATED: it reads back
# empty, not non-zero, so every phase that checked one failed while the command
# had plainly worked and written its output file. A parameterless
# $proc.WaitForExit() afterwards does not fix it either. Which means you cannot
# have a per-command timeout AND a reliable exit code out of Start-Process --
# so there is deliberately no timeout here. vmkit already owns that, and does
# it better: VMKIT_FLAVOR_<NAME>_TIMEOUT bounds the whole run host-side and
# VMKIT_KILL_WINDOWS reaps stragglers afterwards.
#
# Explicit -RedirectStandardOutput/-RedirectStandardError are also load-bearing
# and not just for capture: without them the child inherits this script's
# stdout handle, and any installer that leaves a service running holds that
# pipe open so `prlctl exec` never sees EOF and never returns
# (docs/FAILURES.md, "prlctl exec never returns after the script finished").
function Invoke-Native {
    param(
        [string]   $Exe,
        [string[]] $Arguments = @(),
        [string]   $WorkDir = $PWD.Path,
        [string]   $StdIn
    )
    $log = Join-Path $env:TEMP ("vmkit-" + [guid]::NewGuid().ToString('N') + ".log")
    $err = "$log.err"
    $start = @{
        FilePath               = $Exe
        WorkingDirectory       = $WorkDir
        RedirectStandardOutput = $log
        RedirectStandardError  = $err
        NoNewWindow            = $true
        PassThru               = $true
        Wait                   = $true
    }
    if ($Arguments.Count -gt 0) { $start['ArgumentList'] = $Arguments }
    if ($StdIn) { $start['RedirectStandardInput'] = $StdIn }

    # A missing file makes Start-Process THROW and return nothing, so $proc is
    # null and every call on it fails with a stack trace instead of a verdict.
    # A harness whose own error hides the finding is worse than no harness.
    $proc = $null
    try {
        $proc = Start-Process @start -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("   Start-Process failed for $Exe : $($_.Exception.Message)")
        return @{ Completed = $false; ExitCode = -1; Out = ''; Err = '' }
    }
    if (-not $proc) {
        return @{ Completed = $false; ExitCode = -1; Out = ''; Err = '' }
    }

    $stdout = if (Test-Path $log) { (Get-Content $log -Raw) } else { '' }
    $stderr = if (Test-Path $err) { (Get-Content $err -Raw) } else { '' }
    return @{
        Completed = $true
        ExitCode  = $proc.ExitCode
        Out       = ("$stdout").Trim()
        Err       = ("$stderr").Trim()
    }
}

# Turn an Invoke-Native result into the [bool] Phase wants, printing why on
# failure. Note the diagnostic goes to stderr -- see the header.
function Ran-Ok {
    param($Result)
    if (-not $Result.Completed) { return $false }
    if ($Result.ExitCode -ne 0) {
        [Console]::Error.WriteLine("   exit code $($Result.ExitCode): $($Result.Err)")
        return $false
    }
    return $true
}

# Run a scriptblock under a hard timeout so a wedged child (msiexec, certutil,
# a hung service stop) never hangs the whole run.
#
# IT ANSWERS ONE QUESTION: did this complete, or did it hang. $true on
# completion, $false on timeout.
#
# IT CANNOT TELL YOU WHETHER THE COMMAND SUCCEEDED. Start-Job runs the block in
# a SEPARATE PROCESS, so $LASTEXITCODE and every variable the block sets stay
# there, and Receive-Job's output is discarded. This reads naturally and is
# wrong:
#
#     $ok = Invoke-Guarded -Script { & $using:exe --version }
#     Phase 'version' ($ok -and $LASTEXITCODE -eq 0)   # <- the CALLER's
#                                                      #    $LASTEXITCODE
#
# The failure is quiet: a plausible boolean that is not measuring what you
# think. If you want "did this succeed", use Invoke-Native above. Reserve this
# for the case it was built for -- a step that can WEDGE and whose success you
# assert some other way afterwards (the service is running, the cert is in the
# store). docs/FAILURES.md #25.
function Invoke-Guarded {
    param([scriptblock] $Script, [object[]] $ArgList = @(), [int] $TimeoutSec = 120, [string] $Label = 'step')
    $job = Start-Job -ScriptBlock $Script -ArgumentList $ArgList
    if (Wait-Job $job -Timeout $TimeoutSec) {
        Receive-Job $job 2>&1 | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return $true
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("WARN=$Label-timed-out-after-${TimeoutSec}s")
    return $false
}
