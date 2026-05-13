# AtoMind — single-click launcher
# Starts Home Base and the AI Chat Runtime when needed, then opens the dashboard.

$ErrorActionPreference = 'SilentlyContinue'

$Port       = 8080
$ChatPort   = if ($env:HB_CHAT_PORT) { [int]$env:HB_CHAT_PORT } else { 8081 }
$Url        = "http://localhost:$Port/"
$ChatUrl    = "http://localhost:$ChatPort/"
$Script     = Join-Path $PSScriptRoot 'homebase.ps1'
$ChatScript = Join-Path $PSScriptRoot 'tools\homebase-ai-chat-runtime.ps1'
$EmbedScript = Join-Path $PSScriptRoot 'tools\ensure-in-cockpit-chat.ps1'

function Test-UrlUp {
    param([string]$HealthUrl)
    try {
        $r = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Start-PwshScript {
    param([string]$Path)
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
    if (-not $pwsh) { Write-Error 'No PowerShell found (pwsh or powershell).'; exit 1 }

    Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$Path`"") `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Minimized
}

if (-not (Test-Path $Script)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Couldn't find homebase.ps1 next to this launcher.`n`nExpected: $Script",
        'AtoMind Home Base', 'OK', 'Error'
    ) | Out-Null
    exit 1
}

# v0.6.8.2: ensure the main 8080 cockpit contains the embedded 8081 AI chat card.
# Idempotent; only modifies local homebase.ps1 if the card is missing.
if (Test-Path $EmbedScript) {
    & $EmbedScript | Out-Null
}

if (-not (Test-UrlUp "${Url}api/status")) {
    Start-PwshScript -Path $Script
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-UrlUp "${Url}api/status") { break }
    }
}

# Start the integrated AI chat surface with the app. It runs as a local sidecar on 8081.
# If HB_AI_API_KEY / LLM_API_KEY is set, it auto-connects to the real OpenAI-compatible provider.
# Otherwise it starts safely in dry-run mode.
if ((Test-Path $ChatScript) -and -not (Test-UrlUp "${ChatUrl}api/chat/status")) {
    Start-PwshScript -Path $ChatScript
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-UrlUp "${ChatUrl}api/chat/status") { break }
    }
}

Start-Process $Url
Start-Process $ChatUrl
