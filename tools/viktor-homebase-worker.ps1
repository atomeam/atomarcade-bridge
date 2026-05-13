# VIKTOR Generic Worker entrypoint for AtoMind/HomeBase
# Runs approved HomeBase diagnostics/repair tasks and writes output files for VIKTOR.
# Intended config.yaml command shape:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\AtomArcade\atomarcade-bridge\tools\viktor-homebase-worker.ps1 -Task smoke-test

param(
    [ValidateSet('port-diagnose','repair-smoke','repair-real','smoke-test')]
    [string]$Task = 'smoke-test',
    [string]$RepoRoot = 'C:\AtomArcade\atomarcade-bridge',
    [string]$OutputText = 'output.txt',
    [string]$OutputJson = 'diagnostics.json'
)

$ErrorActionPreference = 'Continue'
$started = Get-Date
$lines = [System.Collections.Generic.List[string]]::new()

function LogLine {
    param([string]$Message)
    $line = "{0:o} {1}" -f (Get-Date), $Message
    $lines.Add($line) | Out-Null
    Write-Host $line
}

function Run-Capture {
    param([string]$Label, [scriptblock]$Block)
    LogLine "== $Label =="
    try {
        $out = & $Block 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($out)) {
            $out.TrimEnd() -split "`r?`n" | ForEach-Object { LogLine $_ }
        }
        return @{ ok=$true; output=$out; error=$null }
    } catch {
        LogLine "ERROR: $($_.Exception.Message)"
        return @{ ok=$false; output=''; error=$_.Exception.Message }
    }
}

function Get-Port8080State {
    try {
        $conns = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)
        $owners = @($conns | Select-Object -ExpandProperty OwningProcess -Unique)
        $procs = @()
        foreach ($owner in $owners) {
            try {
                $p = Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue
                if ($p) {
                    $procs += @{ processId=$p.ProcessId; name=$p.Name; commandLine=$p.CommandLine }
                } else {
                    $procs += @{ processId=$owner; name=$null; commandLine=$null }
                }
            } catch {
                $procs += @{ processId=$owner; name=$null; commandLine=$_.Exception.Message }
            }
        }
        return @{ listening=($conns.Count -gt 0); owners=$procs }
    } catch {
        return @{ listening=$false; owners=@(); error=$_.Exception.Message }
    }
}

function Test-Endpoint {
    param([string]$Uri, [int]$TimeoutSec = 8)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $res = Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec
        $sw.Stop()
        return @{ ok=$true; seconds=[math]::Round($sw.Elapsed.TotalSeconds, 2); response=$res; error=$null }
    } catch {
        $sw.Stop()
        return @{ ok=$false; seconds=[math]::Round($sw.Elapsed.TotalSeconds, 2); response=$null; error=$_.Exception.Message }
    }
}

function Test-ChatPost {
    param([int]$TimeoutSec = 20)
    $body = @{ message='hi' } | ConvertTo-Json
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $res = Invoke-RestMethod -Uri 'http://localhost:8080/api/chat' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
        $sw.Stop()
        return @{ ok=$true; seconds=[math]::Round($sw.Elapsed.TotalSeconds, 2); response=$res; error=$null }
    } catch {
        $sw.Stop()
        return @{ ok=$false; seconds=[math]::Round($sw.Elapsed.TotalSeconds, 2); response=$null; error=$_.Exception.Message }
    }
}

if (-not (Test-Path $RepoRoot)) {
    LogLine "RepoRoot not found: $RepoRoot"
}
Set-Location $RepoRoot

LogLine "VIKTOR HomeBase worker task=$Task repo=$RepoRoot"
LogLine "PowerShell=$($PSVersionTable.PSVersion) user=$env:USERNAME computer=$env:COMPUTERNAME"

$beforePort = Get-Port8080State
LogLine "Port 8080 before: $($beforePort | ConvertTo-Json -Depth 6 -Compress)"

$steps = @()

switch ($Task) {
    'port-diagnose' {
        $steps += Run-Capture 'git status' { git status -sb }
        $steps += Run-Capture 'git log -1' { git log -1 --oneline }
        $steps += Run-Capture 'netsh urlacl 8080' { netsh http show urlacl | Select-String '8080' -Context 2,2 }
    }
    'repair-smoke' {
        $steps += Run-Capture 'git pull' { git pull --ff-only origin main }
        $steps += Run-Capture 'fix-homebase-chat-now -Smoke -Start' { pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\fix-homebase-chat-now.ps1 -Smoke -Start }
        Start-Sleep -Seconds 3
    }
    'repair-real' {
        $steps += Run-Capture 'git pull' { git pull --ff-only origin main }
        $steps += Run-Capture 'fix-homebase-chat-now -Start' { pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\fix-homebase-chat-now.ps1 -Start }
        Start-Sleep -Seconds 3
    }
    'smoke-test' {
        $steps += Run-Capture 'homebase-chat-smoke-test' { pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\homebase-chat-smoke-test.ps1 }
    }
}

$afterPort = Get-Port8080State
$status = Test-Endpoint -Uri 'http://localhost:8080/api/status' -TimeoutSec 8
$chatStatus = Test-Endpoint -Uri 'http://localhost:8080/api/chat/status' -TimeoutSec 8
$chatPost = Test-ChatPost -TimeoutSec 20

LogLine "Port 8080 after: $($afterPort | ConvertTo-Json -Depth 6 -Compress)"
LogLine "GET /api/status: $($status | ConvertTo-Json -Depth 8 -Compress)"
LogLine "GET /api/chat/status: $($chatStatus | ConvertTo-Json -Depth 8 -Compress)"
LogLine "POST /api/chat: $($chatPost | ConvertTo-Json -Depth 8 -Compress)"

$summaryOk = $status.ok -and $chatStatus.ok -and ($Task -ne 'smoke-test' -or $chatPost.ok)
$diagnostics = [ordered]@{
    ok = $summaryOk
    task = $Task
    started = $started.ToString('o')
    ended = (Get-Date).ToString('o')
    repoRoot = $RepoRoot
    beforePort = $beforePort
    afterPort = $afterPort
    status = $status
    chatStatus = $chatStatus
    chatPost = $chatPost
    steps = $steps
}

$lines | Out-File -FilePath $OutputText -Encoding UTF8 -Force
$diagnostics | ConvertTo-Json -Depth 12 | Out-File -FilePath $OutputJson -Encoding UTF8 -Force

if ($summaryOk) {
    LogLine "RESULT: OK"
    exit 0
} else {
    LogLine "RESULT: FAIL"
    exit 2
}
