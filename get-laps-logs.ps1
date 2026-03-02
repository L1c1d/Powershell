
<#
.SYNOPSIS
  Collects Windows LAPS event logs.

.DESCRIPTION
  - Works even if Get-LapsPolicy / Get-LapsAADPassword are not present.
  - Reads LAPS policy from registry (known Windows LAPS policy paths).
  - Dumps LAPS Operational events and backup success/failure.
  - Lists local accounts for quick verification.

.PARAMETER Days
  Number of days back to query (default: 7).
#>

[CmdletBinding()]
param(
    [int]$Days = 7
)

$ErrorActionPreference = 'Stop'
$computer = $env:COMPUTERNAME
$start = (Get-Date).AddDays(-[math]::Abs($Days))
$logDir = 'C:\Temp'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory | Out-Null }
$logPath = Join-Path $logDir ("LAPS_Logs_{0}.txt" -f $computer)

function Write-Section {
    param([string]$Title)
    $line = ('=' * 90)
    Write-Host "`n$line" -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkGray
    Add-Content -Path $logPath -Value "`n$line`n$Title`n$line"
}

function Write-Log {
    param([string]$Text)
    Write-Host $Text
    Add-Content -Path $logPath -Value $Text
}

"Windows LAPS Log Capture - $(Get-Date)" | Set-Content -Path $logPath
Write-Host ("Output log: {0}" -f $logPath) -ForegroundColor Yellow

# 1) Windows LAPS Feature Status
Write-Section "1) Windows LAPS Feature Status"
try {
    $feat = Get-WindowsOptionalFeature -Online -FeatureName WindowsLAPS -ErrorAction SilentlyContinue
    if ($feat) {
        $feat | Format-List FeatureName, State | Out-String | Write-Log
    } else {
        Write-Log "WindowsLAPS optional feature not reported (older build or feature not present)."
    }
} catch {
    Write-Log ("INFO: Could not query Windows optional features: {0}" -f $_.Exception.Message)
}

# 2) Attempt to read Windows LAPS policy from registry (best-effort)
Write-Section "2) Windows LAPS Policy (registry best-effort)"
$possibleKeys = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LAPS',          # common Windows LAPS policy path
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS', # alternate
    'HKLM:\SOFTWARE\Policies\Microsoft Services\LAPS'          # rare / transitional
)
$foundPolicy = $false
foreach ($key in $possibleKeys) {
    try {
        if (Test-Path $key) {
            Write-Log ("Policy key found: {0}" -f $key)
            $props = Get-ItemProperty -Path $key
            $foundPolicy = $true
            $props |
              Select-Object * |
              Format-List | Out-String | Write-Log
        }
    } catch {
        Write-Log ("INFO: Could not read {0}: {1}" -f $key, $_.Exception.Message)
    }
}
if (-not $foundPolicy) {
    Write-Log "No LAPS policy registry keys found (policy may be coming from Intune only and reported via events)."
    Write-Log "Check Event ID 10044 below for effective policy applied."
}

# 3) Local Accounts Overview
Write-Section "3) Local Accounts Overview"
try {
    Get-LocalUser | Select-Object Name, Enabled, LastLogon |
      Format-Table -AutoSize | Out-String | Write-Log
} catch {
    Write-Log ("ERROR: Get-LocalUser failed: {0}" -f $_.Exception.Message)
}

# 4) LAPS Operational Events
Write-Section "4) LAPS Operational Events (last $Days days)"
$lapLogName = "Microsoft-Windows-LAPS/Operational"
try {
    $events = Get-WinEvent -LogName $lapLogName -ErrorAction Stop |
              Where-Object { $_.TimeCreated -ge $start } |
              Sort-Object TimeCreated

    if (-not $events) {
        Write-Log "No LAPS events found in the last $Days days."
    } else {
        $events |
          Select-Object TimeCreated, Id, LevelDisplayName, Message |
          Format-Table -Wrap -AutoSize | Out-String | Write-Log

        Write-Log "`n---- Parsed reset summary ----"
        $parsed = foreach ($ev in $events) {
            $reason = $null
            $account = $null

            if ($ev.Message -match "account '?([^']+)'?") { $account = $Matches[1] }
            elseif ($ev.Message -match "Account Name:\s*(.+)$") { $account = $Matches[1].Trim() }

            switch ($ev.Id) {
                10031 { $reason = "Password reset completed" }
                10038 { $reason = "Post-authentication reset" }
                10044 { $reason = "Effective policy applied" }
                10033 { $reason = "Backup succeeded (AAD)" }
                10034 { $reason = "Backup failed (AAD)" }
                Default { $reason = "Other" }
            }

            if (-not $reason -or $reason -eq "Password reset completed") {
                if ($ev.Message -match "(policy compliance|policy enforcement)") { $reason = "Reset for policy compliance" }
                elseif ($ev.Message -match "(manual|admin triggered|user initiated)") { $reason = "Manual reset action" }
                elseif ($ev.Message -match "(backup fail|could not back up|AAD backup failed)") { $reason = "Reset due to backup failure" }
                elseif ($ev.Message -match "(post-auth)") { $reason = "Post-authentication reset" }
            }

            [pscustomobject]@{
                TimeCreated = $ev.TimeCreated
                EventId     = $ev.Id
                Reason      = $reason
                Account     = $account
                Message     = ($ev.Message -replace '\s+', ' ').Trim()
            }
        }

        $parsed |
          Where-Object { $_.EventId -in 10031,10038,10044,10033,10034 } |
          Format-Table TimeCreated, EventId, Reason, Account -AutoSize |
          Out-String | Write-Log
    }
} catch {
    Write-Log ("ERROR: Unable to read LAPS event log: {0}" -f $_.Exception.Message)
}

# 5) Backup Events (quick)
Write-Section "5) Backup Events (AAD backup success/failure)"
try {
    $bkpEvents = Get-WinEvent -LogName $lapLogName -ErrorAction Stop |
                 Where-Object { $_.TimeCreated -ge $start -and ($_.Id -eq 10033 -or $_.Id -eq 10034) } |
                 Select-Object TimeCreated, Id, Message |
                 Sort-Object TimeCreated
    if ($bkpEvents) {
        $bkpEvents | Format-Table -Wrap -AutoSize | Out-String | Write-Log        $bkpEvents | Format-Table -Wrap -AutoSize | Out-String | Write-Log
    } else {
        Write-Log "No backup events in the last $Days days."
    }
} catch {
    Write-Log ("ERROR: Unable to read backup events: {0}" -f $_.Exception.Message)
}

Write-Section "END"
