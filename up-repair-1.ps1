# ============================================================
# Script A - USER CONTEXT
# Universal print has major issues where printing just stops working with little info or errors
# This is part one of a two part script
# Detects & removes Universal Print printers
# Run this script as the user
# Writes a flag for SYSTEM script
# ============================================================

$FlagRoot = "C:\ProgramData\Intune-UP"
$FlagFile = Join-Path $FlagRoot "UPPrintersRemoved.flag"

Write-Output "Checking for Universal Print printers (user context)..."

$upPrinters = Get-Printer | Where-Object {
    $_.DriverName -match 'Universal Print|MSIPP|Mopria' -or
    $_.PortName   -match '^IPP'
}

if (-not $upPrinters) {
    Write-Output "No Universal Print printers found. Exiting."
    exit 0
}

Write-Output "Universal Print printers detected. Removing..."

foreach ($printer in $upPrinters) {
    Write-Output "Removing printer: $($printer.Name)"
    try {
        Remove-Printer -Name $printer.Name -Confirm:$false
    }
    catch {
        Write-Warning "Failed to remove $($printer.Name): $($_.Exception.Message)"
    }
}

# ---- Ensure flag directory exists ----
if (-not (Test-Path $FlagRoot)) {
    New-Item -Path $FlagRoot -ItemType Directory -Force | Out-Null
}

# ---- Create flag ----
Set-Content `
    -Path $FlagFile `
    -Value "Universal Print printers removed on $(Get-Date -Format s)"

Write-Output "Flag written: $FlagFile"
exit 0