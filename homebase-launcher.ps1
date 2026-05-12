# AtoMind Home Base - one-click launcher (v0.6.5)
# Starts the bridge if it isn't running, then opens Home Base in an Edge --app window.
# Idempotent: safe to run any number of times. Writes diagnostics to homebase-launcher.log.

$ErrorActionPreference = 'SilentlyContinue'

$port = 8080
$rootUrl   = "http://localhost:$port/"
$healthUrl = "http://localhost:$port/api/health/snapshot"

$repo = $PSScriptRoot
if (-not $repo) { $repo = Split-Path -Parent $MyInvocation.MyCommand.Path }
$bridgePs1 = Join-Path $repo 'homebase.ps1'
$logFile   = Join-Path $repo 'homebase-launcher.log'

function Write-LauncherLog {
  param([string]$Message)
  try {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
  } catch { }
}

function Show-LauncherMessage {
  param([string]$Title, [string]$Message)
  try {
    $sh = New-Object -ComObject WScript.Shell
    [void]$sh.Popup($Message, 0, $Title, 0x30) # 0x30 = warning icon, OK button
  } catch {
    Write-LauncherLog "Could not show MessageBox: $($_.Exception.Message)"
  }
}

Write-LauncherLog '==== launcher start ===='
Write-LauncherLog "repo=$repo"

# Locate pwsh.exe explicitly (don't rely on PATH inheritance from the shortcut)
$pwshCmd  = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
if (-not (Test-Path $pwshPath)) {
  Write-LauncherLog "ERROR: pwsh.exe not found at $pwshPath"
  Show-LauncherMessage 'Home Base launcher' "PowerShell 7 (pwsh.exe) not found at:`n$pwshPath`n`nInstall PowerShell 7 from https://aka.ms/powershell."
  exit 1
}
Write-LauncherLog "pwsh=$pwshPath"

# Locate Microsoft Edge
$edgeCandidates = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
)
$edge = $edgeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
Write-LauncherLog "edge=$edge"

function Test-BridgeReady {
  # Hit /api/health/snapshot first (proves the app is actually responding).
  # Fall back to the root URL for older bridge versions that don't have the endpoint yet.
  try {
    $null = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    return $true
  } catch { }
  try {
    $null = Invoke-WebRequest -Uri $rootUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    return $true
  } catch { }
  return $false
}

function Test-PortListening {
  param([int]$Port)
  try {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conns)
  } catch { return $false }
}

function Stop-StaleBridgeProcesses {
  # Only kill pwsh/powershell whose command line includes homebase.ps1.
  # This avoids nuking unrelated PowerShell sessions the operator may have open.
  try {
    $stale = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and ($_.CommandLine -match 'homebase\.ps1') -and ($_.ProcessId -ne $PID) }
    foreach ($p in $stale) {
      Write-LauncherLog "killing stale homebase.ps1 PID=$($p.ProcessId)"
      Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
  } catch {
    Write-LauncherLog "Stop-StaleBridgeProcesses error: $($_.Exception.Message)"
  }
}

function Start-Bridge {
  if (-not (Test-Path $bridgePs1)) {
    Write-LauncherLog "ERROR: homebase.ps1 missing at $bridgePs1"
    Show-LauncherMessage 'Home Base launcher' "homebase.ps1 not found at:`n$bridgePs1`n`nRun: cd $repo ; git pull --ff-only origin main"
    return $false
  }
  Write-LauncherLog "starting bridge: $pwshPath -File $bridgePs1"
  # Visible window so startup errors are on screen if anything goes wrong.
  Start-Process -FilePath $pwshPath -ArgumentList @(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $bridgePs1
  ) -WindowStyle Normal | Out-Null
  return $true
}

$ready = Test-BridgeReady
Write-LauncherLog "initial readiness=$ready"

if (-not $ready) {
  $portBusy = Test-PortListening -Port $port
  Write-LauncherLog "port $port busy=$portBusy (bridge not ready)"

  if ($portBusy) {
    # Something is on the port but it's not answering /api/health/snapshot or /.
    # Almost certainly a stale homebase.ps1. Kill and restart.
    Stop-StaleBridgeProcesses
    Start-Sleep -Seconds 1
  }

  if (-not (Start-Bridge)) { exit 1 }

  # Poll up to 60s (Notion API auth handshake can take 10-20s on a cold start)
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-BridgeReady) {
      $ready = $true
      Write-LauncherLog ("bridge ready after {0:N1}s" -f (($i + 1) * 0.5))
      break
    }
  }
}

if ($ready) {
  Write-LauncherLog 'opening Home Base in Edge --app window'
  if ($edge) {
    Start-Process -FilePath $edge -ArgumentList "--app=$rootUrl" | Out-Null
  } else {
    Write-LauncherLog 'Edge not found, falling back to default browser'
    Start-Process $rootUrl | Out-Null
  }
} else {
  Write-LauncherLog 'TIMEOUT: bridge never responded within 60s'
  Show-LauncherMessage 'Home Base launcher' "Home Base bridge didn't respond within 60 seconds.`n`nThe PowerShell window that opened should show the error.`n`nDiagnostic log:`n$logFile"
}

Write-LauncherLog '==== launcher end ===='
