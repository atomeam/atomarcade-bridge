# AtomArcade Home Base — one-click launcher
# Starts the bridge if it isn't running, then opens Home Base in an Edge --app window.
# Idempotent: safe to run any number of times.

$ErrorActionPreference = 'SilentlyContinue'

$port = 8080
$url  = "http://localhost:$port/"

$repo = $PSScriptRoot
if (-not $repo) { $repo = Split-Path -Parent $MyInvocation.MyCommand.Path }
$bridgePs1 = Join-Path $repo 'homebase.ps1'

# Locate Microsoft Edge
$edgeCandidates = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
)
$edge = $edgeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

function Test-BridgeUp {
  param([string]$Url)
  try {
    $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

$up = Test-BridgeUp -Url $url

if (-not $up) {
  if (Test-Path $bridgePs1) {
    # Start the bridge minimized so it doesn't steal focus
    Start-Process -FilePath 'pwsh.exe' -ArgumentList @(
      '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $bridgePs1
    ) -WindowStyle Minimized | Out-Null

    # Poll up to ~15 seconds for the bridge to come up
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Milliseconds 500
      if (Test-BridgeUp -Url $url) { $up = $true; break }
    }
  } else {
    Write-Warning "homebase.ps1 not found next to launcher at: $bridgePs1"
  }
}

# Open Home Base as an Edge app window (no tab bar, no address bar = looks like a real app)
if ($edge) {
  Start-Process -FilePath $edge -ArgumentList "--app=$url" | Out-Null
} else {
  # Fallback: default browser
  Start-Process $url | Out-Null
}
