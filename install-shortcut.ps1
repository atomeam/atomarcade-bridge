# AtomArcade — one-time desktop shortcut installer.
#
# Usage (run once from the repo folder):
#   pwsh -File install-shortcut.ps1
#
# Creates "AtomArcade Home Base.lnk" on the current user's Desktop. Double-clicking
# it launches Home Base (if not already running) and opens http://localhost:8080/.
#
# Re-run any time to refresh the shortcut (e.g. after moving the repo folder).

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$Launcher = Join-Path $RepoRoot 'launch-homebase.ps1'
$Homebase = Join-Path $RepoRoot 'homebase.ps1'

if (-not (Test-Path $Launcher)) { throw "Missing launcher: $Launcher" }
if (-not (Test-Path $Homebase)) { throw "Missing homebase.ps1: $Homebase" }

# Find PowerShell (prefer pwsh 7+)
$Pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $Pwsh) { $Pwsh = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
if (-not $Pwsh) { throw 'No PowerShell executable found (pwsh or powershell).' }

$Desktop = [Environment]::GetFolderPath('Desktop')
$LnkPath = Join-Path $Desktop 'AtomArcade Home Base.lnk'

$Shell = New-Object -ComObject WScript.Shell
$Lnk   = $Shell.CreateShortcut($LnkPath)
$Lnk.TargetPath       = $Pwsh
$Lnk.Arguments        = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
$Lnk.WorkingDirectory = $RepoRoot
$Lnk.Description      = 'Launch AtomArcade Home Base and open the dashboard'
# Windows 10/11 "game controller" icon. Change index if you want a different glyph.
$Lnk.IconLocation     = "$env:SystemRoot\System32\imageres.dll,109"
$Lnk.WindowStyle      = 7   # Minimized
$Lnk.Save()

Write-Host ""
Write-Host "✓ Created: $LnkPath" -ForegroundColor Green
Write-Host "  Target:  $Pwsh" -ForegroundColor DarkGray
Write-Host "  Runs:    $Launcher" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Double-click the new icon any time to start Home Base + open http://localhost:8080/." -ForegroundColor Cyan
Write-Host "To change the icon, edit \$Lnk.IconLocation in this script and re-run." -ForegroundColor DarkGray
