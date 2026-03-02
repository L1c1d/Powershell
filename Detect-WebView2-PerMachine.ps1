<#
  Detects if webview 2 is installed
  Exits 0 if WebView2 Runtime is installed per-machine with a valid version; otherwise 1.
#>

$ErrorActionPreference = 'SilentlyContinue'

# WebView2 Evergreen Runtime Client GUID per Microsoft docs
$Wv2Guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

# Per-machine detection key for 64-bit Windows
$RegPath_HKLM = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$Wv2Guid"

# Read the 'pv' (product version) string; it must exist and not be 0.0.0.0
$pv = (Get-ItemProperty -Path $RegPath_HKLM -ErrorAction SilentlyContinue).pv

# Treat empty/0.0.0.0 as not installed or corrupt, per Microsoft guidance
if ([string]::IsNullOrWhiteSpace($pv) -or $pv -eq '0.0.0.0') {
    Write-Output "WebView2 per-machine not detected or version invalid. pv='$pv'"
    exit 1
}

# (Optional) verify version parses correctly
try {
    [void][Version]$pv
    Write-Output "WebView2 per-machine detected. pv='$pv'"
    exit 0
}
catch {
    Write-Output "WebView2 per-machine version value not a valid semantic version. pv='$pv'"
    exit 1
}
