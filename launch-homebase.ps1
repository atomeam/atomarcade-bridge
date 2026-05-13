# AtoMind — single-click launcher
# If Home Base isn't running, start it. Then open the dashboard in the default browser.
# Used by the desktop shortcut created by install-shortcut.ps1.

$ErrorActionPreference = 'SilentlyContinue'

$Port    = 8080
$Url     = "http://localhost:$Port/"
$Script  = Join-Path $PSScriptRoot 'homebase.ps1'

function Test-HomeBaseUp {
    try {
        $r = Invoke-WebRequest -Uri "${Url}api/status" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

if (-not (Test-Path $Script)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Couldn't find homebase.ps1 next to this launcher.`n`nExpected: $Script",
        'AtoMind Home Base', 'OK', 'Error'
    ) | Out-Null
    exit 1
}

if (-not (Test-HomeBaseUp)) {
    # Launch Home Base in its own minimized PowerShell window so it keeps running
    # after this launcher exits. Use pwsh if available, fall back to Windows PowerShell.
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
    if (-not $pwsh) { Write-Error 'No PowerShell found (pwsh or powershell).'; exit 1 }

    Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$Script`"") `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Minimized

    # Wait up to 10 seconds for the listener to bind
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-HomeBaseUp) { break }
    }
}

Start-Process $Url
