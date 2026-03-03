#  Resets windows update. Stops services, applies fixes, starts services again.
#  Useful for any issues with windows updates. Failure, errors, etc....
#  Requires -RunAsAdministrator


param(
    [switch]$ClearTRV,
    [switch]$NetworkReset,
    [switch]$NoScan
)

Write-Host "== Windows Update reset starting ==" -ForegroundColor Cyan

# Try to quiet any active WU workers
$procNames = 'usocoreworker.exe','MoUsoCoreWorker.exe','wuauclt.exe'
foreach ($p in $procNames) {
    Stop-Process -Name $p -Force -ErrorAction SilentlyContinue
}

# Services to stop/start (order matters for catroot2 rename)
$stopOrder  = 'UsoSvc','wuauserv','bits','cryptsvc','msiserver'
$startOrder = 'cryptsvc','bits','wuauserv','UsoSvc','msiserver'

foreach ($svc in $stopOrder) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') {
        Write-Host "Stopping $svc..." -ForegroundColor DarkGray
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
    }
}

# Clear any lingering BITS jobs (do before folder work)
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -Confirm:$false
} catch {}

# Paths
$sdPath = Join-Path $env:windir 'SoftwareDistribution'
$crPath = Join-Path $env:windir 'System32\catroot2'
$ts     = (Get-Date).ToString('yyyyMMdd_HHmmss')

# Rename (preferred) so you can roll back; if rename fails, purge contents
function Safe-RotateFolder {
    param([string]$Path)
    if (Test-Path $Path) {
        $bak = "$Path.bak_$ts"
        try {
            Write-Host "Rotating $Path -> $bak" -ForegroundColor DarkGray
            Rename-Item -Path $Path -NewName $bak -ErrorAction Stop
        } catch {
            Write-Host "Rename failed; purging contents of $Path" -ForegroundColor Yellow
            try { Remove-Item -Path (Join-Path $Path '*') -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# Rebuild working folders
Safe-RotateFolder -Path $sdPath
Safe-RotateFolder -Path $crPath

# Clear UX pause flags (does NOT erase ring settings)
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
if (Test-Path $ux) {
    'PauseFeatureStatus','PauseFeatureUpdatesStartTime','PauseFeatureUpdatesEndTime' |
        ForEach-Object { Remove-ItemProperty -Path $ux -Name $_ -ErrorAction SilentlyContinue }
}

# Optional: Clear TRV pinning/deferrals/policy pins
if ($ClearTRV) {
    Write-Host "Clearing TargetReleaseVersion/ProductVersion/Deferrals..." -ForegroundColor Yellow
    $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if (Test-Path $wuPol) {
        'ProductVersion','TargetReleaseVersion','TargetReleaseVersionInfo','DeferFeatureUpdatesPeriodInDays' |
            ForEach-Object { Remove-ItemProperty -Path $wuPol -Name $_ -ErrorAction SilentlyContinue }
    }
}

# Restart services
foreach ($svc in $startOrder) {
    Write-Host "Starting $svc..." -ForegroundColor DarkGray
    Start-Service $svc -ErrorAction SilentlyContinue
}

# Optional: Reset Winsock (requires reboot)
if ($NetworkReset) {
    Write-Host "Running 'netsh winsock reset' (reboot required)..." -ForegroundColor Yellow
    & netsh winsock reset | Out-Null
}

# Trigger a fresh scan
if (-not $NoScan) {
    Write-Host "Triggering Windows Update scan..." -ForegroundColor DarkGray
    Start-Process "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList 'StartInteractiveScan' -WindowStyle Hidden
    try { (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow() } catch {}
}

Write-Host "== Done. Backups (if created):" -ForegroundColor Cyan
if (Test-Path "$sdPath.bak_$ts") { Write-Host "   $sdPath.bak_$ts" -ForegroundColor Cyan }
if (Test-Path "$crPath.bak_$ts") { Write-Host "   $crPath.bak_$ts" -ForegroundColor Cyan }