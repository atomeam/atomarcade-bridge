# HomeBase handler: viktor.run
# Queues a local Viktor job and starts the worker wrapper in the background.

param(
    [Parameter(Mandatory=$true)]
    [string]$payloadJson
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ViktorRoot = Join-Path $RepoRoot 'viktor'
$ScriptsRoot = Join-Path $ViktorRoot 'scripts'
$QueueDir = Join-Path $ViktorRoot 'queue'
$Worker = Join-Path $PSScriptRoot 'run-viktor-task.ps1'

New-Item -ItemType Directory -Force -Path $QueueDir, $ScriptsRoot | Out-Null

$payload = $payloadJson | ConvertFrom-Json -AsHashtable
if (-not $payload.script) { throw 'Missing script' }

$scriptText = [string]$payload.script
$rootFull = [System.IO.Path]::GetFullPath($ScriptsRoot)
$scriptFull = if ([System.IO.Path]::IsPathRooted($scriptText)) {
    [System.IO.Path]::GetFullPath($scriptText)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $scriptText))
}

$allowOutside = ($env:ATOMARCADE_VIKTOR_ALLOW_OUTSIDE_ROOT -eq '1')
if (-not $allowOutside -and -not $scriptFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Script blocked: must be under $rootFull"
}
if (-not (Test-Path $scriptFull)) { throw "Script not found: $scriptFull" }

$jobId = [guid]::NewGuid().ToString('N')
$jobFile = Join-Path $QueueDir "$jobId.json"
$logFile = Join-Path $QueueDir "$jobId.log"
$resultFile = Join-Path $QueueDir "$jobId.result.json"

$job = [ordered]@{
    jobId = $jobId
    status = 'queued'
    created_at = (Get-Date).ToString('o')
    payload = $payload
    script_full = $scriptFull
    log_file = $logFile
    result_file = $resultFile
}
$job | ConvertTo-Json -Depth 10 | Out-File -FilePath $jobFile -Encoding UTF8 -Force

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction Stop).Source }

Start-Process -FilePath $pwsh -ArgumentList @(
    '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$Worker,
    '-JobFile',$jobFile,
    '-LogFile',$logFile,
    '-ResultFile',$resultFile
) -WindowStyle Hidden | Out-Null

@{
    ok = $true
    status = 'queued'
    jobId = $jobId
    jobFile = $jobFile
    logPath = $logFile
    resultPath = $resultFile
} | ConvertTo-Json -Depth 8
