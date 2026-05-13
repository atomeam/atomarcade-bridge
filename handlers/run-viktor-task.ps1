# Executes a queued HomeBase Viktor job.
# The job payload supports:
#   script: viktor/scripts/test.py
#   args: ["--hello", "homebase"]
#   mode: python | viktor-cli
#   timeout_sec: 120

param(
    [Parameter(Mandatory=$true)][string]$JobFile,
    [Parameter(Mandatory=$true)][string]$LogFile,
    [Parameter(Mandatory=$true)][string]$ResultFile
)

$ErrorActionPreference = 'Continue'

function LogLine([string]$m) {
    $line = "{0:o} {1}" -f (Get-Date), $m
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

$started = Get-Date
try {
    $job = Get-Content -Raw -Path $JobFile | ConvertFrom-Json -AsHashtable
    $payload = $job.payload
    $scriptFull = [string]$job.script_full
    $args = @()
    if ($payload.args -is [System.Collections.IEnumerable] -and -not ($payload.args -is [string])) {
        foreach ($a in $payload.args) { $args += [string]$a }
    } elseif ($payload.args) { $args += [string]$payload.args }

    $mode = if ($payload.mode) { [string]$payload.mode } else { 'python' }
    $timeout = if ($payload.timeout_sec) { [int]$payload.timeout_sec } else { 120 }
    if ($timeout -lt 1) { $timeout = 1 }
    if ($timeout -gt 900) { $timeout = 900 }

    LogLine "Starting Viktor job $($job.jobId) mode=$mode script=$scriptFull timeout=${timeout}s"

    switch ($mode) {
        'python' {
            $cmd = Get-Command python -ErrorAction SilentlyContinue
            if (-not $cmd) { $cmd = Get-Command py -ErrorAction SilentlyContinue }
            if (-not $cmd) { throw 'python/py not found on PATH' }
            $filePath = $cmd.Source
            $processArgs = @($scriptFull) + $args
        }
        'viktor-cli' {
            $cmd = Get-Command viktor -ErrorAction SilentlyContinue
            if (-not $cmd) { throw 'viktor CLI not found on PATH' }
            $filePath = $cmd.Source
            $processArgs = @('run', $scriptFull) + $args
        }
        default { throw "Unsupported mode: $mode" }
    }

    LogLine "Executing: $filePath $($processArgs -join ' ')"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $filePath
    foreach ($a in $processArgs) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory = Split-Path -Parent $scriptFull
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    $out = [System.Text.StringBuilder]::new()
    $err = [System.Text.StringBuilder]::new()
    $p.add_OutputDataReceived({ if ($null -ne $_.Data) { [void]$out.AppendLine($_.Data); LogLine "OUT: $($_.Data)" } })
    $p.add_ErrorDataReceived({ if ($null -ne $_.Data) { [void]$err.AppendLine($_.Data); LogLine "ERR: $($_.Data)" } })

    [void]$p.Start()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    $exited = $p.WaitForExit($timeout * 1000)
    if (-not $exited) {
        try { $p.Kill($true) } catch {}
        $result = @{ ok=$false; status='timeout'; jobId=$job.jobId; exit_code=$null; timed_out=$true; stdout=[string]$out; stderr=[string]$err; elapsed_sec=[math]::Round(((Get-Date)-$started).TotalSeconds,2) }
    } else {
        $p.WaitForExit()
        $result = @{ ok=($p.ExitCode -eq 0); status=($(if ($p.ExitCode -eq 0) { 'completed' } else { 'failed' })); jobId=$job.jobId; exit_code=$p.ExitCode; timed_out=$false; stdout=([string]$out).Trim(); stderr=([string]$err).Trim(); elapsed_sec=[math]::Round(((Get-Date)-$started).TotalSeconds,2) }
    }
} catch {
    LogLine "EXCEPTION: $($_.Exception.Message)"
    $result = @{ ok=$false; status='failed'; error=$_.Exception.Message; elapsed_sec=[math]::Round(((Get-Date)-$started).TotalSeconds,2) }
}

$result | ConvertTo-Json -Depth 10 | Out-File -FilePath $ResultFile -Encoding UTF8 -Force
LogLine "Finished: $($result | ConvertTo-Json -Compress -Depth 6)"
if ($result.ok) { exit 0 } else { exit 2 }
