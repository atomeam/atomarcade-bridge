# Optional Windows service installer for a local VIKTOR/HomeBase worker loop.
# Run as Administrator if you want the worker installed as a service.
# This does NOT expose arbitrary shell execution; it runs the allowlisted HomeBase worker wrapper.
#
# Usage:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\install-viktor-worker-service.ps1 -Install
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\install-viktor-worker-service.ps1 -Uninstall

param(
    [switch]$Install,
    [switch]$Uninstall,
    [string]$ServiceName = 'HomeBaseViktorWorker',
    [string]$DisplayName = 'HomeBase VIKTOR Worker',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$WorkerLoop = Join-Path $RepoRoot 'tools\viktor-worker-loop.ps1'
$Pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $Pwsh) { $Pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell window for service install/uninstall.'
    }
}

if ($Uninstall) {
    Assert-Admin
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue }
        sc.exe delete $ServiceName | Out-Host
        Write-Host "Removed service $ServiceName"
    } else {
        Write-Host "Service $ServiceName not found."
    }
    exit 0
}

if (-not $Install) {
    Write-Host 'Specify -Install or -Uninstall.'
    exit 1
}

Assert-Admin
if (-not (Test-Path $Pwsh)) { throw "pwsh.exe not found: $Pwsh" }
if (-not (Test-Path $WorkerLoop)) { throw "Worker loop not found: $WorkerLoop" }

New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'viktor\queue'), (Join-Path $RepoRoot 'viktor\worker'), (Join-Path $RepoRoot 'viktor\chatlogs') | Out-Null

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Service $ServiceName already exists. Updating requires uninstall first."
    Write-Host "Run: pwsh -File .\tools\install-viktor-worker-service.ps1 -Uninstall"
    exit 0
}

$binPath = '"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}" -RepoRoot "{2}"' -f $Pwsh, $WorkerLoop, $RepoRoot
New-Service -Name $ServiceName -DisplayName $DisplayName -BinaryPathName $binPath -StartupType Manual -Description 'Runs the local HomeBase VIKTOR worker queue loop.' | Out-Null
Write-Host "Installed service $ServiceName"
Write-Host "Start it with: Start-Service $ServiceName"
Write-Host "Stop it with:  Stop-Service $ServiceName"
