#Requires -Version 5.0
# Homebase Button installer
# Usage:
#   iex (irm https://raw.githubusercontent.com/atomeam/atomarcade-bridge/homebase-button/apps/homebase-button/install.ps1)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$AppName    = 'Homebase'
$InstallDir = Join-Path $env:LOCALAPPDATA 'HomebaseButton'
$RepoRaw    = 'https://raw.githubusercontent.com/atomeam/atomarcade-bridge/homebase-button/apps/homebase-button'

Write-Host "Installing $AppName to $InstallDir ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Download the app script from the repo
$AppPath = Join-Path $InstallDir 'HomebaseButton.ps1'
Invoke-WebRequest -Uri "$RepoRaw/HomebaseButton.ps1" -OutFile $AppPath -UseBasicParsing

# Write a hidden-window launcher (.cmd)
$LauncherPath  = Join-Path $InstallDir 'HomebaseButton.cmd'
$LauncherLines = @(
    '@echo off',
    'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0HomebaseButton.ps1"'
)
Set-Content -Path $LauncherPath -Value $LauncherLines -Encoding ASCII

# Create Desktop + Start Menu shortcuts
$WshShell = New-Object -ComObject WScript.Shell

$DesktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
$sc1 = $WshShell.CreateShortcut($DesktopLink)
$sc1.TargetPath       = $LauncherPath
$sc1.WorkingDirectory = $InstallDir
$sc1.IconLocation     = 'shell32.dll,77'
$sc1.Description      = 'Homebase (button-only)'
$sc1.Save()

$StartMenuDir  = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
$StartMenuLink = Join-Path $StartMenuDir "$AppName.lnk"
$sc2 = $WshShell.CreateShortcut($StartMenuLink)
$sc2.TargetPath       = $LauncherPath
$sc2.WorkingDirectory = $InstallDir
$sc2.IconLocation     = 'shell32.dll,77'
$sc2.Description      = 'Homebase (button-only)'
$sc2.Save()

Write-Host ""
Write-Host "Homebase installed." -ForegroundColor Green
Write-Host "  Install dir:   $InstallDir"
Write-Host "  Desktop:       $DesktopLink"
Write-Host "  Start Menu:    $StartMenuLink"
Write-Host ""
Write-Host "Run via Desktop, Start Menu, or directly:"
Write-Host "  $LauncherPath"
