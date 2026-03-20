# Remediate-ProToEnterprise-KMS.ps1
# If device is on pro and not enterprise, convert to enterprise.
# Performs: Install's Enterprise GVLK, set's KMS host, force's activation, log's results.
# You need to set your own value for $DefaultKmsHost 


[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param()

$ErrorActionPreference = 'Stop'

# === Settings ===
$LogRoot = "C:\windows\temp\protoenterprise"
$Log     = Join-Path $LogRoot "protoenterprise.log"

# Your KMS host (fallback if DNS _vlmcs._tcp not present)
$DefaultKmsHost = "yourKMSservernamehere"

# Windows 11/10 Enterprise (non-N) GVLK
# Ref: Microsoft GVLK list for KMS clients (Windows 11 Enterprise)
$EnterpriseGvlk = "XGVPP-NMH47-7TTHJ-W3FW7-8HV2C"

# If you have any Pro N devices, supply the Enterprise N GVLK here (optional).
# If left empty, we will still try the non-N key.
$EnterpriseNGvlk = ""   # e.g. "TBN2J-..." if you want to support Pro N explicitly.

# === Helpers ===
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SLMGR')][string]$Level = "INFO")
    if (-not (Test-Path $LogRoot)) { New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null }
    $line = "{0:u} [{1}] {2}" -f (Get-Date), $Level, $Message
    $line | Tee-Object -FilePath $Log -Append | Out-Null
}

function Invoke-Slmgr {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string[]]$Args)
    Write-Log ("slmgr " + ($Args -join ' '))
    if (-not $PSCmdlet.ShouldProcess("slmgr $($Args -join ' ')")) { 
        Write-Log "Skipped by ShouldProcess" "SLMGR"; 
        return @{ ExitCode = 0; StdOut = "[Skipped]"; StdErr = "" } 
    }
    $cmd = "$env:windir\system32\cscript.exe"
    $allArgs = @("//Nologo", "$env:windir\system32\slmgr.vbs") + $Args
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $cmd
    $psi.Arguments              = ($allArgs -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($stdout) { Write-Log $stdout.Trim() "SLMGR" }
    if ($stderr) { Write-Log $stderr.Trim() "SLMGR" }
    return @{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Get-LicenseProduct {
    Get-CimInstance -ClassName SoftwareLicensingProduct |
        Where-Object { $_.Name -like "Windows*" -and $_.PartialProductKey } |
        Select-Object -First 1
}

function IsClientOS {
    try { (Get-CimInstance Win32_OperatingSystem).ProductType -eq 1 } catch { $true }
}

# === Start ===
Write-Log "===== KMS Enterprise Remediation start ====="

if (-not (IsClientOS)) {
    Write-Log "Non-client OS detected. Exiting success to avoid touching servers."
    exit 0
}

$ci = Get-ComputerInfo
$editionName = $ci.WindowsProductName
$editionId   = $ci.WindowsEditionId
Write-Log "Detected edition: $editionName (EditionId=$editionId)"

# Figure out which key to use
$keyToUse = $EnterpriseGvlk
if ($editionId -match "ProfessionalN" -and $EnterpriseNGvlk) {
    $keyToUse = $EnterpriseNGvlk
    Write-Log "Pro N detected; using Enterprise N GVLK."
}

# If not already Enterprise, install the Enterprise GVLK (converts Pro -> Enterprise in-place)
if ($editionName -notmatch "Enterprise") {
    $res = Invoke-Slmgr -Args "/ipk", $keyToUse
    if ($res.ExitCode -ne 0) { 
        Write-Log "Failed to install Enterprise GVLK. ExitCode=$($res.ExitCode)" "ERROR"
        exit 1
    }
    try { Restart-Service -Name sppsvc -Force -ErrorAction Stop; Write-Log "Restarted sppsvc." } catch { Write-Log "sppsvc restart error: $_" "WARN" }
}

# Decide KMS host: prefer DNS SRV, fallback to your host
$kmsHost = $null
try {
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    if ($domain) {
        $srv = Resolve-DnsName -Type SRV "_vlmcs._tcp.$domain" -ErrorAction SilentlyContinue
        if ($srv) { $kmsHost = ($srv | Sort-Object -Property Priority,Weight | Select-Object -First 1).NameTarget.TrimEnd('.') }
    }
} catch { }

if (-not $kmsHost) { $kmsHost = $DefaultKmsHost; Write-Log "DNS SRV not found; using default host $kmsHost" }

# Point to KMS explicitly (safe even if DNS exists)
$null = Invoke-Slmgr -Args "/skms", $kmsHost

# Try activation
$null = Invoke-Slmgr -Args "/ato"

Start-Sleep -Seconds 5
$prod = Get-LicenseProduct
$licensed = $prod -and ($prod.LicenseStatus -eq 1) -and ($prod.ProductKeyChannel -match '^VOLUME_KMS')
Write-Log ("Post-activation: LicenseStatus={0}, Channel={1}" -f $prod.LicenseStatus, $prod.ProductKeyChannel)

if ($licensed) {
    Write-Log "Activation successful."
    Write-Log "===== KMS Enterprise Remediation end (success) ====="
    exit 0
}

# Fallback: clear explicit host -> rely on DNS and try again
Write-Log "First activation attempt failed; trying DNS discovery."
$null = Invoke-Slmgr -Args "/ckms"
Start-Sleep -Seconds 2
$null = Invoke-Slmgr -Args "/ato"
Start-Sleep -Seconds 5

$prod = Get-LicenseProduct
$licensed = $prod -and ($prod.LicenseStatus -eq 1) -and ($prod.ProductKeyChannel -match '^VOLUME_KMS')

if ($licensed) {
    Write-Log "Activation successful via DNS."
    Write-Log "===== KMS Enterprise Remediation end (success) ====="
    exit 0
} else {
    Write-Log "Activation still not licensed. Exiting with failure." "ERROR"
    Write-Log "===== KMS Enterprise Remediation end (failed) ====="
    exit 1
}
