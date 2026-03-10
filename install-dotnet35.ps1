# Install .NET 3.5 using PS
# Uses Windows built-in optional features to grab the install
# Logs output to C:\temp\dotnet35.logs

# Ensure log directory exists
$LogPath = 'C:\Temp\dotnet35.log'
$null = New-Item -Path (Split-Path $LogPath) -ItemType Directory -Force -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format s), $Level, $Message
    $line | Tee-Object -FilePath $LogPath -Append | Out-Host
}

# Parameters for enabling NetFx3
$params = @{
    Online      = $true
    FeatureName = 'NetFx3'
    All         = $true
    NoRestart   = $true
}

# Detection: check if already installed
try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
} catch {
    Write-Log ("Failed to query Windows optional feature NetFx3: {0}" -f $_.Exception.Message) 'ERROR'
    exit 2
}

Write-Log ("Detected NetFx3 current state: {0}" -f $feature.State)

if ($feature.State -eq 'Enabled') {
    Write-Log ".NET 3.5 is already installed; no action needed."
    exit 0
}

# --- Not enabled: attempt installation ---
Write-Log "Starting .NET 3.5 enablement via Enable-WindowsOptionalFeature..."

$exitCode = 0
try {
    Enable-WindowsOptionalFeature @params -Verbose *>&1 | Tee-Object -FilePath $LogPath -Append
}
catch {
    Write-Log ("Exception during Enable-WindowsOptionalFeature: {0}" -f $_.Exception.Message) 'ERROR'
    $exitCode = 2
}

# Re-check state
try {
    $post = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
    Write-Log ("Feature state after run: {0}" -f $post.State)
} catch {
    Write-Log ("Failed to re-query NetFx3 after install attempt: {0}" -f $_.Exception.Message) 'ERROR'
    if ($exitCode -eq 0) { $exitCode = 2 }
}

if ($exitCode -eq 0) {
    if ($post.State -in 'Enabled','Enable Pending') {
        Write-Log ".NET 3.5 installation succeeded (state: $($post.State))."
        exit 0
    } else {
        Write-Log ".NET 3.5 installation did not complete successfully (state: $($post.State))." 'WARN'
        exit 1
    }
} else {
    exit $exitCode
}