# Ensures HomeBase supports Notion -> HomeBase -> Viktor commands.
# Adds a safe allowlisted Bridge Command target:
#   Kind: viktor
#   Command: run
#   Args: { "script": "viktor/scripts/test.py", "args": [] }
# Also supports Command: viktor.run by remapping it to Kind=viktor / Command=run.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HomeBasePath = Join-Path $RepoRoot 'homebase.ps1'
$ViktorRoot = Join-Path $RepoRoot 'viktor'
$ViktorScripts = Join-Path $ViktorRoot 'scripts'

if (-not (Test-Path $HomeBasePath)) { throw "homebase.ps1 not found at $HomeBasePath" }
New-Item -ItemType Directory -Path $ViktorScripts -Force | Out-Null

$text = Get-Content -Path $HomeBasePath -Raw
$changed = $false

function Replace-Once {
    param([string]$Needle, [string]$Replacement)
    if ($script:text.Contains($Needle)) {
        $script:text = $script:text.Replace($Needle, $Replacement)
        $script:changed = $true
        return $true
    }
    return $false
}

# 1) Curator allowlist: add viktor kind.
if ($text -notmatch "'viktor'\s*=\s*\$true") {
    $needle = "    'notion-log'  = `$true`r`n}"
    if (-not (Replace-Once $needle "    'notion-log'  = `$true`r`n    'viktor'      = `$true`r`n}")) {
        $needleLf = "    'notion-log'  = `$true`n}"
        [void](Replace-Once $needleLf "    'notion-log'  = `$true`n    'viktor'      = `$true`n}")
    }
}

# 2) Config block.
if ($text -notmatch '\$VIKTOR_ROOT\s*=') {
    $needle = "$REPO_ROOT = $PSScriptRoot"
    $replacement = @'
$REPO_ROOT = $PSScriptRoot

# --- Viktor command target ---
# Local-first tool root for Notion -> HomeBase -> Viktor runs.
# Scripts are restricted to this root unless ATOMARCADE_VIKTOR_ALLOW_OUTSIDE_ROOT=1.
$VIKTOR_ROOT            = if ($env:ATOMARCADE_VIKTOR_ROOT) { $env:ATOMARCADE_VIKTOR_ROOT } else { Join-Path $REPO_ROOT 'viktor' }
$VIKTOR_SCRIPTS_ROOT    = Join-Path $VIKTOR_ROOT 'scripts'
$VIKTOR_DEFAULT_TIMEOUT = if ($env:ATOMARCADE_VIKTOR_TIMEOUT_SEC) { [int]$env:ATOMARCADE_VIKTOR_TIMEOUT_SEC } else { 120 }
'@
    [void](Replace-Once $needle $replacement)
}

# 3) Helper functions before dispatcher.
if ($text -notmatch 'function Invoke-ViktorRun') {
    $helpers = @'

function Resolve-ViktorScriptPath {
    param([Parameter(Mandatory)][string]$Script)

    if ([string]::IsNullOrWhiteSpace($Script)) { throw 'viktor.run missing script' }

    $rootFull = [System.IO.Path]::GetFullPath($VIKTOR_SCRIPTS_ROOT)
    if (-not (Test-Path $rootFull)) { New-Item -ItemType Directory -Path $rootFull -Force | Out-Null }

    $candidate = if ([System.IO.Path]::IsPathRooted($Script)) {
        [System.IO.Path]::GetFullPath($Script)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $REPO_ROOT $Script))
    }

    $allowOutside = ($env:ATOMARCADE_VIKTOR_ALLOW_OUTSIDE_ROOT -eq '1')
    if (-not $allowOutside -and -not $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "viktor.run blocked: script must be under $rootFull. Set ATOMARCADE_VIKTOR_ALLOW_OUTSIDE_ROOT=1 to override."
    }
    if (-not (Test-Path $candidate)) { throw "viktor.run script not found: $candidate" }
    return $candidate
}

function Invoke-HomeBaseProcessCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 120,
        [string]$WorkingDirectory = $REPO_ROOT
    )

    $tmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ("homebase-viktor-{0}" -f ([guid]::NewGuid().ToString('N')))
    $stdout = "$tmpBase.out.txt"
    $stderr = "$tmpBase.err.txt"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    $outBuilder = [System.Text.StringBuilder]::new()
    $errBuilder = [System.Text.StringBuilder]::new()
    $p.add_OutputDataReceived({ if ($null -ne $_.Data) { [void]$outBuilder.AppendLine($_.Data) } })
    $p.add_ErrorDataReceived({ if ($null -ne $_.Data) { [void]$errBuilder.AppendLine($_.Data) } })

    $started = Get-Date
    [void]$p.Start()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    $exited = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        try { $p.Kill($true) } catch {}
        return @{ ok=$false; timed_out=$true; exit_code=$null; timeout_sec=$TimeoutSec; stdout=[string]$outBuilder; stderr=[string]$errBuilder; elapsed_sec=[math]::Round(((Get-Date)-$started).TotalSeconds,2) }
    }
    $p.WaitForExit()
    $exitCode = $p.ExitCode
    return @{ ok=($exitCode -eq 0); timed_out=$false; exit_code=$exitCode; timeout_sec=$TimeoutSec; stdout=([string]$outBuilder).Trim(); stderr=([string]$errBuilder).Trim(); elapsed_sec=[math]::Round(((Get-Date)-$started).TotalSeconds,2) }
}

function Invoke-ViktorRun {
    param([string]$ArgsJson)

    $payload = @{}
    if (-not [string]::IsNullOrWhiteSpace($ArgsJson)) {
        try { $payload = $ArgsJson | ConvertFrom-Json -AsHashtable } catch { return @{ ok=$false; error="viktor.run invalid Args JSON: $($_.Exception.Message)" } }
    }

    $script = [string]$payload.script
    if ([string]::IsNullOrWhiteSpace($script)) { return @{ ok=$false; error='viktor.run requires Args.script' } }

    $argList = @()
    if ($payload.args -is [System.Collections.IEnumerable] -and -not ($payload.args -is [string])) {
        foreach ($a in $payload.args) { $argList += [string]$a }
    } elseif ($payload.args) {
        $argList += [string]$payload.args
    }

    $timeout = $VIKTOR_DEFAULT_TIMEOUT
    if ($payload.timeout_sec) { $timeout = [int]$payload.timeout_sec }
    if ($timeout -lt 1) { $timeout = 1 }
    if ($timeout -gt 900) { $timeout = 900 }

    try { $resolvedScript = Resolve-ViktorScriptPath -Script $script } catch { return @{ ok=$false; blocked=$true; error=$_.Exception.Message } }

    $mode = if ($payload.mode) { [string]$payload.mode } else { 'python' }
    $filePath = $null
    $processArgs = @()

    switch ($mode) {
        'python' {
            $py = Get-Command python -ErrorAction SilentlyContinue
            if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
            if (-not $py) { return @{ ok=$false; error='python/py not found on PATH for viktor.run' } }
            $filePath = $py.Source
            $processArgs = @($resolvedScript) + $argList
        }
        'viktor-cli' {
            $vk = Get-Command viktor -ErrorAction SilentlyContinue
            if (-not $vk) { return @{ ok=$false; error='viktor CLI not found on PATH for viktor.run mode=viktor-cli' } }
            $filePath = $vk.Source
            $processArgs = @('run', $resolvedScript) + $argList
        }
        default { return @{ ok=$false; error="unsupported viktor.run mode '$mode'. Use python or viktor-cli." } }
    }

    Add-LogEntry -Kind 'VIKTOR' -Message "run $script mode=$mode timeout=${timeout}s" -Data @{ args=$argList }
    $run = Invoke-HomeBaseProcessCapture -FilePath $filePath -ArgumentList $processArgs -TimeoutSec $timeout -WorkingDirectory (Split-Path -Parent $resolvedScript)
    return @{
        ok = $run.ok
        command = 'viktor.run'
        mode = $mode
        script = $script
        resolved_script = $resolvedScript
        args = $argList
        exit_code = $run.exit_code
        timed_out = $run.timed_out
        timeout_sec = $run.timeout_sec
        elapsed_sec = $run.elapsed_sec
        stdout = $run.stdout
        stderr = $run.stderr
    }
}
'@
    $needle = "# ============================================================`r`n# Bridge Command dispatcher"
    if (-not (Replace-Once $needle ($helpers + "`r`n`r`n" + $needle))) {
        $needleLf = "# ============================================================`n# Bridge Command dispatcher"
        [void](Replace-Once $needleLf ($helpers + "`n`n" + $needleLf))
    }
}

# 4) Support Command=viktor.run by remapping to Kind=viktor, Command=run after Args parsing.
if ($text -notmatch "Command -eq 'viktor.run'") {
    $needle = @'
    if ($ArgsJson) {
        try { $argsObj = $ArgsJson | ConvertFrom-Json -AsHashtable } catch { $argsObj = @{} }
    }

    switch ($Kind) {
'@
    $replacement = @'
    if ($ArgsJson) {
        try { $argsObj = $ArgsJson | ConvertFrom-Json -AsHashtable } catch { $argsObj = @{} }
    }

    # Allow Notion rows to use either:
    #   Kind=viktor, Command=run
    # or the compact form:
    #   Command=viktor.run
    if ($Command -eq 'viktor.run') {
        $Kind = 'viktor'
        $Command = 'run'
    }

    switch ($Kind) {
'@
    [void](Replace-Once $needle $replacement)
}

# 5) Add dispatcher case.
if ($text -notmatch "'viktor'\s*\{") {
    $needle = @'
        'notion-log'  {
            Add-LogEntry -Kind 'NOTION_LOG' -Message "event=$Command"
            return Invoke-NotionLog -Event $Command -ArgsJson $ArgsJson
        }
        default { return @{ ok=$false; error="unknown kind: $Kind" } }
'@
    $replacement = @'
        'notion-log'  {
            Add-LogEntry -Kind 'NOTION_LOG' -Message "event=$Command"
            return Invoke-NotionLog -Event $Command -ArgsJson $ArgsJson
        }
        'viktor'      {
            switch ($Command) {
                'run' { return Invoke-ViktorRun -ArgsJson $ArgsJson }
                default { return @{ ok=$false; error="unknown viktor command: $Command" } }
            }
        }
        default { return @{ ok=$false; error="unknown kind: $Kind" } }
'@
    [void](Replace-Once $needle $replacement)
}

if ($changed) {
    Copy-Item $HomeBasePath "$HomeBasePath.bak-viktor-command" -Force
    Set-Content -Path $HomeBasePath -Value $text -Encoding UTF8
    Write-Host 'Installed HomeBase viktor.run Bridge Command target.'
} else {
    Write-Host 'HomeBase viktor.run Bridge Command target already installed.'
}

# Ensure starter files exist.
$testPy = Join-Path $ViktorScripts 'test.py'
if (-not (Test-Path $testPy)) {
@'
import json
import platform
import sys
from datetime import datetime, timezone

result = {
    "ok": True,
    "tool": "viktor.test",
    "message": "Hello from HomeBase -> Viktor script target",
    "python": sys.version,
    "platform": platform.platform(),
    "argv": sys.argv[1:],
    "ts": datetime.now(timezone.utc).isoformat(),
}
print(json.dumps(result, indent=2))
'@ | Set-Content -Path $testPy -Encoding UTF8
}

$configJson = Join-Path $ViktorRoot 'config.json'
if (-not (Test-Path $configJson)) {
@{
    version = 1
    scripts_root = 'viktor/scripts'
    default_mode = 'python'
    default_timeout_sec = 120
    command_examples = @(
        @{ Command='viktor.run'; Kind='viktor'; Args='{"script":"viktor/scripts/test.py","args":["--hello","homebase"],"mode":"python","timeout_sec":60}' }
    )
} | ConvertTo-Json -Depth 6 | Set-Content -Path $configJson -Encoding UTF8
}

Select-String -Path $HomeBasePath -Pattern "'viktor'","function Invoke-ViktorRun","viktor.run","Resolve-ViktorScriptPath" | Select-Object LineNumber, Line | Format-Table -AutoSize
