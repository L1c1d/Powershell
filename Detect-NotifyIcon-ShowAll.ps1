# Detect if taskbar icons are set to always show or not.



$baseKey = 'HKCU:\Control Panel\NotifyIconSettings'
$prop    = 'IsPromoted'

if (-not (Test-Path $baseKey)) {
    Write-Host "No NotifyIconSettings key yet (likely first logon with no tray apps)."
    exit 0
}

$nonCompliant = Get-ChildItem -LiteralPath $baseKey |
    Where-Object {
        try {
            ($_.GetValue($prop) -ne 1)
        } catch {
            $true # Missing property counts as non-compliant
        }
    }

if ($nonCompliant) {
    $names = ($nonCompliant | Select-Object -ExpandProperty PSChildName) -join ', '
    Write-Host "Non-compliant entries (IsPromoted!=1): $names"
    exit 1
}

Write-Host "All tray icons are promoted."
exit 0