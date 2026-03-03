<#
  Trigger remediation unless Windows Update scan/install ran within the last N hours.
  Exit code: 0 = compliant (no remediation); 1 = noncompliant (run remediation)
#>

[CmdletBinding()]
param()

# ======= Config =======
$MinHoursBetweenRuns = 2
$StateRoot = Join-Path $env:ProgramData 'IntuneTools\WindowsUpdate'
$StateFile = Join-Path $StateRoot 'state.json'

# ======= Helpers =======
function Write-Status {
    param([string]$Message)
    Write-Output $Message
}

try {
    if (-not (Test-Path -Path $StateRoot)) {
        Write-Status "State folder missing ($StateRoot) → needs remediation."
        exit 1
    }
    if (-not (Test-Path -Path $StateFile)) {
        Write-Status "State file missing ($StateFile) → needs remediation."
        exit 1
    }

    $state = Get-Content -Path $StateFile -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $state.LastRun) {
        Write-Status "State missing LastRun → needs remediation."
        exit 1
    }

    $lastRun = [DateTime]::Parse($state.LastRun)
    $ageHours = [Math]::Round((New-TimeSpan -Start $lastRun -End (Get-Date)).TotalHours, 2)

    if ($ageHours -ge $MinHoursBetweenRuns) {
        Write-Status ("Last run {0} ({1}h ago) ≥ threshold {2}h → needs remediation." -f $lastRun.ToString("s"), $ageHours, $MinHoursBetweenRuns)
        exit 1
    } else {
        Write-Status ("Last run {0} ({1}h ago) < threshold {2}h → compliant." -f $lastRun.ToString("s"), $ageHours, $MinHoursBetweenRuns)
        exit 0
    }
}
catch {
    Write-Status "Detection error: $($_.Exception.Message) → needs remediation."
    exit 1
}