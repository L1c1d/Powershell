#  Installs Microsoft .NET Framework 3.5


$params = @{
    Online      = $true
    FeatureName = 'NetFx3'
    All         = $true
    NoRestart   = $true
}

Enable-WindowsOptionalFeature @params

Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart