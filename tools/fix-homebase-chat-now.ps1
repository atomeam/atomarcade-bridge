# One-shot HomeBase chat repair
# Purpose: isolate and fix the current "Thinking..." loop without relying on the launcher.
# Usage from repo root:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\fix-homebase-chat-now.ps1 -Start
# Optional smoke test mode, bypasses provider entirely:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\fix-homebase-chat-now.ps1 -Smoke -Start

param(
    [switch]$Smoke,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HomeBasePath = Join-Path $RepoRoot 'homebase.ps1'
$EnsurePath = Join-Path $PSScriptRoot 'ensure-in-cockpit-chat.ps1'

function Say($m) { Write-Host "[homebase-chat-fix] $m" }

if (-not (Test-Path $HomeBasePath)) { throw "homebase.ps1 not found at $HomeBasePath" }
if (-not (Test-Path $EnsurePath)) { throw "ensure-in-cockpit-chat.ps1 not found at $EnsurePath" }

Say 'Setting known-good Ollama Cloud environment variables.'
[Environment]::SetEnvironmentVariable('HB_AI_PROVIDER', 'ollama', 'User')
[Environment]::SetEnvironmentVariable('HB_AI_ENDPOINT', 'https://ollama.com/v1/chat/completions', 'User')
[Environment]::SetEnvironmentVariable('HB_AI_MODEL', 'gemma4:31b', 'User')
[Environment]::SetEnvironmentVariable('HB_AI_TIMEOUT_SEC', '180', 'User')
[Environment]::SetEnvironmentVariable('HB_AI_INCLUDE_CONTEXT', $null, 'User')

$ollamaKey = [Environment]::GetEnvironmentVariable('OLLAMA_API_KEY','User')
if (-not [string]::IsNullOrWhiteSpace($ollamaKey)) {
    [Environment]::SetEnvironmentVariable('HB_AI_API_KEY', $ollamaKey, 'User')
    $env:HB_AI_API_KEY = $ollamaKey
}

$env:HB_AI_PROVIDER = 'ollama'
$env:HB_AI_ENDPOINT = 'https://ollama.com/v1/chat/completions'
$env:HB_AI_MODEL = 'gemma4:31b'
$env:HB_AI_TIMEOUT_SEC = '180'
Remove-Item Env:\HB_AI_INCLUDE_CONTEXT -ErrorAction SilentlyContinue
if ($Smoke) {
    [Environment]::SetEnvironmentVariable('HB_AI_SMOKE_TEST', '1', 'User')
    $env:HB_AI_SMOKE_TEST = '1'
    Say 'Smoke mode enabled: /api/chat will return OK without calling Ollama.'
} else {
    [Environment]::SetEnvironmentVariable('HB_AI_SMOKE_TEST', $null, 'User')
    Remove-Item Env:\HB_AI_SMOKE_TEST -ErrorAction SilentlyContinue
}

Say 'Stopping stale HomeBase PowerShell processes.'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('pwsh.exe','powershell.exe') -and $_.CommandLine -match 'homebase' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Say 'Running canonical native chat patcher.'
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $EnsurePath | Write-Host

Say 'Applying emergency smoke-test and Invoke-RestMethod provider patch.'
$text = Get-Content -Path $HomeBasePath -Raw
Copy-Item $HomeBasePath "$HomeBasePath.bak-chat-fix-now" -Force

# Add smoke-test bypass immediately before context loading. This proves the UI + /api/chat route independently from Ollama.
$contextNeedle = '    $context = Get-HomeBaseNativeChatContext'
$smokeBlock = @'
    if ($env:HB_AI_SMOKE_TEST -eq '1') {
        return @{
            ok = $true
            reply = 'OK - HomeBase /api/chat smoke test works. Ollama was not called.'
            proposals = @()
            requires_approval = $false
            meta = @{
                version = $HB_CHAT_VERSION
                mode = 'native-8080-smoke-test'
                provider = 'smoke-test'
                model = 'none'
                writes = 0
                context_enabled = $false
                timeout_sec = $HB_AI_TIMEOUT_NATIVE
            }
        }
    }

    $context = Get-HomeBaseNativeChatContext
'@
if ($text.Contains($contextNeedle) -and -not $text.Contains('HomeBase /api/chat smoke test works')) {
    $text = $text.Replace($contextNeedle, $smokeBlock)
}

# Use Invoke-RestMethod like the already-proven direct Ollama Cloud test, not Invoke-WebRequest.
$providerRegex = '(?s)        \$http = Invoke-WebRequest -Method POST -Uri \$HB_AI_ENDPOINT_NATIVE -Headers \$headers -Body \$reqBody -TimeoutSec \$HB_AI_TIMEOUT_NATIVE -ErrorAction Stop\r?\n        \$raw = if \(\$null -ne \$http\.Content\) \{ \[string\]\$http\.Content \} else \{ '''' \}\r?\n        if \(\[string\]::IsNullOrWhiteSpace\(\$raw\)\) \{ throw ''Provider returned an empty HTTP response\.'' \}\r?\n        \$preview = if \(\$raw\.Length -gt 1200\) \{ \$raw\.Substring\(0,1200\) \+ '' \.\.\.\[truncated\]'' \} else \{ \$raw \}\r?\n        \$res = \$raw \| ConvertFrom-Json\r?\n        \$reply = Get-HomeBaseProviderReply -ResponseObject \$res -RawPreview \$preview'
$providerReplacement = @'
        Write-NativeChatAudit -Row @{ ts=(Get-Date).ToString('o'); event='provider_call_start'; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; endpoint=$HB_AI_ENDPOINT_NATIVE; timeout_sec=$HB_AI_TIMEOUT_NATIVE; context_enabled=$HB_AI_INCLUDE_CONTEXT_NATIVE }
        $res = Invoke-RestMethod -Method POST -Uri $HB_AI_ENDPOINT_NATIVE -Headers $headers -Body $reqBody -TimeoutSec $HB_AI_TIMEOUT_NATIVE -ErrorAction Stop
        $preview = ($res | ConvertTo-Json -Depth 20 -Compress)
        if ($preview.Length -gt 1200) { $preview = $preview.Substring(0,1200) + ' ...[truncated]' }
        $reply = Get-HomeBaseProviderReply -ResponseObject $res -RawPreview $preview
        Write-NativeChatAudit -Row @{ ts=(Get-Date).ToString('o'); event='provider_call_done'; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; reply_len=([string]$reply).Length }
'@
$text = [regex]::Replace($text, $providerRegex, $providerReplacement)

Set-Content -Path $HomeBasePath -Value $text -Encoding UTF8

Say 'Verification lines:'
Select-String -Path $HomeBasePath -Pattern 'v0.6.8.7-native-real-ai-stable','HomeBase /api/chat smoke test works','Invoke-RestMethod -Method POST','provider_call_start','hbReplaceThinking','HB_AI_INCLUDE_CONTEXT' |
    Select-Object LineNumber, Line |
    Format-Table -AutoSize

if ($Start) {
    Say 'Starting HomeBase directly from patched homebase.ps1.'
    Start-Process pwsh -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$HomeBasePath) -WindowStyle Normal
    Start-Sleep -Seconds 5
    Say 'Current /api/chat/status:'
    try {
        Invoke-RestMethod http://localhost:8080/api/chat/status -TimeoutSec 10 | ConvertTo-Json -Depth 10 | Write-Host
    } catch {
        Say "Could not read /api/chat/status yet: $($_.Exception.Message)"
    }
}

Say 'Done.'
