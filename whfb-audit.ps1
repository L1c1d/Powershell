# Windows Hello for Business audit
# Writes a .cvs report (WHfB_Audit_Report.csv) to the desktop showing status for....
# AzureADJoined, DomainJoined, TPMStatus, WHfBPolicyEnabled, SharedPCMode, WHfBProvisioned



$ErrorActionPreference = 'Stop'

$results = @()
$computerName = $env:COMPUTERNAME

# ----- Device Join Status (robust regex parsing) -----
$aadJoined = $null
$domainJoined = $null
try {
    $dsregText = (dsregcmd /status | Out-String)
    $aadJoined    = ([regex]::Match($dsregText, 'AzureADJoined\s*:\s*(YES|NO)', 'IgnoreCase')).Groups[1].Value.ToUpper()
    $domainJoined = ([regex]::Match($dsregText, 'DomainJoined\s*:\s*(YES|NO)', 'IgnoreCase')).Groups[1].Value.ToUpper()

    if (-not $aadJoined)    { $aadJoined = 'UNKNOWN' }
    if (-not $domainJoined) { $domainJoined = 'UNKNOWN' }
}
catch {
    $aadJoined = 'ERROR'
    $domainJoined = 'ERROR'
}

# ----- TPM Status (use CIM) -----
$tpmStatus = 'TPM not available'
try {
    $tpm = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -ClassName Win32_Tpm -ErrorAction Stop
    if ($tpm) {
        $tpmStatus = '{0}, {1}' -f $tpm.IsPresent, $tpm.IsReady
    }
}
catch {
    $tpmStatus = 'TPM query failed'
}

# ----- WHfB Policy (PassportForWork) -----
$whfbPolicy = 'Not Found'
try {
    $pfwPath = 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork'
    if (Test-Path $pfwPath) {
        $policy = Get-ItemProperty $pfwPath
        # Enabled is commonly used: 1 = enabled, 0 = disabled
        $whfbPolicy = if ($policy.PSObject.Properties.Name -contains 'Enabled') { $policy.Enabled } else { 'Found (no Enabled value)' }
    }
}
catch { $whfbPolicy = 'Policy read error' }

# ----- Shared PC Mode -----
$sharedPCMode = 'Not Found'
try {
    $spcPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC'
    if (Test-Path $spcPath) {
        $spc = Get-ItemProperty $spcPath
        $sharedPCMode = if ($spc.PSObject.Properties.Name -contains 'EnableSharedPCMode') { $spc.EnableSharedPCMode } else { 'Found (no EnableSharedPCMode value)' }
    }
}
catch { $sharedPCMode = 'Policy read error' }

# ----- WHfB Provisioning (current user oriented) -----
# Prefer user NGC status; if not available (e.g., running as SYSTEM), fall back to original key check
$whfbProvisioned = 'Unknown'
try {
    $ngcStatusPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Ngc\Status'
    if (Test-Path $ngcStatusPath) {
        $ngc = Get-ItemProperty $ngcStatusPath
        # Status typically 1 when provisioned
        if ($ngc.PSObject.Properties.Name -contains 'Status') {
            $whfbProvisioned = if ($ngc.Status -eq 1) { 'Provisioned' } else { 'Not Provisioned' }
        } else {
            $whfbProvisioned = 'Status value not present'
        }
    } else {
        # Fallback to your original heuristic
        $fallbackPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\SessionData'
        $whfbProvisioned = if (Test-Path $fallbackPath) { 'Provisioned (heuristic)' } else { 'Not Provisioned (heuristic)' }
    }
}
catch {
    $whfbProvisioned = 'Provisioning check failed'
}

# ----- Collect -----
$results += [PSCustomObject]@{
    ComputerName       = $computerName
    AzureADJoined      = $aadJoined
    DomainJoined       = $domainJoined
    TPMStatus          = $tpmStatus
    WHfBPolicyEnabled  = $whfbPolicy
    SharedPCMode       = $sharedPCMode
    WHfBProvisioned    = $whfbProvisioned
}

# ----- Export -----
$csvPath = Join-Path $env:USERPROFILE 'Desktop\WHfB_Audit_Report.csv'
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "Audit complete. CSV saved to: $csvPath"