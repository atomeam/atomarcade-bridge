# apps/minimal-ai/tools/install-minimal-ai.ps1
# Idempotent installer for the minimal HomeBase VIKTOR app.
# - Verifies Python 3.10+ on PATH
# - Installs VIKTOR CLI if missing
# - Verifies Ollama is reachable; optionally pulls the default model
# - Persists HB_AI_* env vars for the current user

[CmdletBinding()]
param(
    [string]$Model     = 'qwen2.5:7b-instruct',
    [string]$Endpoint  = 'http://localhost:11434/v1/chat/completions',
    [int]   $TimeoutSec = 300,
    [string]$KeepAlive  = '30m',
    [switch]$PullModel
)

$ErrorActionPreference = 'Stop'

function Hdr($msg)  { Write-Host ''; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Bad($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

Hdr '1. Python check'
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Bad 'Python not on PATH. Install from https://www.python.org/downloads/windows/ (check "Add to PATH").'
    exit 1
}
$ver = (& python --version) 2>&1
Ok "$ver at $($py.Source)"

Hdr '2. VIKTOR CLI'
$viktor = Get-Command viktor -ErrorAction SilentlyContinue
if (-not $viktor) {
    Warn 'viktor CLI not found. Installing via pip...'
    & python -m pip install --upgrade pip | Out-Null
    & python -m pip install viktor
    $viktor = Get-Command viktor -ErrorAction SilentlyContinue
    if (-not $viktor) { Bad 'viktor install failed.'; exit 1 }
}
Ok "viktor CLI at $($viktor.Source)"

Hdr '3. Ollama reachability'
try {
    $tags = Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 3
    $count = @($tags.models).Count
    Ok "Ollama listening on :11434 ($count model(s) available)"
    $have = @($tags.models) | Where-Object { $_.name -eq $Model -or $_.model -eq $Model }
    if (-not $have) {
        Warn "Model '$Model' not pulled yet."
        if ($PullModel) {
            Write-Host "  Pulling $Model (this may take a few minutes)..."
            & ollama pull $Model
        } else {
            Warn "Re-run with -PullModel to download it, or run: ollama pull $Model"
        }
    } else {
        Ok "Model '$Model' is pulled"
    }
} catch {
    Warn 'Ollama not reachable yet. Install Ollama Desktop and make sure it is running.'
    Warn 'Download: https://ollama.com/download/windows'
}

Hdr '4. Env vars (persisted for current user)'
[Environment]::SetEnvironmentVariable('HB_AI_PROVIDER',    'ollama',        'User')
[Environment]::SetEnvironmentVariable('HB_AI_ENDPOINT',    $Endpoint,        'User')
[Environment]::SetEnvironmentVariable('HB_AI_MODEL',       $Model,           'User')
[Environment]::SetEnvironmentVariable('HB_AI_API_KEY',     'ollama-local',   'User')
[Environment]::SetEnvironmentVariable('HB_AI_TIMEOUT_SEC', "$TimeoutSec",    'User')
[Environment]::SetEnvironmentVariable('HB_AI_KEEP_ALIVE',  $KeepAlive,       'User')
Ok 'HB_AI_* env vars set. Restart your terminal so they take effect.'

Hdr 'Done'
Write-Host 'Next:'
Write-Host '  cd apps\minimal-ai'
Write-Host '  viktor start'
Write-Host 'Then run .\tools\smoke-minimal-ai.ps1 to verify.'
