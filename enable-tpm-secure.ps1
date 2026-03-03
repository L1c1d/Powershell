#requires -RunAsAdministrator
<#
.SYNOPSIS
  Enables TPM and Secure Boot for Windows 11 readiness on HP commercial PCs.
  - Converts MBR->GPT (MBR2GPT) if needed, flips firmware to UEFI, enables TPM and Secure Boot.
  - Uses HP InstrumentedBIOS WMI; optional fallback to HP BCU if requested.

.NOTES
  Tested on HP EliteDesk/EliteBook lines. Requires admin. Reboots are expected.
  Exit codes:
    0    = No change needed (already compliant)
    3010 = Changes applied; reboot required
    1    = Error

.PARAMETER BiosPassword
  Optional BIOS Setup password as SecureString (used for HP WMI calls and/or BCU).

.PARAMETER UseBCU
  Force use of HP BCU (fallback when WMI provider missing or policy prefers BCU).

.PARAMETER BCUPath
  Path to BiosConfigUtility64.exe (required if -UseBCU).

.PARAMETER SkipMBR2GPT
  Skips disk conversion (assumes GPT/UEFI already).

.LOGS
  %ProgramData%\IntuneTools\TPM_SecureBoot\Enable-TpmSecureBoot_*.log
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [SecureString]$BiosPassword,
  [switch]$UseBCU,
  [string]$BCUPath,
  [switch]$SkipMBR2GPT
)

$ErrorActionPreference = 'Stop'

# --- Logging ------------------------------------------------------------------
$logDir = Join-Path $env:ProgramData 'IntuneTools\TPM_SecureBoot'
$null = New-Item -ItemType Directory -Path $logDir -Force
$log = Join-Path $logDir ("Enable-TpmSecureBoot_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $log -Force | Out-Null

function Write-Info($msg){ Write-Host "[INFO ] $msg" -ForegroundColor Cyan }
function Write-Warn($msg){ Write-Warning $msg }
function Write-Err ($msg){ Write-Error $msg }

# --- Preflight ----------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
  Write-Err "Must run as Administrator."
  Stop-Transcript | Out-Null
  exit 1
}

$cs = Get-CimInstance Win32_ComputerSystem
$manufacturer = ($cs.Manufacturer).Trim()
$model        = ($cs.Model).Trim()
Write-Info "Manufacturer: $manufacturer, Model: $model"

if ($manufacturer -notmatch 'HP|Hewlett-Packard') {
  Write-Warn "Non-HP device detected. HP InstrumentedBIOS WMI/BCU steps may not apply."
}

# Convert BIOS password to HP WMI format if provided
$BiosPwdUtf16 = $null
if ($BiosPassword) {
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($BiosPassword))
  $BiosPwdUtf16 = "<utf-16/>$plain"
}

# --- Helpers ------------------------------------------------------------------
function Get-HPWmi {
  try {
    $ns = 'root\HP\InstrumentedBIOS'
    $enumClass = Get-WmiObject -Namespace $ns -Class HP_BIOSEnumeration -ErrorAction Stop
    $ifClass   = Get-WmiObject -Namespace $ns -Class HP_BIOSSettingInterface -ErrorAction Stop
    return @{ Enum=$enumClass; If=$ifClass; Namespace=$ns }
  } catch {
    return $null
  }
}

function Set-HPBiosSetting {
  param(
    [Parameter(Mandatory)] [string[]]$CandidateNames,  # e.g. "Secure Boot","SecureBoot"
    [Parameter(Mandatory)] [string[]]$DesiredValues,   # e.g. "Enable","Enabled","Available"
    [string]$PasswordUtf16
  )
  $hp = Get-HPWmi
  if (-not $hp) { 
    Write-Warn "HP WMI: provider not available (root\HP\InstrumentedBIOS)."
    return $false 
  }

  $hit = $null
  foreach ($name in $CandidateNames) {
    $hit = $hp.Enum | Where-Object { $_.Name -like $name }
    if ($hit) { break }
  }
  if (-not $hit) {
    Write-Warn "HP WMI: none of [$($CandidateNames -join ', ')] present."
    return $false
  }

  $current = $hit.CurrentValue
  $allowed = $hit.Value
  Write-Info "HP WMI: '$($hit.Name)' current='$current'; allowed=[$($allowed -join ', ')]"

  $target = $DesiredValues | Where-Object { $allowed -contains $_ } | Select-Object -First 1
  if (-not $target) {
    Write-Warn "HP WMI: desired values '$($DesiredValues -join ',')' not available for '$($hit.Name)'."
    return $false
  }

  if ($current -eq $target) {
    Write-Info "HP WMI: '$($hit.Name)' already '$target'."
    return $true
  }

  $iface = $hp.If
  $res = if ($PasswordUtf16) {
    $iface.SetBIOSSetting($hit.Name, $target, $PasswordUtf16)
  } else {
    $iface.SetBIOSSetting($hit.Name, $target)
  }

  # Robust return-code handling: result can be an int or an object with .Return
  $code = $null
  if ($res -is [int]) {
    $code = $res
  } elseif ($res -and $res.PSObject.Properties['Return']) {
    $code = $res.Return
  } else {
    $code = -1
  }

  if ($code -eq 0) {
    Write-Info "HP WMI: set '$($hit.Name)' to '$target' OK."
    return $true
  } else {
    Write-Warn "HP WMI: failed to set '$($hit.Name)' to '$target' (code=$code)."
    return $false
  }
}

function Get-BootMode {
  # 2 = UEFI, 1 = Legacy
  try { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PEFirmwareType } catch { 0 }
}

function Is-GPT { ((Get-Disk -Number 0).PartitionStyle -eq 'GPT') }

# --- State --------------------------------------------------------------------
$rebootNeeded = $false
$madeChanges  = $false

$bootMode  = Get-BootMode
$diskStyle = (Get-Disk -Number 0).PartitionStyle
Write-Info "BootMode: $bootMode (2=UEFI,1=Legacy), Disk0: $diskStyle"

# --- Step 1: Legacy/MBR -> GPT + switch firmware to UEFI ----------------------
if (-not $SkipMBR2GPT -and ($bootMode -eq 1 -or $diskStyle -eq 'MBR')) {
  Write-Info "Preparing for MBR2GPT: suspending BitLocker if needed..."
  try {
    $osVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($osVol -and $osVol.ProtectionStatus -eq 'On') {
      Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 | Out-Null
      Write-Info "BitLocker suspended for 1 reboot."
    } else {
      Write-Info "BitLocker not active or not found."
    }
  } catch {
    Write-Warn "BitLocker module not available or query failed: $_"
  }

  Write-Info "Validating MBR2GPT..."
  $val = Start-Process -FilePath "$env:SystemRoot\System32\mbr2gpt.exe" -ArgumentList '/validate','/allowFullOS' -PassThru -Wait
  if ($val.ExitCode -ne 0) {
    Write-Err "MBR2GPT validation failed. ExitCode=$($val.ExitCode)"
    Stop-Transcript | Out-Null
    exit 1
  }

  Write-Info "Converting MBR->GPT..."
  $conv = Start-Process -FilePath "$env:SystemRoot\System32\mbr2gpt.exe" -ArgumentList '/convert','/allowFullOS' -PassThru -Wait
  if ($conv.ExitCode -ne 0) {
    Write-Err "MBR2GPT conversion failed. ExitCode=$($conv.ExitCode)"
    Stop-Transcript | Out-Null
    exit 1
  }
  $madeChanges = $true
  $rebootNeeded = $true
  Write-Info "MBR2GPT completed. Firmware must now be set to UEFI."

  # Flip firmware to UEFI / disable Legacy/CSM (HP WMI)
  $hpTried = $false
  if ($manufacturer -match 'HP|Hewlett-Packard') {
    $hpTried = $true
    $null = Set-HPBiosSetting -CandidateNames @('Legacy Support*','CSM*','Legacy Mode*') -DesiredValues @('Disable','Disabled') -PasswordUtf16 $BiosPwdUtf16
    $null = Set-HPBiosSetting -CandidateNames @('UEFI Boot*','UEFI*','Native UEFI*')     -DesiredValues @('Enable','Enabled','Native UEFI') -PasswordUtf16 $BiosPwdUtf16
  }

  if (-not $hpTried -and $UseBCU) {
    if (-not (Test-Path $BCUPath)) {
      Write-Warn "BCU requested but not found at '$BCUPath'."
    } else {
      Write-Info "Applying UEFI settings via BCU fallback..."
      $cfg = @"
BIOSConfig 1.0
Legacy Support
    Disable
UEFI Boot Options
    Enable
"@
      $tmp = Join-Path $env:TEMP "uefi_enable.txt"
      $cfg | Out-File -FilePath $tmp -Encoding ASCII -Force
      $args = @('/set',":`"$tmp`"")
      # If you deploy a password BIN with BCU, add: $args += @('/cspwd',':"C:\Path\BIOSPW.bin"')
      Start-Process -FilePath $BCUPath -ArgumentList $args -Wait -NoNewWindow
    }
  }

  Write-Info "Reboot is required to finish UEFI switch. Exiting 3010."
  Stop-Transcript | Out-Null
  exit 3010
}

# Refresh state if script is re-run after the first reboot
$bootMode = Get-BootMode
Write-Info "Current BootMode: $bootMode (2=UEFI expected)."

# --- Step 2: Ensure TPM is enabled/activated ----------------------------------
try {
  $tpm = Get-Tpm
  if (-not $tpm.TpmPresent -or -not $tpm.TpmEnabled) {
    Write-Info "Attempting to enable TPM via HP WMI..."
    $ok1 = Set-HPBiosSetting -CandidateNames @('TPM Device*','Embedded Security Device*','Security Device*') -DesiredValues @('Available','Enable','Enabled') -PasswordUtf16 $BiosPwdUtf16
    $ok2 = Set-HPBiosSetting -CandidateNames @('TPM State*','TPM Activation Policy*','TPM Activation*') -DesiredValues @('Enable','Enabled','Activate','Activate on Next Boot') -PasswordUtf16 $BiosPwdUtf16
    if ($ok1 -or $ok2) {
      $madeChanges = $true; $rebootNeeded = $true
      Write-Info "TPM setting changed, reboot required."
    } else {
      Write-Warn "Could not change TPM via WMI. If HP BCU is available, re-run with -UseBCU."
    }
  } else {
    Write-Info "TPM already present and enabled."
  }
} catch {
  Write-Warn "Get-TPM query failed: $_"
}

# --- Step 3: Enable Secure Boot (UEFI only) -----------------------------------
if ($bootMode -ne 2) {
  Write-Warn "Device is not in UEFI mode yet; cannot enable Secure Boot."
} else {
  $sb = $false
  try { $sb = Confirm-SecureBootUEFI } catch { $sb = $false }
  if (-not $sb) {
    Write-Info "Attempting to enable Secure Boot via HP WMI..."
    $okSB = Set-HPBiosSetting -CandidateNames @('Secure Boot*','SecureBoot*') -DesiredValues @('Enable','Enabled') -PasswordUtf16 $BiosPwdUtf16
    if ($okSB) { $madeChanges = $true; $rebootNeeded = $true }
    else {
      Write-Warn "Could not set Secure Boot via WMI; on some models you may need to 'Install default keys' in firmware UI or use BCU."
    }
  } else {
    Write-Info "Secure Boot already enabled."
  }
}

# --- Exit path ----------------------------------------------------------------
if ($rebootNeeded) {
  Write-Info "Changes queued. Exit 3010 to trigger reboot via Intune."
  Stop-Transcript | Out-Null
  exit 3010
}

# Final detection
$finalTpm = $null; $finalSB = $false
try { $finalTpm = Get-Tpm } catch {}
try { $finalSB = Confirm-SecureBootUEFI } catch {}

if ($finalTpm -and $finalTpm.TpmPresent -and $finalTpm.TpmEnabled -and $finalSB) {
  Write-Info "✅ TPM enabled and Secure Boot enabled. Windows 11 readiness achieved."
  Stop-Transcript | Out-Null
  exit 0
} else {
  Write-Warn "One or more requirements still missing. See log: $log"
  Stop-Transcript | Out-Null
  exit 1
}