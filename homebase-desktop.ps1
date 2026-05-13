# ============================================================
# AtoMind Home Base — Desktop Launcher (v0.6.8.2)
# ============================================================
# Starts the browser Automation Center in homebase.ps1 and the AI Chat Runtime
# sidecar when needed, then opens both local app surfaces.
# v0.6.8.2 also ensures the main cockpit embeds the chat panel.
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'

$Version = 'v0.6.8.2-in-cockpit-chat-launcher'
$Port    = 8080
$ChatPort = if ($env:HB_CHAT_PORT) { [int]$env:HB_CHAT_PORT } else { 8081 }
$Url     = "http://localhost:$Port/"
$HealthUrl = "${Url}api/soak/status"
$ChatUrl = "http://localhost:$ChatPort/"
$ChatHealthUrl = "${ChatUrl}api/chat/status"
$Script  = Join-Path $PSScriptRoot 'homebase.ps1'
$ChatScript = Join-Path $PSScriptRoot 'tools\homebase-ai-chat-runtime.ps1'
$EmbedScript = Join-Path $PSScriptRoot 'tools\ensure-in-cockpit-chat.ps1'

function Test-EndpointUp {
    param([string]$Endpoint)
    try {
        $r = Invoke-WebRequest -Uri $Endpoint -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Show-ErrorMessage {
    param([string]$Message)

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            'AtoMind Home Base',
            'OK',
            'Error'
        ) | Out-Null
    } catch {
        Write-Error $Message
    }
}

function Start-PwshScript {
    param([string]$Path)
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) {
        $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source
    }

    if (-not $pwsh) {
        Show-ErrorMessage 'No PowerShell executable found. Install PowerShell 7 or ensure Windows PowerShell is available.'
        exit 1
    }

    Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $Path) `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Minimized
}

if (-not (Test-Path $Script)) {
    Show-ErrorMessage "Could not find homebase.ps1 next to this launcher.`n`nExpected: $Script"
    exit 1
}

# v0.6.8.2: ensure the main 8080 cockpit contains the embedded 8081 AI chat card.
# Idempotent; only modifies local homebase.ps1 if the card is missing.
if (Test-Path $EmbedScript) {
    & $EmbedScript | Out-Null
}

if (-not (Test-EndpointUp $HealthUrl)) {
    Start-PwshScript -Path $Script

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-EndpointUp $HealthUrl) { break }
    }
}

if ((Test-Path $ChatScript) -and -not (Test-EndpointUp $ChatHealthUrl)) {
    Start-PwshScript -Path $ChatScript

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-EndpointUp $ChatHealthUrl) { break }
    }
}

Start-Process $Url
Start-Process $ChatUrl

if (Test-EndpointUp $HealthUrl) {
    exit 0
}

Show-ErrorMessage "Home Base browser was opened, but the local server did not answer $HealthUrl yet.`n`nIf the browser does not load after a refresh, run manually:`n`npwsh -File `"$Script`""
exit 1
