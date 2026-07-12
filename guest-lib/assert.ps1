# vmkit guest-side assertion helpers (PowerShell; Windows guests).
#
# Copy this file into your repo next to your flavor scripts and dot-source it:
#     . (Join-Path $PSScriptRoot 'lib\assert.ps1')
#
# Protocol: emit "PHASE=<name> ok=true|false|SKIP" lines, finish with
# Vmkit-Result. Run under a hard step timeout where a child can wedge
# (see Invoke-Guarded below) — prlctl exec runs you as SYSTEM, and a hung
# msiexec/service call would otherwise stall the whole harness.

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

# Run a scriptblock under a hard timeout so a wedged child (msiexec, certutil,
# a hung service stop) never hangs the whole run. Returns $true on completion,
# $false on timeout.
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
    "WARN=$Label-timed-out-after-${TimeoutSec}s"
    return $false
}
