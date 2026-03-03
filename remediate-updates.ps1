<# Check and install Windows Updates (software only)
   Trigger reboot after 5 min.
   Run as Administrator or SYSTEM (Intune/SCCM)
#>

# Create update session
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()

Write-Output "Starting Windows Update scan..."
$searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
Write-Output ("Found {0} applicable updates." -f $searchResult.Updates.Count)

if ($searchResult.Updates.Count -eq 0) {
    Write-Output "No updates found."
    exit 0
}

# Accept EULAs and prepare updates
$toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($update in $searchResult.Updates) {
    if (-not $update.EulaAccepted) { $update.AcceptEula() }
    if (-not $update.IsDownloaded) { [void]$toDownload.Add($update) }
}

# Download updates
if ($toDownload.Count -gt 0) {
    Write-Output "Downloading updates..."
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $toDownload
    $downloadResult = $downloader.Download()
    Write-Output ("Download result: {0}" -f $downloadResult.ResultCode)
}

# Install updates
$toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($update in $searchResult.Updates) {
    if ($update.IsDownloaded) { [void]$toInstall.Add($update) }
}

if ($toInstall.Count -gt 0) {
    Write-Output "Installing updates..."
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $toInstall
    $installResult = $installer.Install()
    Write-Output ("Install result: {0}" -f $installResult.ResultCode)
    if ($installResult.RebootRequired) {
        Write-Output "Reboot required to complete installation."
    }
} else {
    Write-Output "No updates ready to install."
}

if ($installResult.RebootRequired) {
shutdown.exe /r /t 300 /c "Windows updates installed. Restarting in 5 minutes." /f
}
