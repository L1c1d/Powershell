# Lists installed Credential Providers (CLSID and friendly name) on the device


$cpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers'
Get-ChildItem $cpKey | ForEach-Object {
    [PSCustomObject]@{
        CLSID = $_.PSChildName
        Name  = (Get-ItemProperty $_.PSPath).'(default)'
    }
} | Sort-Object Name | Format-Table -Auto