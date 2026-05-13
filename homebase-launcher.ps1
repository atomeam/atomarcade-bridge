# AtoMind Home Base - one-click launcher (v0.6.5)
# Starts the bridge if it isn't running, then opens Home Base in an Edge --app window.
# Idempotent: safe to run any number of times. Writes diagnostics to homebase-launcher.log.
#
# v0.6.5 absorbs the Endless Dungeon 'Door Opening' pattern: every click
# gets instant visual feedback. A WPF splash window appears immediately so
# the operator never wonders if the click registered. Status updates per
# phase; splash closes when the cockpit opens (or before any error popup).

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

# ---- Splash window (instant click feedback) -------------------------------
# Runs in a background STA runspace so its WPF dispatcher doesn't get blocked
# by the main script's port checks and polling loop. Main script communicates
# via a synchronized hashtable polled by a DispatcherTimer on the splash side.
$script:splashState = $null
$script:splashRunspace = $null
$script:splashPS = $null
$script:splashAsync = $null

function Start-Splash {
  $script:splashState = [hashtable]::Synchronized(@{
    Status = 'Starting Home Base...'
    ShouldClose = $false
  })
  try {
    $script:splashRunspace = [runspacefactory]::CreateRunspace()
    $script:splashRunspace.ApartmentState = 'STA'
    $script:splashRunspace.ThreadOptions = 'ReuseThread'
    $script:splashRunspace.Open()
    $script:splashRunspace.SessionStateProxy.SetVariable('state', $script:splashState)

    $script:splashPS = [powershell]::Create()
    $script:splashPS.Runspace = $script:splashRunspace
    [void]$script:splashPS.AddScript({
      Add-Type -AssemblyName PresentationFramework
      [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AtoMind Home Base"
        Width="440" Height="240"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        ResizeMode="NoResize"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ShowInTaskbar="True">
  <Border Background="#0F0F1F" CornerRadius="14" BorderBrush="#9D6CFF" BorderThickness="1">
    <Grid>
      <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
        <TextBlock Text="AtoMind" FontSize="40" FontWeight="Bold"
                   Foreground="#9D6CFF" HorizontalAlignment="Center"
                   FontFamily="Segoe UI"/>
        <TextBlock Text="Home Base" FontSize="14"
                   Foreground="#A0A0C0" HorizontalAlignment="Center"
                   FontFamily="Segoe UI" Margin="0,0,0,18"/>
        <ProgressBar IsIndeterminate="True" Width="300" Height="4"
                     Foreground="#9D6CFF" Background="#1A1A2E"
                     BorderThickness="0"/>
        <TextBlock x:Name="StatusText" Text="Starting..."
                   Foreground="#C0C0E0" HorizontalAlignment="Center"
                   FontFamily="Segoe UI" FontSize="12" Margin="0,14,0,0"/>
        <TextBlock Text="v0.6.5 - absorbs everything it contacts"
                   Foreground="#606080" FontSize="10"
                   HorizontalAlignment="Center" Margin="0,10,0,0"
                   FontStyle="Italic"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@
      $reader = New-Object System.Xml.XmlNodeReader $xaml
      $window = [Windows.Markup.XamlReader]::Load($reader)
      $statusText = $window.FindName('StatusText')

      $timer = New-Object System.Windows.Threading.DispatcherTimer
      $timer.Interval = [TimeSpan]::FromMilliseconds(150)
      $timer.Add_Tick({
        $statusText.Text = $state.Status
        if ($state.ShouldClose) {
          $timer.Stop()
          $window.Close()
        }
      })
      $timer.Start()

      [void]$window.ShowDialog()
    })
    $script:splashAsync = $script:splashPS.BeginInvoke()
    Write-LauncherLog 'splash window started'
  } catch {
    Write-LauncherLog "splash failed to start: $($_.Exception.Message)"
  }
}

function Set-SplashStatus {
  param([string]$Status)
  if ($script:splashState) { $script:splashState.Status = $Status }
  Write-LauncherLog "splash: $Status"
}

function Close-Splash {
  if (-not $script:splashState) { return }
  $script:splashState.ShouldClose = $true
  Start-Sleep -Milliseconds 250
  try { if ($script:splashPS -and $script:splashAsync) { [void]$script:splashPS.EndInvoke($script:splashAsync) } } catch { }
  try { if ($script:splashPS) { $script:splashPS.Dispose() } } catch { }
  try { if ($script:splashRunspace) { $script:splashRunspace.Close() } } catch { }
  $script:splashState = $null
}

function Show-LauncherMessage {
  param([string]$Title, [string]$Message)
  Close-Splash
  try {
    $sh = New-Object -ComObject WScript.Shell
    [void]$sh.Popup($Message, 0, $Title, 0x30) # 0x30 = warning icon, OK button
  } catch {
    Write-LauncherLog "Could not show MessageBox: $($_.Exception.Message)"
  }
}

# Show the splash IMMEDIATELY so the click feels responsive
Start-Splash

Write-LauncherLog '==== launcher start ===='
Write-LauncherLog "repo=$repo"

# Locate pwsh.exe explicitly (don't rely on PATH inheritance from the shortcut)
Set-SplashStatus 'Locating PowerShell 7...'
$pwshCmd  = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
if (-not (Test-Path $pwshPath)) {
  Write-LauncherLog "ERROR: pwsh.exe not found at $pwshPath"
  Show-LauncherMessage 'Home Base launcher' "PowerShell 7 (pwsh.exe) not found at:`n$pwshPath`n`nInstall PowerShell 7 from https://aka.ms/powershell."
  exit 1
}
Write-LauncherLog "pwsh=$pwshPath"

# Locate Microsoft Edge
Set-SplashStatus 'Locating Microsoft Edge...'
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

Set-SplashStatus 'Checking if bridge is already running...'
$ready = Test-BridgeReady
Write-LauncherLog "initial readiness=$ready"

if (-not $ready) {
  $portBusy = Test-PortListening -Port $port
  Write-LauncherLog "port $port busy=$portBusy (bridge not ready)"

  if ($portBusy) {
    # Something is on the port but it's not answering /api/health/snapshot or /.
    # Almost certainly a stale homebase.ps1. Kill and restart.
    Set-SplashStatus 'Clearing stale bridge processes...'
    Stop-StaleBridgeProcesses
    Start-Sleep -Seconds 1
  }

  Set-SplashStatus 'Starting bridge...'
  if (-not (Start-Bridge)) { Close-Splash; exit 1 }

  # Poll up to 60s (Notion API auth handshake can take 10-20s on a cold start)
  for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    if ($i -gt 0 -and ($i % 4) -eq 0) {
      Set-SplashStatus ("Waiting for cockpit... {0:N0}s" -f ($i * 0.5))
    }
    if (Test-BridgeReady) {
      $ready = $true
      Write-LauncherLog ("bridge ready after {0:N1}s" -f (($i + 1) * 0.5))
      break
    }
  }
}

if ($ready) {
  Set-SplashStatus 'Opening cockpit in Edge...'
  Write-LauncherLog 'opening Home Base in Edge --app window'
  if ($edge) {
    Start-Process -FilePath $edge -ArgumentList "--app=$rootUrl" | Out-Null
  } else {
    Write-LauncherLog 'Edge not found, falling back to default browser'
    Start-Process $rootUrl | Out-Null
  }
  # Give Edge a moment to take focus, then close splash
  Start-Sleep -Milliseconds 600
  Close-Splash
} else {
  Write-LauncherLog 'TIMEOUT: bridge never responded within 60s'
  Show-LauncherMessage 'Home Base launcher' "Home Base bridge didn't respond within 60 seconds.`n`nThe PowerShell window that opened should show the error.`n`nDiagnostic log:`n$logFile"
}

Write-LauncherLog '==== launcher end ===='
