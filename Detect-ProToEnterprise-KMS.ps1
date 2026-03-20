# Detect-ProToEnterprise-KMS.ps1
# Detects if device is on windows pro or enterprise. If pro, not complaint, needs remediation.
# Remediate with Remediate-ProToEnterprise-KMS.ps1
# Exit 0 = compliant, Exit 1 = needs remediation

$ErrorActionPreference = 'Stop'

function Write-Det {
    param([string]$m) 
    Write-Output $m
}

# Skip Windows Server SKUs (ProductType 1 = client)
try {
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -ne 1) {
        Write-Det "Non-client OS (likely server). Skipping as compliant."
        exit 0
    }
}
catch {
    Write-Det "Could not query OS type: $_"
    # If we can't tell, let remediation decide safely.
}

# Get Windows license view
$prod = Get-CimInstance -ClassName SoftwareLicensingProduct |
        Where-Object { $_.Name -like "Windows*" -and $_.PartialProductKey } |
        Select-Object -First 1

# Get edition
$ci = Get-ComputerInfo
$editionName = $ci.WindowsProductName
$editionId   = $ci.WindowsEditionId

# Compliance criteria:
#  - Edition must contain "Enterprise"
#  - Licensing must be "Licensed"
#  - ProductKeyChannel should be KMS (VOLUME_KMSCLIENT or VOLUME_KMS*)
$okEdition   = ($editionName -match "Enterprise")
$okLic       = $prod -and ($prod.LicenseStatus -eq 1)
$okChannel   = $prod -and ($prod.ProductKeyChannel -match '^VOLUME_KMS')

# Optional: confirm DNS KMS SRV record exists (if you rely on DNS)
# We’ll treat missing SRV as non-fatal; remediation can set /skms explicitly.
$kmsSrvOk = $false
try {
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    if ($domain) {
        $srv = Resolve-DnsName -Type SRV "_vlmcs._tcp.$domain" -ErrorAction SilentlyContinue
        $kmsSrvOk = $srv -ne $null
    }
} catch { }

$compliant = $okEdition -and $okLic -and $okChannel

$summary = [pscustomobject]@{
    EditionName  = $editionName
    EditionId    = $editionId
    License      = if ($prod) { $prod.LicenseStatus } else { $null }
    Channel      = if ($prod) { $prod.ProductKeyChannel } else { $null }
    DnsSrvFound  = $kmsSrvOk
    Compliant    = $compliant
}
$summary | ConvertTo-Json -Compress | Write-Output

if ($compliant) { exit 0 } else { exit 1 }
