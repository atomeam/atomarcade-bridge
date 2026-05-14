#Requires -Version 5.0
# Homebase installer — launches the Homebase web app (atomeam/HomeBase-)
# Usage:
#   iex (irm https://raw.githubusercontent.com/atomeam/atomarcade-bridge/homebase-button/apps/homebase-button/install.ps1)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$AppName = 'Homebase'
$AppUrl  = 'https://ais-dev-67uj6cve22lq7ja6prfk25-310117696491.us-west1.run.app'

Write-Host "Installing $AppName Desktop launcher..." -ForegroundColor Cyan

function New-UrlShortcut {
    param([string]$Path, [string]$Url)
    @"
[InternetShortcut]
URL=$Url
IconIndex=0
"@ | Set-Content -Path $Path -Encoding ASCII -Force
}

# Clean up legacy .lnk shortcuts from the previous PowerShell WinForms version
$Desktop     = [Environment]::GetFolderPath('Desktop')
$StartMenu   = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
$LegacyPaths = @(
    (Join-Path $Desktop   "$AppName.lnk"),
    (Join-Path $StartMenu "$AppName.lnk")
)
foreach ($p in $LegacyPaths) {
    if (Test-Path $p) {
        Remove-Item $p -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed legacy shortcut: $p"
    }
}

# Create new Internet Shortcuts pointing at the live web app
$DesktopUrl   = Join-Path $Desktop   "$AppName.url"
$StartMenuUrl = Join-Path $StartMenu "$AppName.url"
New-UrlShortcut -Path $DesktopUrl   -Url $AppUrl
New-UrlShortcut -Path $StartMenuUrl -Url $AppUrl

Write-Host ""
Write-Host "$AppName installed." -ForegroundColor Green
Write-Host "  Desktop:    $DesktopUrl"
Write-Host "  Start Menu: $StartMenuUrl"
Write-Host "  Target URL: $AppUrl"
Write-Host ""
Write-Host "Double-click '$AppName' on the Desktop to launch."
