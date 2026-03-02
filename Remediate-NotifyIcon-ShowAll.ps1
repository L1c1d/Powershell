# Remediate taskbar icons to always show.


$baseKey = 'HKCU:\Control Panel\NotifyIconSettings'
$prop    = 'IsPromoted'

if (Test-Path $baseKey) {
    Get-ChildItem -LiteralPath $baseKey | ForEach-Object {
        try {
            New-ItemProperty -LiteralPath $_.PSPath -Name $prop -PropertyType DWord -Value 1 -Force | Out-Null
        } catch {
            Write-Warning "Failed to set IsPromoted for $($_.PSChildName): $_"
        }
    }
}

# OPTIONAL: apply immediately by restarting Explorer.
# Uncomment if you want instant effect instead of waiting for next sign-in.

# $explorer = Get-Process explorer -ErrorAction SilentlyContinue
# if ($explorer) { Stop-Process -Id $explorer.Id -Force }
