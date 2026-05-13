# Simple local queue worker loop for HomeBase VIKTOR jobs.
# Watches viktor/queue/*.json and executes queued jobs using handlers/run-viktor-task.ps1.
# This is optional; HomeBase can also launch jobs directly.

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$PollSeconds = 3
)

$ErrorActionPreference = 'Continue'
$QueueDir = Join-Path $RepoRoot 'viktor\queue'
$Handler = Join-Path $RepoRoot 'handlers\run-viktor-task.ps1'
$Log = Join-Path $RepoRoot 'viktor\worker\worker-loop.log'

New-Item -ItemType Directory -Force -Path $QueueDir, (Split-Path -Parent $Log) | Out-Null

function LogLine([string]$m) {
    $line = "{0:o} {1}" -f (Get-Date), $m
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line
}

LogLine "HomeBase VIKTOR worker loop starting repo=$RepoRoot queue=$QueueDir"

while ($true) {
    try {
        $jobs = Get-ChildItem -Path $QueueDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.result\.json$' } |
            Sort-Object CreationTime

        foreach ($job in $jobs) {
            $raw = Get-Content -Raw -Path $job.FullName | ConvertFrom-Json -AsHashtable
            if ($raw.status -and $raw.status -ne 'queued') { continue }

            $jobId = if ($raw.jobId) { [string]$raw.jobId } else { [System.IO.Path]::GetFileNameWithoutExtension($job.Name) }
            $claimFile = Join-Path $QueueDir "$jobId.running"
            if (Test-Path $claimFile) { continue }
            New-Item -ItemType File -Path $claimFile -Force | Out-Null

            $logFile = if ($raw.log_file) { [string]$raw.log_file } else { Join-Path $QueueDir "$jobId.log" }
            $resultFile = if ($raw.result_file) { [string]$raw.result_file } else { Join-Path $QueueDir "$jobId.result.json" }

            LogLine "Executing queued job $jobId"
            & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Handler -JobFile $job.FullName -LogFile $logFile -ResultFile $resultFile 2>&1 | ForEach-Object { LogLine $_ }
            Remove-Item $claimFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        LogLine "ERROR: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $PollSeconds
}
