# Detects if TPM is Present/Enabled/Activated

$ErrorActionPreference = 'SilentlyContinue'
$tpm = Get-Tpm
if (-not $tpm) { exit 1 }
if (-not $tpm.TpmPresent) { exit 1 }
if (-not $tpm.TpmEnabled) { exit 1 }
if (-not $tpm.TpmActivated) { exit 1 }
if (-not $tpm.ManufacturerVersionFull20) { exit 1 }
Write-Host "TPM Present/Enabled/Activated with TPM2.0 indicators"
exit 0
