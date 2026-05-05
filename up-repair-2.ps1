# ============================================================
# Script B - SYSTEM CONTEXT
# Universal print has issues with some print helper apps such as xerox print & scan experience
# This is part two of a two part script
# Run this script as admin.
# Detects and removes Xerox PSA + enables Protected Print
# ============================================================

$FlagFile   = "C:\ProgramData\Intune-UP\UPPrintersRemoved.flag"
$packageName = 'XeroxCorp.PrintExperience'
$eventSource = 'Intune-Xerox-PSA'
$logName     = 'Application'

Write-Output "Starting system remediation..."

# ---- Check flag ----
if (-not (Test-Path $FlagFile)) {
    Write-Output "User flag not found. Skipping system remediation."
    exit 0
}

Write-Output "Flag detected. Proceeding with system changes."

# ---- Ensure Event Log source ----
if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    New-EventLog -LogName $logName -Source $eventSource
}

# ============================================================
# Remove Xerox Print and Scan Experience
# ============================================================

$psaPackages = Get-AppxPackage -AllUsers |
    Where-Object { $_.Name -eq $packageName }

if ($psaPackages) {
    Write-EventLog `
        -LogName $logName `
        -Source $eventSource `
        -EventID 2000 `
        -EntryType Information `
        -Message "Removing Xerox Print and Scan Experience."

    foreach ($pkg in $psaPackages) {
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers
    }

    Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -eq $packageName } |
        ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName
        }
}

# ============================================================
# Enable Windows Protected Print
# ============================================================

$printerPolicyPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Printers"

if (-not (Test-Path $printerPolicyPath)) {
    New-Item -Path $printerPolicyPath -Force | Out-Null
}

Set-ItemProperty `
    -Path $printerPolicyPath `
    -Name "ConfigureWindowsProtectedPrint" `
    -Type String `
    -Value "<enabled/>"

Write-EventLog `
    -LogName $logName `
    -Source $eventSource `
    -EventID 2001 `
    -EntryType Information `
    -Message "Protected Print enabled and Xerox PSA removed."

Write-Output "System remediation completed."
exit 0