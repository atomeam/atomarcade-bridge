# install-edge-app.ps1
# Canonical fix for the desktop-launcher bug (Copilot, v0.6.2 chorus pass).
# Creates a desktop shortcut that opens Home Base in Edge --app mode
# so it feels like a native window (no tabs, no address bar).
#
# Run once after bridge install:
#   pwsh -File C:\AtomArcade\install-edge-app.ps1
#
# After this, you can also right-click the Home Base tab in Edge once it's
# open and choose "Apps -> Install Home Base..." to pin it via PWA install,
# which uses /manifest.webmanifest served by homebase.ps1 (v0.6.2+).

param(
    [string]$Url     = 'http://localhost:8080/',
    [string]$AppName = 'AtomArcade Home Base'
)

$ErrorActionPreference = 'Stop'

$edgeCandidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
)
$edgePath = $edgeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edgePath) {
    Write-Error 'Microsoft Edge not found. Install Edge or run homebase.ps1 directly in a browser.'
    exit 1
}

$desktop      = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop "$AppName.lnk"

$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath       = $edgePath
$sc.Arguments        = "--app=$Url"
$sc.WorkingDirectory = Split-Path $edgePath -Parent
$sc.IconLocation     = "$edgePath,0"
$sc.Description      = 'AtomArcade Home Base — opens in app window'
$sc.Save()

Write-Host "Created desktop shortcut: $shortcutPath"
Write-Host "Target: $edgePath --app=$Url"
Write-Host ''
Write-Host 'Next: double-click the shortcut after the bridge is running.'
Write-Host 'For an even more native feel, in Edge -> ... -> Apps -> Install this site as an app.'
