<#
.SYNOPSIS
  Verifies VBS, HVCI (Memory Integrity), System Guard Secure Launch, UEFI MAT,
  and Kernel-mode hardware-enforced stack protection (Shadow Stack).

.NOTES
  Run as Administrator.
#>

# region Utility
function Test-Admin {
    $curr = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $curr).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Warning "Please run this script in an elevated PowerShell session (Run as administrator)."
    return
}

# Color helpers
function Write-Ok($msg){ Write-Host "[OK]  $msg" -ForegroundColor Green }
function Write-Warn($msg){ Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Bad($msg){ Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Info($msg){ Write-Host "[INFO] $msg" -ForegroundColor Cyan }

# Safe registry getter
function Get-RegValue {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name
    )
    try {
        $val = (Get-ItemProperty -LiteralPath $Path -ErrorAction Stop).$Name
        return $val
    } catch {
        return $null
    }
}
# endregion Utility

# region Checks

# 1) DeviceGuard / VBS / HVCI core status via WMI
$dg = Get-CimInstance -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue

# 2) Process mitigations (Shadow Stack / Kernel-mode protections)
$pm = $null
try { $pm = Get-ProcessMitigation -System } catch {}

# 3) Secure Launch indicators
$regDG      = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
$enableSL   = Get-RegValue -Path $regDG -Name EnableSecureLaunch
# msinfo32 stores a state too, but reading live registry + bcdedit is sufficient
$bcd = $null
try {
    $bcd = bcdedit /enum "{current}" 2>$null | Out-String
} catch {}

# 4) HVCI / Memory Integrity registry
$hvciReg = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
$hvciEnabled = Get-RegValue -Path $hvciReg -Name Enabled

# 5) UEFI Memory Attributes Table requirement (PolicyManager & runtime presence)
$pmReqPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceGuard"
$uefiMatRequired = Get-RegValue -Path $pmReqPath -Name RequireUEFIMemoryAttributesTable
# Runtime presence is indicated when VBS/HVCI is functional on modern systems; we’ll reflect both policy + effective state

# 6) Core isolation "Memory integrity" UI flag (optional check)
$coreIsoReg = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
$coreIsoUi = Get-RegValue -Path $coreIsoReg -Name Enabled

# 7) Credential Guard (optional)
$cgReg = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard"
$cgEnabled = Get-RegValue -Path $cgReg -Name Enabled

# 8) Platform security features requirement
$reqPlatSec = Get-RegValue -Path $pmReqPath -Name RequirePlatformSecurityFeatures

# 9) DeviceGuard configured vs running services
$dgConfigured = $null
$dgRunning = $null
if ($dg) {
    $dgConfigured = $dg.SecurityServicesConfigured
    $dgRunning    = $dg.SecurityServicesRunning
}

# Map codes to names (per Win32_DeviceGuard docs)
$svcMap = @{
    1 = "Credential Guard"
    2 = "Hypervisor Code Integrity (HVCI)"
    3 = "Secure Launch / SMM protection"
}

function Resolve-Services([int[]]$codes) {
    if (-not $codes) { return @() }
    $codes | ForEach-Object { if ($svcMap.ContainsKey($_)) { $svcMap[$_] } else { "Unknown($_)" } }
}

# 10) Shadow Stack status from Get-ProcessMitigation
$shadowStack = $null
$kernelShadowStack = $null
try {
    if ($pm) {
        $shadowStack = $pm.Process.System | Select-Object -ExpandProperty ShadowStack -ErrorAction SilentlyContinue
        # Kernel shadow stack typically reflected via System mitigations in newer builds; additional signals:
        $kernelShadowStack = $pm.System | Select-Object -ExpandProperty ShadowStack -ErrorAction SilentlyContinue
    }
} catch {}

# Compose result object
$result = [ordered]@{}

# VBS state
$vbsConfigured = ($dgConfigured -and ($dgConfigured -contains 2 -or $dgConfigured -contains 1 -or $dgConfigured -contains 3))
$vbsRunning    = ($dgRunning    -and ($dgRunning    -contains 2 -or $dgRunning    -contains 1 -or $dgRunning    -contains 3))
$result.VBS_ConfiguredServices = (Resolve-Services $dgConfigured)
$result.VBS_RunningServices    = (Resolve-Services $dgRunning)
$result.VBS_IsActive           = [bool]$vbsRunning

# HVCI state
$hvciActive = $false
if ($dgRunning -and $dgRunning -contains 2) { $hvciActive = $true }
elseif ($hvciEnabled -ne $null) { $hvciActive = ($hvciEnabled -eq 1) } # 1=On, 0=Off
$result.HVCI_RegistryEnabled   = $hvciEnabled
$result.HVCI_IsActive          = $hvciActive

# Secure Launch state
# EnableSecureLaunch: 0/1; bcdedit hypervisorsettings secureboot? We’ll primarily trust registry + DeviceGuard services (3)
$secureLaunchActive = $false
if ($dgRunning -and $dgRunning -contains 3) { $secureLaunchActive = $true }
elseif ($enableSL -ne $null) { $secureLaunchActive = ($enableSL -eq 1) }

$result.SecureLaunch_Registry   = $enableSL
$result.SecureLaunch_bcdeditRaw = ($bcd -replace "`r","").Trim()
$result.SecureLaunch_IsActive   = $secureLaunchActive

# UEFI MAT
$result.UEFI_MAT_RequiredPolicy = $uefiMatRequired

# Credential Guard (optional)
$result.CredentialGuard_Registry = $cgEnabled
$result.CredentialGuard_IsActive = ($dgRunning -and $dgRunning -contains 1)

# Kernel-mode hardware-enforced stack protection (Shadow Stack signals)
# Shadow Stack for processes and/or system:
$result.ShadowStack_ProcessSignal = if ($shadowStack) { $shadowStack } else { $null }
$result.ShadowStack_SystemSignal  = if ($kernelShadowStack) { $kernelShadowStack } else { $null }

# Platform security features requirement (Secure Boot/TPM levels)
$result.RequirePlatformSecurityFeatures = $reqPlatSec

# endregion Checks

# region Output (human-friendly)
Write-Host ""
Write-Host "==== Device Guard / System Guard Verification ====" -ForegroundColor White

# VBS
if ($result.VBS_IsActive) {
    Write-Ok "VBS is ACTIVE  → Running services: $($result.VBS_RunningServices -join ', ')"
} else {
    if ($result.VBS_ConfiguredServices.Count -gt 0) {
        Write-Warn "VBS is NOT ACTIVE, but configured services exist: $($result.VBS_ConfiguredServices -join ', ')"
    } else {
        Write-Bad "VBS is NOT ACTIVE"
    }
}

# HVCI
if ($result.HVCI_IsActive) {
    Write-Ok "HVCI (Memory Integrity) is ACTIVE"
} else {
    Write-Bad "HVCI (Memory Integrity) is NOT active (Reg Enabled=$($result.HVCI_RegistryEnabled))"
}

# Secure Launch
if ($result.SecureLaunch_IsActive) {
    Write-Ok "System Guard Secure Launch is ACTIVE"
} else {
    Write-Warn "System Guard Secure Launch is NOT active (Reg EnableSecureLaunch=$($result.SecureLaunch_Registry))."
}

# UEFI MAT
if ($result.UEFI_MAT_RequiredPolicy -eq 1) {
    Write-Ok "UEFI Memory Attributes Table is REQUIRED by policy"
} elseif ($null -eq $result.UEFI_MAT_RequiredPolicy) {
    Write-Warn "UEFI MAT policy requirement not set (null)"
} else {
    Write-Warn "UEFI MAT policy requirement not enforced (value=$($result.UEFI_MAT_RequiredPolicy))"
}

# Shadow Stack (kernel-mode stack protection signal)
$ssSignals = @()
if ($result.ShadowStack_SystemSignal) { $ssSignals += "System:$($result.ShadowStack_SystemSignal)" }
if ($result.ShadowStack_ProcessSignal) { $ssSignals += "Process:$($result.ShadowStack_ProcessSignal)" }
if ($ssSignals.Count -gt 0) {
    Write-Ok "Shadow Stack signals present → $($ssSignals -join ' | ')"
} else {
    Write-Warn "Shadow Stack signals not reported by Get-ProcessMitigation (may vary by build; verify via Security Center UI)."
}

# Credential Guard (optional)
if ($result.CredentialGuard_IsActive) {
    Write-Ok "Credential Guard is ACTIVE"
} elseif ($null -ne $result.CredentialGuard_Registry) {
    Write-Info "Credential Guard Registry=$($result.CredentialGuard_Registry) (Active=$($result.CredentialGuard_IsActive))"
}

Write-Host ""
Write-Info "Tip: Reboot may be required after enabling VBS/HVCI/Secure Launch."
Write-Host ""

# Machine-readable object
$object = [PSCustomObject]$result

# Print compact JSON preview to console (optional)
Write-Info "Detailed JSON (preview):"
$object | ConvertTo-Json -Depth 5

# Export options (comment/uncomment as needed)
# $out = Join-Path $env:ProgramData "DG_Verification_$(Get-Date -Format yyyyMMdd_HHmmss).json"
# $object | ConvertTo-Json -Depth 5 | Out-File -FilePath $out -Encoding UTF8
# Write-Info "Saved results to: $out"
# endregion Output