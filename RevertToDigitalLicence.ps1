<#
.SYNOPSIS
    Reverts Windows activation to the OEM digital license stored in firmware.

.DESCRIPTION
    - Clears the current product key.
    - Retrieves the OEM key from the BIOS/UEFI.
    - Installs the OEM key.
    - Attempts online activation.

.NOTES
    Run as Administrator.
#>

Write-Host "Starting Windows activation revert process..." -ForegroundColor Cyan

# Step 1: Remove current product key
Write-Host "Removing current product key..." -ForegroundColor Yellow
try {
    slmgr.vbs /upk
    slmgr.vbs /cpky
    Write-Host "Current product key removed." -ForegroundColor Green
} catch {
    Write-Host "Failed to remove product key: $_" -ForegroundColor Red
}

# Step 2: Get OEM key from firmware
Write-Host "Retrieving OEM key from firmware..." -ForegroundColor Yellow
$oemKey = (Get-WmiObject -Query "SELECT OA3xOriginalProductKey FROM SoftwareLicensingService").OA3xOriginalProductKey

if ([string]::IsNullOrWhiteSpace($oemKey)) {
    Write-Host "No OEM key found in firmware. Cannot proceed." -ForegroundColor Red
    exit 1
}

Write-Host "OEM key found: $oemKey" -ForegroundColor Green

# Step 3: Install OEM key
Write-Host "Installing OEM key..." -ForegroundColor Yellow
try {
    slmgr.vbs /ipk $oemKey
    Write-Host "OEM key installed successfully." -ForegroundColor Green
} catch {
    Write-Host "Failed to install OEM key: $_" -ForegroundColor Red
    exit 1
}

# Step 4: Attempt activation
Write-Host "Activating Windows online..." -ForegroundColor Yellow
try {
    slmgr.vbs /ato
    Write-Host "Activation attempt completed." -ForegroundColor Green
} catch {
    Write-Host "Activation failed: $_" -ForegroundColor Red
}

Write-Host "Process finished." -ForegroundColor Cyan
