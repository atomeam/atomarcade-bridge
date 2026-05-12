# Creates Desktop + Start Menu shortcuts for AtomArcade Home Base.
# The shortcut launches homebase-launcher.ps1 hidden via pwsh, so clicking the icon
# starts the bridge (if needed) and opens Home Base in an Edge app window.
# Idempotent: running again just overwrites the shortcut.

$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
if (-not $repo) { $repo = Split-Path -Parent $MyInvocation.MyCommand.Path }
$launcher = Join-Path $repo 'homebase-launcher.ps1'

if (-not (Test-Path $launcher)) {
  Write-Error "Launcher not found at $launcher. Run 'git pull --ff-only origin main' in $repo first."
  exit 1
}

$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
if (-not (Test-Path $pwshPath)) {
  Write-Error "PowerShell 7 (pwsh.exe) not found. Install PowerShell 7 or edit this script's `$pwshPath."
  exit 1
}

# Edge icon for a nice native-app look (falls back silently if not present)
$edgeIconCandidates = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
)
$edgeIcon = $edgeIconCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

$wshell  = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$start   = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'

foreach ($dir in @($desktop, $start)) {
  if (-not (Test-Path $dir)) { continue }
  $lnk = Join-Path $dir 'AtomArcade Home Base.lnk'
  $s   = $wshell.CreateShortcut($lnk)
  $s.TargetPath       = $pwshPath
  $s.Arguments        = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
  $s.WorkingDirectory = $repo
  if ($edgeIcon) { $s.IconLocation = "$edgeIcon,0" }
  $s.WindowStyle      = 7   # minimized — but pwsh is hidden anyway
  $s.Description      = 'AtomArcade Home Base — Automation Center cockpit'
  $s.Save()
  Write-Host "Created shortcut: $lnk"
}

Write-Host ''
Write-Host 'Done. Click the AtomArcade Home Base icon on your Desktop or in the Start menu.'
Write-Host 'It will start the bridge if needed, then open Home Base in its own window.'
