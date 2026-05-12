# AtomArcade — desktop shortcut installer (v0.5.1).
#
# Creates "AtomArcade Home Base.lnk" on the user's Desktop.
# The shortcut targets homebase-desktop.ps1 because that launcher starts the
# browser Automation Center server and opens http://localhost:8080/.
#
# Usage from the repo folder:
#   pwsh -File install-shortcut.ps1

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$Launcher = Join-Path $RepoRoot 'homebase-desktop.ps1'
$Browser  = Join-Path $RepoRoot 'homebase.ps1'

if (Test-Path $Launcher) {
    $Target = $Launcher
    Write-Host 'Target: homebase-desktop.ps1 (opens browser Automation Center)'
} elseif (Test-Path $Browser) {
    $Target = $Browser
    Write-Host 'Target: homebase.ps1 (server only fallback)'
} else {
    throw "Neither homebase-desktop.ps1 nor homebase.ps1 found in $RepoRoot. Did you 'git clone' first?"
}

# Find a PowerShell executable (prefer pwsh 7+)
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$Pwsh = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command powershell).Source }

$DesktopDir = [Environment]::GetFolderPath('Desktop')
if (-not (Test-Path $DesktopDir)) { $DesktopDir = Join-Path $env:USERPROFILE 'Desktop' }
$LnkPath = Join-Path $DesktopDir 'AtomArcade Home Base.lnk'

$Shell = New-Object -ComObject WScript.Shell
$Lnk   = $Shell.CreateShortcut($LnkPath)
$Lnk.TargetPath       = $Pwsh
$Lnk.Arguments        = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Target`""
$Lnk.WorkingDirectory = $RepoRoot
$Lnk.Description      = 'AtomArcade Home Base — Automation Center'
$Lnk.IconLocation     = "$env:SystemRoot\System32\imageres.dll,109"
$Lnk.WindowStyle      = 7
$Lnk.Save()

Write-Host ''
Write-Host "✓ Created: $LnkPath" -ForegroundColor Green
Write-Host "  Runs:    $Target" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Double-click the desktop icon to launch Home Base Automation Center.' -ForegroundColor Cyan
