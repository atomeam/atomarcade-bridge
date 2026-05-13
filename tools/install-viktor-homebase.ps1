# Bootstrap Notion -> HomeBase -> Viktor command target and cockpit UI.
# Run from repo root:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\install-viktor-homebase.ps1

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnsureCommand = Join-Path $PSScriptRoot 'ensure-viktor-command.ps1'
$EnsureUi = Join-Path $PSScriptRoot 'ensure-viktor-ui.ps1'

if (-not (Test-Path $EnsureCommand)) { throw "Missing $EnsureCommand" }
if (-not (Test-Path $EnsureUi)) { throw "Missing $EnsureUi" }

Write-Host '[viktor-homebase] Creating Viktor folders...'
New-Item -ItemType Directory -Force -Path `
  (Join-Path $RepoRoot 'viktor'),`
  (Join-Path $RepoRoot 'viktor\scripts'),`
  (Join-Path $RepoRoot 'viktor\queue'),`
  (Join-Path $RepoRoot 'viktor\worker'),`
  (Join-Path $RepoRoot 'viktor\chatlogs'),`
  (Join-Path $RepoRoot 'handlers') | Out-Null

Write-Host '[viktor-homebase] Installing Python package if available/needed...'
try {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    if ($py) {
        & $py.Source -m pip install viktor 2>&1 | Write-Host
    } else {
        Write-Host '[viktor-homebase] python/py not found; skipping pip install.'
    }
} catch {
    Write-Host "[viktor-homebase] pip install viktor skipped/failed: $($_.Exception.Message)"
}

Write-Host '[viktor-homebase] Applying HomeBase viktor.run patch...'
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $EnsureCommand

Write-Host '[viktor-homebase] Applying VIKTOR cockpit UI/proxy patch...'
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $EnsureUi

Write-Host '[viktor-homebase] Done.'
Write-Host 'After restarting HomeBase, you should see a VIKTOR panel in the bridge cockpit.'
Write-Host 'Queue this in Bridge Commands:'
Write-Host '  Command: viktor.run'
Write-Host '  Kind: viktor'
Write-Host '  Risk: low'
Write-Host '  Args: {"script":"viktor/scripts/test.py","args":["--hello","homebase"],"mode":"python","timeout_sec":60}'
