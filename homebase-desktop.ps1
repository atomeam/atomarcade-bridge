# ============================================================
# AtoMind Home Base — Desktop Launcher (v0.5.1)
# ============================================================
# Starts the browser Automation Center in homebase.ps1 when needed, then opens
# http://localhost:8080/ in the default browser.
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'

$Version = 'v0.5.1-desktop-launcher'
$Port    = 8080
$Url     = "http://localhost:$Port/"
$HealthUrl = "${Url}api/soak/status"
$Script  = Join-Path $PSScriptRoot 'homebase.ps1'

function Test-HomeBaseUp {
    try {
        $r = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
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

if (-not (Test-Path $Script)) {
    Show-ErrorMessage "Could not find homebase.ps1 next to this launcher.`n`nExpected: $Script"
    exit 1
}

if (-not (Test-HomeBaseUp)) {
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) {
        $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source
    }

    if (-not $pwsh) {
        Show-ErrorMessage 'No PowerShell executable found. Install PowerShell 7 or ensure Windows PowerShell is available.'
        exit 1
    }

    Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $Script) `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Minimized

    # Wait up to 15 seconds for the listener to bind.
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-HomeBaseUp) { break }
    }
}

# Always try to open the browser, even if the health endpoint did not answer.
# If the server is still booting, the browser can be refreshed manually.
Start-Process $Url

if (Test-HomeBaseUp) {
    exit 0
}

Show-ErrorMessage "Home Base browser was opened, but the local server did not answer $HealthUrl yet.`n`nIf the browser does not load after a refresh, run manually:`n`npwsh -File `"$Script`""
exit 1
