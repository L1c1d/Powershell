<#
.SYNOPSIS
  Enforce Windows Error Reporting (WER) LocalDumps policy to prevent large user-mode dump files.
  Windows 11 device showed "System & Storage' was at 260GB, leaving very little storage left on the drive.
  A service was crashing on this device repeatedly and triggering the creation of dump files.
  These dump files were very large, 5-7GB each.
  Each new crash writes a fresh .dmp file into a Temp folder (C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp)
  that windows recognizes as System & Storage, quickly consuming hundreds of GB. 

.DESCRIPTION
  - Sets system-wide WER LocalDumps to DumpType=1 (mini-dump) and DumpCount=5.
  - Configures a secure DumpFolder (default C:\CrashDumps).
  - Applies to both native and WOW64 (32-bit) apps.
  - Optional: -Clean will remove existing *.dmp files >= 1 GB in common locations.

.PARAMETER DumpFolder
  Target folder for future WER dumps. Default: C:\CrashDumps

.PARAMETER DumpType
  1 = Mini dump (recommended), 2 = Full dump (not recommended). Default: 1

.PARAMETER DumpCount
  Max number of dumps to retain (oldest purged first). Default: 5

.PARAMETER Clean
  If set, deletes existing *.dmp files >= 1 GB from known locations.

#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$DumpFolder = 'C:\CrashDumps',
    [ValidateSet(1,2)]
    [int]$DumpType = 1,
    [ValidateRange(1,100)]
    [int]$DumpCount = 5,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg){ Write-Host "[INFO ] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)  { Write-Host "[ OK  ] $msg" -ForegroundColor Green }
function Write-Warn($msg){ Write-Host "[WARN ] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "[ERR  ] $msg" -ForegroundColor Red }

function Ensure-FolderSecure($path){
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Write-Ok "Created $path"
    }
    # Lock down to SYSTEM and Administrators
    try {
        $acl = Get-Acl $path
        $acl.SetAccessRuleProtection($true, $false) # disable inheritance, remove inherited
        $rules = @(
            New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM','FullControl','ContainerInherit,ObjectInherit','None','Allow'),
            New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators','FullControl','ContainerInherit,ObjectInherit','None','Allow')
        )
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        foreach ($r in $rules){ $acl.AddAccessRule($r) | Out-Null }
        Set-Acl -Path $path -AclObject $acl
        Write-Ok "Secured ACL on $path (SYSTEM + Administrators)"
    } catch {
        Write-Warn "Failed to set ACL on $path: $($_.Exception.Message)"
    }
}

function Set-LocalDumpsPolicy($baseKey){
    New-Item -Path $baseKey -Force | Out-Null
    New-ItemProperty -Path $baseKey -Name DumpType  -PropertyType DWord        -Value $DumpType  -Force | Out-Null
    New-ItemProperty -Path $baseKey -Name DumpCount -PropertyType DWord        -Value $DumpCount -Force | Out-Null
    New-ItemProperty -Path $baseKey -Name DumpFolder -PropertyType ExpandString -Value $DumpFolder -Force | Out-Null
    Write-Ok "Configured WER at $baseKey (DumpType=$DumpType, DumpCount=$DumpCount, DumpFolder=$DumpFolder)"
}

function Show-LocalDumpsPolicy($baseKey){
    if (Test-Path $baseKey) {
        $props = Get-ItemProperty $baseKey
        [PSCustomObject]@{
            Key        = $baseKey
            DumpType   = $props.DumpType
            DumpCount  = $props.DumpCount
            DumpFolder = $props.DumpFolder
        }
    }
}

Write-Info "Enforcing WER LocalDumps (mini-dumps + capped retention)"
Ensure-FolderSecure -path $DumpFolder

# Apply to both native and WOW64 registry locations
$keys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\Windows Error Reporting\LocalDumps'
)
foreach ($k in $keys){ Set-LocalDumpsPolicy -baseKey $k }

# (Optional but helpful) Common crash hosts: ensure per-process mini-dumps too
$perProc = @('svchost.exe','dllhost.exe','werfault.exe','SearchIndexer.exe')
foreach ($exe in $perProc) {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\Windows Error Reporting\LocalDumps')) {
        $pp = Join-Path $root $exe
        New-Item -Path $pp -Force | Out-Null
        New-ItemProperty -Path $pp -Name DumpType  -PropertyType DWord        -Value $DumpType  -Force | Out-Null
        New-ItemProperty -Path $pp -Name DumpCount -PropertyType DWord        -Value $DumpCount -Force | Out-Null
        New-ItemProperty -Path $pp -Name DumpFolder -PropertyType ExpandString -Value $DumpFolder -Force | Out-Null
        Write-Ok "Per-process WER set for $exe at $pp"
    }
}

# Optional cleanup of existing giant dumps (>= 1 GB)
if ($Clean) {
    Write-Info "Cleaning existing large (*.dmp) files (>= 1 GB) from common locations…"
    $targets = @(
        'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp',
        'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Temp',
        $DumpFolder
    ) | Where-Object { Test-Path $_ }

    # Stop WER to avoid file locks during cleanup (optional)
    try { Stop-Service WerSvc -Force -ErrorAction SilentlyContinue } catch {}

    $deleted = 0
    $freed = 0
    foreach ($dir in $targets) {
        $files = Get-ChildItem $dir -Filter *.dmp -Force -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.Length -ge 1GB) {
                $freed += $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                $deleted++
            }
        }
    }

    try { Start-Service WerSvc -ErrorAction SilentlyContinue } catch {}
    Write-Ok ("Deleted {0} large dumps and freed {1} GB" -f $deleted, [math]::Round($freed/1GB,2))
}

Write-Info "Current WER LocalDumps configuration:"
$keys | ForEach-Object { Show-LocalDumpsPolicy $_ } | Format-Table -Auto

Write-Ok  "Done. New crashes will produce mini-dumps only, retained up to $DumpCount files in $DumpFolder."
Write-Info "No reboot required. To revert to defaults later, remove the LocalDumps registry keys."
