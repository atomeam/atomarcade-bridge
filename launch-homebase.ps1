# AtoMind — single-click launcher
# v0.6.8.9: single-app HomeBase launch. Native AI chat and VIKTOR chat are served by homebase.ps1 on 8080.
# No iframe sidecar. No automatic 8081 window.

$ErrorActionPreference = 'SilentlyContinue'

$Port        = 8080
$Url         = "http://localhost:$Port/"
$Script      = Join-Path $PSScriptRoot 'homebase.ps1'
$EmbedScript = Join-Path $PSScriptRoot 'tools\ensure-homebase-integrated-chats.ps1'

function Test-UrlUp {
    param([string]$HealthUrl)
    try {
        $r = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Stop-PortListener {
    param([int]$LocalPort)
    try {
        Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    } catch {}
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
        'AtoMind HomeBase', 'OK', 'Error'
    ) | Out-Null
    exit 1
}

# Ensure both native AI chat and VIKTOR chat are injected into the 8080 cockpit before boot.
if (Test-Path $EmbedScript) {
    & $EmbedScript | Out-Null
}

# Force restart 8080 so the in-memory dashboard picks up the freshly patched homebase.ps1.
Stop-PortListener -LocalPort $Port
Start-Sleep -Milliseconds 500

Start-PwshScript -Path $Script
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-UrlUp "${Url}api/status") { break }
}

Start-Process $Url