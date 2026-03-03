#  Top 25 subfolders under C:\Windows by size (in GB).
#  Top 40 largest files anywhere under C:\Windows (in GB).
#  Helpful for locating large files 
#  This can take a while to run so expect a delay
# It prints both sections to the console as formatted tables.


$ErrorActionPreference = 'SilentlyContinue'

function Get-FolderSizeGB {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    [math]::Round(($sum/1GB),2)
}

Write-Host "=== Top subfolders in C:\Windows (by size) ===" -ForegroundColor Cyan
Get-ChildItem -LiteralPath 'C:\Windows' -Directory -Force |
  ForEach-Object {
    [pscustomobject]@{
      Folder = $_.FullName
      GB     = Get-FolderSizeGB -Path $_.FullName
    }
  } | Sort-Object GB -Descending | Select-Object -First 25 | Format-Table -Auto

Write-Host "`n=== Largest files under C:\Windows (top 40) ===" -ForegroundColor Cyan
Get-ChildItem -LiteralPath 'C:\Windows' -Force -Recurse -File -ErrorAction SilentlyContinue |
  Sort-Object Length -Descending |
  Select-Object -First 40 FullName, @{n='GB';e={[math]::Round($_.Length/1GB,2)}} |

  Format-Table -Auto
