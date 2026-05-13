# ============================================================
# AtoMind HomeBase — Desktop Launcher (v0.6.8.6)
# ============================================================
# Single-app launch: starts only the main HomeBase cockpit on localhost:8080.
# Native AI chat is injected into homebase.ps1 and served from the same app.
# No iframe sidecar and no automatic localhost:8081 window.
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'

$Version = 'v0.6.8.6-single-app-native-chat'
$Port    = 8080
$Url     = "http://localhost:$Port/"
$HealthUrl = "${Url}api/status"
$Script  = Join-Path $PSScriptRoot 'homebase.ps1'
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

function Stop-PortListener {
    param([int]$LocalPort)
    try {
        Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Show-ErrorMessage {
    param([string]$Message)

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            'AtoMind HomeBase',
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

# Ensure native chat is injected into the 8080 cockpit before boot.
if (Test-Path $EmbedScript) {
    & $EmbedScript | Out-Null
}

# Force restart the main app so the patched dashboard is loaded into memory.
Stop-PortListener -LocalPort $Port
Start-Sleep -Milliseconds 500

Start-PwshScript -Path $Script
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-EndpointUp $HealthUrl) { break }
}

Start-Process $Url

if (Test-EndpointUp $HealthUrl) {
    exit 0
}

Show-ErrorMessage "HomeBase was opened, but the local server did not answer $HealthUrl yet.`n`nIf the browser does not load after a refresh, run manually:`n`npwsh -File `"$Script`""
exit 1
