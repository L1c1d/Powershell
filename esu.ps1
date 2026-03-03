#  Windows 10 ESU MAK Key install
#  Provides an additional year of security updates
#  Replace $ESUMak with your mak
#  Replace $ESUAppId with your appid

# Ensure the script is running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

$Slmgr = "$env:SystemRoot\System32\slmgr.vbs"   # 64-bit slmgr
$ESUMak = 'ABCDEF-GHIJKL-MNOPQ-RSTVU-WXYZ'
$ESUAppId = '12345678-1234-1234-1234-123456789012'

# Install product key
cscript.exe //NoLogo $Slmgr /ipk $ESUMak
if ($LASTEXITCODE -ne 0) { Write-Warning "slmgr /ipk returned exit code $LASTEXITCODE." }

# Wait 10 seconds
Start-Sleep -Seconds 10

# Activate with ESU AppID
cscript.exe //NoLogo $Slmgr /ato $ESUAppId
