<#
.SYNOPSIS
  Fresh-start recovery helper for AtoMind/HomeBase.

.DESCRIPTION
  Performs the common "runtime drift" recovery sequence for the local HomeBase bridge:
  - stop stale HomeBase PowerShell processes by command line
  - update the repo from origin/main
  - apply the native cockpit chat patch
  - install/wire the VIKTOR HomeBase runtime
  - set HomeBase Ollama env vars for both current and future processes
  - verify/pull the selected Ollama model when possible
  - relaunch HomeBase through the launcher
  - smoke-check chat status and a ping request

  The script is designed to be idempotent and operator-friendly. It does not require
  administrator privileges for the default path.

.EXAMPLE
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\fresh-start-homebase-recovery.ps1

.EXAMPLE
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\fresh-start-homebase-recovery.ps1 -DryRun

.EXAMPLE
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\fresh-start-homebase-recovery.ps1 -OllamaModel llama3.2:3b
#>

param(
    [switch]$DryRun,
    [switch]$SkipGitPull,
    [switch]$SkipKill,
    [switch]$SkipLaunch,
    [switch]$SkipSmokeTest,
    [switch]$SkipModelPull,

    [string]$RepoPath = "C:\AtomArcade\atomarcade-bridge",
    [string]$LauncherPath = "C:\AtomArcade\atomarcade-bridge\homebase-launcher.ps1",

    [string]$OllamaModel = "gpt-oss:20b",
    [string]$FallbackOllamaModel = "llama3.2:3b",
    [int]$OllamaTimeoutSec = 180,
    [int]$BootWaitSeconds = 10
)

$ErrorActionPreference = "Continue"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Gray
}

function Write-Ok {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Fail {
    param([string]$Message)
    Write-Error $Message
    throw $Message
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Block,
        [Parameter(Mandatory=$true)][string]$Label,
        [switch]$AllowFailure
    )

    Write-Host "-> $Label" -ForegroundColor Yellow
    if ($DryRun) {
        Write-Info "   dry-run: skipped"
        return $null
    }

    $script:LASTEXITCODE = 0
    $output = & $Block 2>&1
    if ($null -ne $output) {
        $output | ForEach-Object { Write-Host "   $_" }
    }

    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }

    return $output
}

function Get-HomeBaseProcessCandidates {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -match "^(pwsh|powershell)(\.exe)?$") -and
            ($_.CommandLine -match "homebase|atomarcade-bridge|AtoMind|AtomArcade")
        }
}

function Stop-HomeBaseProcesses {
    Write-Step "Stopping stale HomeBase processes"

    if ($SkipKill) {
        Write-Info "SkipKill set; not stopping processes."
        return
    }

    $candidates = @(Get-HomeBaseProcessCandidates)
    if ($candidates.Count -eq 0) {
        Write-Ok "No stale HomeBase PowerShell processes found."
        return
    }

    Write-Host "Found candidate processes:" -ForegroundColor Yellow
    $candidates |
        Select-Object ProcessId, Name, CommandLine |
        Format-Table -AutoSize |
        Out-String |
        Write-Host

    if ($DryRun) {
        Write-Info "dry-run: would stop the processes above"
        return
    }

    foreach ($p in $candidates) {
        try {
            Write-Host "Stopping PID $($p.ProcessId)"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Failed to stop PID $($p.ProcessId): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
}

function Set-HomeBaseEnv {
    Write-Step "Setting HomeBase Ollama environment"

    $pairs = [ordered]@{
        HB_AI_PROVIDER        = "ollama"
        HB_AI_ENDPOINT        = "http://localhost:11434/v1/chat/completions"
        HB_AI_MODEL           = $OllamaModel
        HB_AI_TIMEOUT_SEC     = [string]$OllamaTimeoutSec
        HB_AI_INCLUDE_CONTEXT = "0"
    }

    foreach ($key in $pairs.Keys) {
        $value = $pairs[$key]
        Write-Host "$key=$value"

        if (-not $DryRun) {
            Set-Item -Path "Env:$key" -Value $value
            setx $key $value | Out-Null
        }
    }

    Write-Ok "Environment set for this process and persisted for future processes."
    Write-Info "Note: setx values are visible to newly-launched shells/processes, not already-running ones."
}

function Sync-Repo {
    Write-Step "Updating repository"

    if (-not (Test-Path $RepoPath)) {
        Fail "Repo path not found: $RepoPath"
    }

    Push-Location $RepoPath
    try {
        Invoke-LoggedCommand { git status --short } "git status --short" -AllowFailure
        Invoke-LoggedCommand { git rev-parse --abbrev-ref HEAD } "git rev-parse --abbrev-ref HEAD" -AllowFailure
        Invoke-LoggedCommand { git log -n 3 --oneline } "git log -n 3 --oneline" -AllowFailure

        if ($SkipGitPull) {
            Write-Info "SkipGitPull set; not pulling."
            return
        }

        Invoke-LoggedCommand { git fetch origin --prune } "git fetch origin --prune"
        Invoke-LoggedCommand { git checkout main } "git checkout main"
        Invoke-LoggedCommand { git pull --ff-only origin main } "git pull --ff-only origin main"
        Invoke-LoggedCommand { git log -n 3 --oneline } "git log -n 3 --oneline after pull" -AllowFailure
    } finally {
        Pop-Location
    }
}

function Invoke-RepoScript {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Label,
        [switch]$Optional
    )

    $path = Join-Path $RepoPath $RelativePath
    Write-Step $Label

    if (-not (Test-Path $path)) {
        if ($Optional) {
            Write-Warn "Script not found, skipping: $path"
            return
        }
        Fail "Script not found: $path"
    }

    Push-Location $RepoPath
    try {
        Invoke-LoggedCommand {
            pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $path
        } $Label
    } finally {
        Pop-Location
    }
}

function Ensure-OllamaModel {
    Write-Step "Checking Ollama model"

    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollama) {
        Write-Warn "ollama CLI not found on PATH. Install/start Ollama or pull the model manually."
        return
    }

    Write-Ok "Ollama CLI found: $($ollama.Source)"

    Invoke-LoggedCommand { ollama --version } "ollama --version" -AllowFailure
    $models = Invoke-LoggedCommand { ollama list } "ollama list" -AllowFailure
    $modelsText = ($models | Out-String)

    if ($modelsText -match [regex]::Escape($OllamaModel)) {
        Write-Ok "Model already present: $OllamaModel"
        return
    }

    if ($SkipModelPull) {
        Write-Warn "Model not present and SkipModelPull set: $OllamaModel"
        return
    }

    Invoke-LoggedCommand { ollama pull $OllamaModel } "ollama pull $OllamaModel" -AllowFailure
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Pulled model: $OllamaModel"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackOllamaModel)) {
        Write-Warn "Preferred model pull failed. Trying fallback: $FallbackOllamaModel"
        Invoke-LoggedCommand { ollama pull $FallbackOllamaModel } "ollama pull $FallbackOllamaModel" -AllowFailure
        if ($LASTEXITCODE -eq 0) {
            $script:OllamaModel = $FallbackOllamaModel
            if (-not $DryRun) {
                Set-Item -Path Env:HB_AI_MODEL -Value $FallbackOllamaModel
                setx HB_AI_MODEL $FallbackOllamaModel | Out-Null
            }
            Write-Ok "Using fallback model: $FallbackOllamaModel"
        } else {
            Write-Warn "Fallback model pull also failed. Set HB_AI_MODEL to an exact model from ollama list."
        }
    }
}

function Start-HomeBase {
    Write-Step "Launching HomeBase"

    if ($SkipLaunch) {
        Write-Info "SkipLaunch set; not launching HomeBase."
        return
    }

    if (-not (Test-Path $LauncherPath)) {
        Fail "Launcher not found: $LauncherPath"
    }

    if ($DryRun) {
        Write-Info "dry-run: would launch $LauncherPath"
        return
    }

    Start-Process pwsh -ArgumentList @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $LauncherPath
    ) | Out-Null

    Write-Ok "HomeBase launch requested."
}

function Test-HomeBaseChat {
    Write-Step "Smoke-checking HomeBase chat"

    if ($SkipSmokeTest) {
        Write-Info "SkipSmokeTest set; not checking endpoints."
        return
    }

    if ($DryRun) {
        Write-Info "dry-run: would call /api/chat/status and /api/chat"
        return
    }

    Write-Info "Waiting $BootWaitSeconds seconds for HomeBase to boot..."
    Start-Sleep -Seconds $BootWaitSeconds

    try {
        $status = Invoke-RestMethod -Uri "http://localhost:8080/api/chat/status" -TimeoutSec 10
        Write-Ok "Chat status endpoint responded:"
        $status | ConvertTo-Json -Depth 8 | Write-Host
    } catch {
        Write-Warn "Could not reach /api/chat/status yet: $($_.Exception.Message)"
        return
    }

    try {
        $body = @{ message = "ping" } | ConvertTo-Json
        $chat = Invoke-RestMethod -Uri "http://localhost:8080/api/chat" -Method Post -ContentType "application/json" -Body $body -TimeoutSec ([Math]::Max($OllamaTimeoutSec + 10, 190))
        Write-Ok "Chat ping responded:"
        $chat | ConvertTo-Json -Depth 8 | Write-Host
    } catch {
        Write-Warn "Chat ping failed: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "AtoMind HomeBase fresh-start recovery" -ForegroundColor Cyan
Write-Host "RepoPath: $RepoPath"
Write-Host "LauncherPath: $LauncherPath"
Write-Host "OllamaModel: $OllamaModel"
Write-Host "DryRun: $DryRun"

try {
    Stop-HomeBaseProcesses
    Sync-Repo
    Invoke-RepoScript -RelativePath "tools\ensure-in-cockpit-chat.ps1" -Label "Applying cockpit chat patch"
    Invoke-RepoScript -RelativePath "tools\install-viktor-homebase.ps1" -Label "Installing VIKTOR into HomeBase runtime" -Optional
    Set-HomeBaseEnv
    Ensure-OllamaModel
    Start-HomeBase
    Test-HomeBaseChat

    Write-Step "Done"
    Write-Ok "Fresh-start recovery sequence completed."
    Write-Host ""
    Write-Host "Manual verification:"
    Write-Host "- HomeBase chat status should show: provider=ollama model=$OllamaModel context=false timeout=${OllamaTimeoutSec}s"
    Write-Host "- A simple chat message should not remain stuck on Thinking..."
    Write-Host "- VIKTOR Bridge test:"
    Write-Host '  Command: viktor.run'
    Write-Host '  Kind: viktor'
    Write-Host '  Risk: low'
    Write-Host '  Args: {"script":"viktor/scripts/test.py","args":["--hello","homebase"],"mode":"python","timeout_sec":60}'
} catch {
    Write-Host ""
    Write-Host "Fresh-start recovery failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Try rerunning with -DryRun, or inspect launcher/HomeBase logs."
    exit 1
}