<#
.SYNOPSIS
Collects WLAN AutoConfig Operational logs (EVTX, optional CSV), summary, and optional WLAN HTML report.
Supports local and remote collection.

.EXAMPLE
.\Collect-WlanAutoConfigLogs.ps1 -SinceHours 24 -OutputRoot "C:\Temp\WiFiLogs" -Zip

.EXAMPLE
.\Collect-WlanAutoConfigLogs.ps1 -ComputerName PC01,PC02 -SinceHours 72 -IncludeWlanReport -Zip
#>

[CmdletBinding()]
param(
    # Local or remote computers. Default is the local machine.
    [string[]] $ComputerName = $env:COMPUTERNAME,

    # Credentials for remote access (WinRM/PowerShell Remoting must be allowed).
    [pscredential] $Credential,

    # How far back to collect events (mutually exclusive with -Since).
    [int] $SinceHours = 24,

    # Or specify an explicit start time (UTC or local accepted).
    [datetime] $Since,

    # Root folder to place outputs (each machine gets its own subfolder).
    [string] $OutputRoot = "C:\Temp",

    # Include CSV export of events (in addition to EVTX).
    [switch] $IncludeCsv,

    # Include Windows native WLAN HTML report (netsh wlan show wlanreport).
    [switch] $IncludeWlanReport,

    # Compress results per machine to a ZIP.
    [switch] $Zip
)

begin {
    $ErrorActionPreference = 'Stop'
    $logName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'

    if (-not $Since) {
        $Since = (Get-Date).AddHours(-[math]::Abs($SinceHours))
    }

    # Build a filter hash for Get-WinEvent
    $filterHashtable = @{
        LogName   = $logName
        StartTime = $Since
    }

    function Invoke-Remote {
        param(
            [string] $Computer,
            [scriptblock] $Script,
            [pscredential] $Cred
        )
        if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq 'localhost' -or $Computer -eq '.') {
            & $Script
        } else {
            if ($Cred) {
                Invoke-Command -ComputerName $Computer -Credential $Cred -ScriptBlock $Script
            } else {
                Invoke-Command -ComputerName $Computer -ScriptBlock $Script
            }
        }
    }

    function Ensure-Directory {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

process {
    foreach ($computer in $ComputerName) {
        Write-Host "=== Collecting from $computer (since $Since) ===" -ForegroundColor Cyan

        # Per-computer output folder with timestamp
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $outDir = Join-Path $OutputRoot "$($computer)_WiFi_$timestamp"
        Ensure-Directory $outDir

        # Build filenames
        $evtxPath   = Join-Path $outDir "WLAN-AutoConfig_Operational.evtx"
        $csvPath    = Join-Path $outDir "WLAN-AutoConfig_Operational.csv"
        $summaryTxt = Join-Path $outDir "Summary.txt"
        $wlanReportFolder = Join-Path $env:ProgramData "Microsoft\Windows\WlanReport"
        $wlanReportCopy   = Join-Path $outDir "WlanReport"

        # ScriptBlock executed locally or remotely
        $scriptBlock = {
            param($logName, $since, $needCsv, $csvPathRemote, $wlanReport, $wlanReportFolderRemote)

            $result = [ordered]@{
                Success           = $false
                Message           = ''
                EvtxTempPath      = ''
                CsvTempPath       = ''
                WlanReportFolder  = ''
            }

            try {
                # Confirm the log exists
                $logInfo = wevtutil el | Where-Object { $_ -eq $logName }
                if (-not $logInfo) {
                    throw "Log '$logName' not found on $env:COMPUTERNAME"
                }

                # Export the raw EVTX with a time filter using XPath (wevtutil epl doesn't directly time-filter reliably; fallback to full export)
                # Safer approach: Export entire EVTX and let analyst filter later.
                $tempEvtx = Join-Path $env:TEMP "WLAN_AutoConfig_Operational_$([guid]::NewGuid()).evtx"
                wevtutil epl $logName $tempEvtx
                if (-not (Test-Path $tempEvtx)) { throw "Failed to export EVTX with wevtutil." }
                $result.EvtxTempPath = $tempEvtx

                if ($needCsv) {
                    $filter = @{
                        LogName   = $logName
                        StartTime = $since
                    }
                    $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop

                    # Flatten common fields + some useful properties
                    $rows = foreach ($e in $events) {
                        # Extract useful properties safely
                        $props = @{}
                        try {
                            # Many WLAN events use properties like SSID, BSSID, ReasonCode, InterfaceName, etc.
                            # We'll capture what we commonly see, but keep it flexible.
                            $xml = [xml]$e.ToXml()
                            $dataNodes = $xml.Event.EventData.Data
                            foreach ($d in $dataNodes) {
                                if ($d.Name) {
                                    $name = [string]$d.Name
                                    if (-not $props.ContainsKey($name)) { $props[$name] = [string]$d.'#text' }
                                }
                            }
                        } catch { }

                        [pscustomobject]@{
                            TimeCreated     = $e.TimeCreated
                            Id              = $e.Id
                            LevelDisplayName= $e.LevelDisplayName
                            ProviderName    = $e.ProviderName
                            MachineName     = $e.MachineName
                            Message         = $e.Message
                            # Selected extracted fields (may be empty if not present)
                            SSID            = $props['SSID']
                            BSSID           = $props['BSSID']
                            InterfaceName   = $props['InterfaceName']
                            ReasonCode      = $props['ReasonCode']
                            FailureReason   = $props['FailureReason']
                            PHYType         = $props['PHYType']
                            Authentication  = $props['Authentication']
                            Cipher          = $props['Cipher']
                        }
                    }

                    if ($rows) {
                        $tempCsv = Join-Path $env:TEMP "WLAN_AutoConfig_Operational_$([guid]::NewGuid()).csv"
                        $rows | Sort-Object TimeCreated | Export-Csv -Path $tempCsv -NoTypeInformation -Encoding UTF8
                        $result.CsvTempPath = $tempCsv
                    }
                }

                if ($wlanReport) {
                    try {
                        # This generates %ProgramData%\Microsoft\Windows\WlanReport\wlan-report-latest.html and assets
                        netsh wlan show wlanreport | Out-Null
                        if (Test-Path $wlanReportFolderRemote) {
                            $result.WlanReportFolder = $wlanReportFolderRemote
                        }
                    } catch {
                        # Non-fatal
                    }
                }

                $result.Success = $true
                $result.Message = "OK"
            }
            catch {
                $result.Success = $false
                $result.Message = $_.Exception.Message
            }
            $result
        }

        # Invoke and collect artifacts
        $res = Invoke-Remote -Computer $computer -Credential $Credential -Script $scriptBlock -ArgumentList $logName, $Since, $IncludeCsv.IsPresent, $csvPath, $IncludeWlanReport.IsPresent, $wlanReportFolder

        if (-not $res.Success) {
            Write-Warning "[$computer] Failed: $($res.Message)"
            continue
        }

        # Copy EVTX from remote/local temp to our outDir
        try {
            if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.') {
                Copy-Item -LiteralPath $res.EvtxTempPath -Destination $evtxPath -Force
                Remove-Item -LiteralPath $res.EvtxTempPath -Force -ErrorAction SilentlyContinue
            } else {
                $session = if ($Credential) {
                    New-PSSession -ComputerName $computer -Credential $Credential
                } else {
                    New-PSSession -ComputerName $computer
                }
                Copy-Item -FromSession $session -LiteralPath $res.EvtxTempPath -Destination $evtxPath -Force
                Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } -ArgumentList $res.EvtxTempPath
                Remove-PSSession $session
            }
        } catch {
            Write-Warning "[$computer] Could not retrieve EVTX: $($_.Exception.Message)"
        }

        # Copy CSV if requested
        if ($IncludeCsv -and $res.CsvTempPath) {
            try {
                if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.') {
                    Copy-Item -LiteralPath $res.CsvTempPath -Destination $csvPath -Force
                    Remove-Item -LiteralPath $res.CsvTempPath -Force -ErrorAction SilentlyContinue
                } else {
                    $session = if ($Credential) {
                        New-PSSession -ComputerName $computer -Credential $Credential
                    } else {
                        New-PSSession -ComputerName $computer
                    }
                    Copy-Item -FromSession $session -LiteralPath $res.CsvTempPath -Destination $csvPath -Force
                    Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } -ArgumentList $res.CsvTempPath
                    Remove-PSSession $session
                }
            } catch {
                Write-Warning "[$computer] Could not retrieve CSV: $($_.Exception.Message)"
            }
        }

        # Copy WLAN report (folder with HTML + assets)
        if ($IncludeWlanReport -and $res.WlanReportFolder) {
            try {
                if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.') {
                    Copy-Item -Path $res.WlanReportFolder -Destination $wlanReportCopy -Recurse -Force
                } else {
                    $session = if ($Credential) {
                        New-PSSession -ComputerName $computer -Credential $Credential
                    } else {
                        New-PSSession -ComputerName $computer
                    }
                    # Create destination
                    New-Item -ItemType Directory -Path $wlanReportCopy -Force | Out-Null
                    # Copy all contents of remote report folder
                    $remoteItems = Invoke-Command -Session $session -ScriptBlock { param($p) Get-ChildItem -Path $p -Recurse -File | Select-Object -ExpandProperty FullName } -ArgumentList $res.WlanReportFolder
                    foreach ($ri in $remoteItems) {
                        $relative = $ri.Substring($res.WlanReportFolder.Length).TrimStart('\')
                        $dest = Join-Path $wlanReportCopy $relative
                        Ensure-Directory (Split-Path $dest -Parent)
                        Copy-Item -FromSession $session -LiteralPath $ri -Destination $dest -Force
                    }
                    Remove-PSSession $session
                }
            } catch {
                Write-Warning "[$computer] Could not retrieve WLAN report: $($_.Exception.Message)"
            }
        }

        # Build a quick summary from EVTX (and CSV if present)
        try {
            $summaryLines = New-Object System.Collections.Generic.List[string]
            $summaryLines.Add("Computer: $computer")
            $summaryLines.Add("Collected: $(Get-Date)")
            $summaryLines.Add("Log: $logName")
            $summaryLines.Add("Since: $Since")
            $summaryLines.Add("EVTX: $evtxPath")
            if (Test-Path $csvPath) { $summaryLines.Add("CSV:  $csvPath") }
            if (Test-Path $wlanReportCopy) { $summaryLines.Add("WLAN report folder: $wlanReportCopy") }
            $summaryLines.Add("")

            # Use Get-WinEvent to summarize directly from the computer (faster and avoids re-reading EVTX)
            $summBlock = {
                param($logName, $since)
                $filter = @{ LogName = $logName; StartTime = $since }
                $evts = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue
                if (-not $evts) { return $null }

                $counts = $evts | Group-Object Id | Sort-Object Count -Descending |
                    Select-Object @{n='EventId';e={$_.Name}}, Count

                # Extract common properties for top reasons
                $rows = foreach ($e in $evts) {
                    $xml = $null
                    try { $xml = [xml]$e.ToXml() } catch { }
                    $props = @{}
                    if ($xml) {
                        foreach ($d in $xml.Event.EventData.Data) {
                            if ($d.Name) { $props[$d.Name] = [string]$d.'#text' }
                        }
                    }
                    [pscustomobject]@{
                        Id            = $e.Id
                        TimeCreated   = $e.TimeCreated
                        InterfaceName = $props['InterfaceName']
                        SSID          = $props['SSID']
                        ReasonCode    = $props['ReasonCode']
                        FailureReason = $props['FailureReason']
                    }
                }

                $topReasons = $rows | Where-Object { $_.FailureReason -or $_.ReasonCode } |
                    Group-Object FailureReason |
                    Where-Object { $_.Name } |
                    Sort-Object Count -Descending |
                    Select-Object -First 10

                $byIface = $rows | Group-Object InterfaceName | Sort-Object Count -Descending

                [pscustomobject]@{
                    CountTotal = ($evts | Measure-Object).Count
                    CountsByEventId = $counts
                    TopReasons = $topReasons
                    ByInterface = $byIface
                }
            }

            $summaryData = Invoke-Remote -Computer $computer -Credential $Credential -Script $summBlock -ArgumentList $logName, $Since
            if ($summaryData) {
                $summaryLines.Add("Total events: " + $summaryData.CountTotal)
                $summaryLines.Add("")
                $summaryLines.Add("Counts by Event ID:")
                foreach ($c in $summaryData.CountsByEventId) {
                    $summaryLines.Add(("  ID {0,-5}  {1,6}" -f $c.EventId, $c.Count))
                }
                $summaryLines.Add("")
                if ($summaryData.TopReasons -and $summaryData.TopReasons.Count -gt 0) {
                    $summaryLines.Add("Top Failure Reasons:")
                    foreach ($r in $summaryData.TopReasons) {
                        $summaryLines.Add(("  {0}  ({1})" -f $r.Name, $r.Count))
                    }
                    $summaryLines.Add("")
                }
                if ($summaryData.ByInterface -and $summaryData.ByInterface.Count -gt 0) {
                    $summaryLines.Add("Events by Interface:")
                    foreach ($g in $summaryData.ByInterface) {
                        $name = if ($g.Name) { $g.Name } else { '(unknown)' }
                        $summaryLines.Add(("  {0}  ({1})" -f $name, $g.Count))
                    }
                }
            } else {
                $summaryLines.Add("No events found since $Since.")
            }

            $summaryLines | Set-Content -Path $summaryTxt -Encoding UTF8
        } catch {
            Write-Warning "[$computer] Failed to write summary: $($_.Exception.Message)"
        }

        # Zip if requested
        if ($Zip) {
            try {
                $zipPath = "$outDir.zip"
                if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
                Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath -Force
                Write-Host "[$computer] Results zipped to $zipPath"
            } catch {
                Write-Warning "[$computer] Failed to zip: $($_.Exception.Message)"
            }
        }

        Write-Host "[$computer] Done. Output: $outDir" -ForegroundColor Green
    }
}

end { }