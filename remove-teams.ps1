# Uninstall Microsoft Teams for all users


Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name = 'Microsoft Teams'" | ForEach-Object {
    $_.Uninstall()
}

# Remove Teams folders for all users
$users = Get-WmiObject -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }
foreach ($user in $users) {
    $userProfile = $user.LocalPath
    Remove-Item -Path "$userProfile\AppData\Local\Microsoft\Teams" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$userProfile\AppData\Roaming\Microsoft\Teams" -Recurse -Force -ErrorAction SilentlyContinue
}

# Remove Teams registry entries
Remove-Item -Path "HKCU:\Software\Microsoft\Office\Teams" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Microsoft\Office\16.0\Teams" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Microsoft\Teams" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\Software\Microsoft\Office\Teams" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\Software\Microsoft\Office\16.0\Teams" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\Software\Microsoft\Teams" -Recurse -Force -ErrorAction SilentlyContinue

# Remove Teams machine-wide installer
Remove-Item -Path "C:\Program Files (x86)\Teams Installer" -Recurse -Force -ErrorAction SilentlyContinue