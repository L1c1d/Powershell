# Detect whether Secure Boot DB and KEK contain 2023 certificates

function Test-Cert {
    param($Name)
    try {
        $data = (Get-SecureBootUEFI -Name $Name -ErrorAction Stop).bytes
        $text = [System.Text.Encoding]::ASCII.GetString($data)
        return ($text -match "2023")
    } catch {
        return $false
    }
}

$DBUpdated = Test-Cert -Name "db"
$KEKUpdated = Test-Cert -Name "kek"

if ($DBUpdated -and $KEKUpdated) {
    Write-Output "SecureBoot Certificates Updated"
    exit 0
} else {
    Write-Output "SecureBoot Certificates Not Updated"
    exit 1
}
