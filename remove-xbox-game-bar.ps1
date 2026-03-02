#  Removes xbox game bar

Get-AppxPackage -Name Microsoft.XboxGamingOverlay | Remove-AppxPackage -ErrorAction SilentlyContinue