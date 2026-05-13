# Bootstrap Notion -> HomeBase -> Viktor command target.
# Run from repo root:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\install-viktor-homebase.ps1

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Ensure = Join-Path $PSScriptRoot 'ensure-viktor-command.ps1'

if (-not (Test-Path $Ensure)) { throw "Missing $Ensure" }

Write-Host '[viktor-homebase] Installing Python package if available/needed...'
try {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    if ($py) {
        # The base viktor package is optional for plain Python scripts, but install attempt is useful on dev machines.
        & $py.Source -m pip install viktor 2>&1 | Write-Host
    } else {
        Write-Host '[viktor-homebase] python/py not found; skipping pip install.'
    }
} catch {
    Write-Host "[viktor-homebase] pip install viktor skipped/failed: $($_.Exception.Message)"
}

Write-Host '[viktor-homebase] Applying HomeBase viktor.run patch...'
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Ensure

Write-Host '[viktor-homebase] Done.'
Write-Host 'Queue this in Bridge Commands:'
Write-Host '  Command: viktor.run'
Write-Host '  Kind: viktor'
Write-Host '  Risk: low'
Write-Host '  Args: {"script":"viktor/scripts/test.py","args":["--hello","homebase"],"mode":"python","timeout_sec":60}'
