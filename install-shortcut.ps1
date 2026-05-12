# AtomArcade — desktop shortcut installer (v0.3).
#
# Creates "AtomArcade Home Base.lnk" on the user's Desktop. Targets the new
# Windows Forms app (homebase-desktop.ps1) if present, otherwise falls back to
# the older console+browser version (homebase.ps1).
#
# Usage (run once from the repo folder):
#   pwsh -File install-shortcut.ps1
# Re-run after `git pull` if file paths changed.

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$Desktop  = Join-Path $RepoRoot 'homebase-desktop.ps1'
$Legacy   = Join-Path $RepoRoot 'homebase.ps1'

if (Test-Path $Desktop) {
    $Target = $Desktop
    Write-Host 'Target: homebase-desktop.ps1 (Windows Forms app)'
} elseif (Test-Path $Legacy) {
    $Target = $Legacy
    Write-Host 'Target: homebase.ps1 (console + browser dashboard)'
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
$Lnk.Arguments        = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Target`""
$Lnk.WorkingDirectory = $RepoRoot
$Lnk.Description      = 'AtomArcade Home Base'
$Lnk.IconLocation     = "$env:SystemRoot\System32\imageres.dll,109"
$Lnk.WindowStyle      = 7   # Minimized (the script hides its own console)
$Lnk.Save()

Write-Host ''
Write-Host "✓ Created: $LnkPath" -ForegroundColor Green
Write-Host "  Runs:    $Target" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Double-click the desktop icon to launch.' -ForegroundColor Cyan
