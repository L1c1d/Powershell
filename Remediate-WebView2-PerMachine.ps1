<#
  - Downloads official Microsoft webview2 bootstrapper
  - Installs WebView2 per-machine silently (when run as SYSTEM)
  - Logs to IME logs folder and verifies installation
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- Config ---
$ScriptName   = 'Install-WebView2-PerMachine'
$LogFolder    = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
$LogPath      = Join-Path $LogFolder    ("{0}-{1}.log" -f $ScriptName, (Get-Date).ToFileTimeUtc())
$TempSetup    = Join-Path $env:TEMP     'MicrosoftEdgeWebview2Setup.exe'

# Microsoft official evergreen bootstrapper link (documented by Microsoft)
$BootstrapperLink = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'   # WebView2 Runtime Bootstrapper (Evergreen)
# Per-machine detection key on 64-bit Windows (documented)
$Wv2Guid  = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$RegPath  = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$Wv2Guid"

# --- Logging ---
if (-not (Test-Path -LiteralPath $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
Start-Transcript -Path $LogPath -Append | Out-Null

Write-Host "[$ScriptName] Starting remediation at $(Get-Date -Format o)"
Write-Host "[$ScriptName] Downloading WebView2 bootstrapper from: $BootstrapperLink"

# Ensure TLS 1.2 for Invoke-WebRequest (older stacks)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Download the official bootstrapper
Invoke-WebRequest -Uri $BootstrapperLink -OutFile $TempSetup -UseBasicParsing

if (-not (Test-Path -LiteralPath $TempSetup)) {
    throw "Bootstrapper download failed: $TempSetup not found."
}

# Run silent install; elevated SYSTEM -> per-machine install (per Microsoft docs)
# Alternative: if you package the Standalone Installer EXE, you can run '/silent /install' on that file too.
$Args = '/silent /install'
Write-Host "[$ScriptName] Running: `"$TempSetup`" $Args"
$process = Start-Process -FilePath $TempSetup -ArgumentList $Args -PassThru -Wait -WindowStyle Hidden
Write-Host "[$ScriptName] Installer exit code: $($process.ExitCode)"

# --- Validation ---
$pv = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).pv
if ([string]::IsNullOrWhiteSpace($pv) -or $pv -eq '0.0.0.0') {
    throw "WebView2 per-machine still not detected or invalid after install. pv='$pv'"
}

try { 
    [void][Version]$pv 
    Write-Host "[$ScriptName] Success: WebView2 per-machine installed. pv='$pv'"
}
catch {
    throw "WebView2 per-machine version not a valid semantic version. pv='$pv'"
}

# Cleanup (optional)
try { Remove-Item -LiteralPath $TempSetup -Force -ErrorAction SilentlyContinue } catch {}

Stop-Transcript | Out-Null
exit 0
