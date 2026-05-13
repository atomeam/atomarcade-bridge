# HomeBase AI Chat Runtime v0.1
# Purpose: sidecar chat endpoint for HomeBase. Proposal-first. No autonomous writes.
# Run: pwsh -File .\tools\homebase-ai-chat-runtime.ps1

param(
    [int]$Port = $(if ($env:HB_CHAT_PORT) { [int]$env:HB_CHAT_PORT } else { 8081 }),
    [string]$RepoRoot = $(Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$Provider = if ($env:HB_AI_PROVIDER) { $env:HB_AI_PROVIDER } elseif ($env:LLM_PROVIDER) { $env:LLM_PROVIDER } else { 'dry-run' }
$Model = if ($env:HB_AI_MODEL) { $env:HB_AI_MODEL } elseif ($env:LLM_MODEL) { $env:LLM_MODEL } else { 'mock-homebase-v0.1' }
$Endpoint = if ($env:HB_AI_ENDPOINT) { $env:HB_AI_ENDPOINT } elseif ($env:LLM_BASE_URL) { $env:LLM_BASE_URL.TrimEnd('/') + '/chat/completions' } else { 'https://api.openai.com/v1/chat/completions' }
$ApiKey = if ($env:HB_AI_API_KEY) { $env:HB_AI_API_KEY } elseif ($env:LLM_API_KEY) { $env:LLM_API_KEY } else { '' }
$AuditLog = if ($env:HB_CHAT_AUDIT_LOG_PATH) { $env:HB_CHAT_AUDIT_LOG_PATH } else { Join-Path $RepoRoot 'homebase-chat.jsonl' }
$MaxContextChars = if ($env:HB_CHAT_MAX_CONTEXT_CHARS) { [int]$env:HB_CHAT_MAX_CONTEXT_CHARS } else { 12000 }

$BlockedPatterns = @(
    '(?i)\b(secret|token|api[_ -]?key|password|credential)\b',
    '(?i)\b(billing|stripe live|domain|dns|public post|tweet|x\.com)\b',
    '(?i)\b(delete|drop table|rm\s+-rf|format|wipe|destructive)\b',
    '(?i)\b(sudo|Invoke-Expression|iex|curl\s+.*\|\s*(bash|sh|pwsh))\b',
    '(?i)\b(loop forever|autonomous loop|run continuously)\b'
)

function Write-ChatAudit {
    param([hashtable]$Row)
    try {
        $dir = Split-Path -Parent $AuditLog
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($Row | ConvertTo-Json -Depth 12 -Compress) | Out-File -FilePath $AuditLog -Encoding UTF8 -Append -Force
    } catch {}
}

function Read-JsonFileSafe {
    param([string]$Path, [int]$MaxChars = 6000)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $text = Get-Content -Path $Path -Raw -ErrorAction Stop
        if ($text.Length -gt $MaxChars) { return $text.Substring(0, $MaxChars) + " ...[truncated]" }
        return $text
    } catch { return $null }
}

function Get-RecentLinesSafe {
    param([string]$Path, [int]$Tail = 80, [int]$MaxChars = 6000)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $text = (Get-Content -Path $Path -Tail $Tail -ErrorAction Stop) -join "`n"
        if ($text.Length -gt $MaxChars) { return $text.Substring($text.Length - $MaxChars) }
        return $text
    } catch { return $null }
}

function Get-HomeBaseChatContext {
    $sources = @()
    $chunks = @()

    $workqueuePreview = Read-JsonFileSafe -Path (Join-Path $RepoRoot 'tools\homebase-workqueue-preview.json')
    if (-not $workqueuePreview) { $workqueuePreview = Read-JsonFileSafe -Path (Join-Path $RepoRoot 'tools\homebase-readonly-ingestion-workqueue-preview.json') }
    if ($workqueuePreview) { $sources += 'workqueue_preview'; $chunks += "## WorkQueue preview`n$workqueuePreview" }

    $profilePreview = Read-JsonFileSafe -Path (Join-Path $RepoRoot 'tools\homebase-readonly-ingestion-profiletemplate-preview.json')
    if ($profilePreview) { $sources += 'profiletemplate_preview'; $chunks += "## ProfileTemplate preview`n$profilePreview" }

    $logs = Get-RecentLinesSafe -Path (Join-Path $RepoRoot 'homebase-logs.jsonl') -Tail 80
    if ($logs) { $sources += 'homebase_jsonl'; $chunks += "## Recent HomeBase JSONL logs`n$logs" }

    $plainLog = Get-RecentLinesSafe -Path (Join-Path $RepoRoot 'homebase.log') -Tail 80
    if ($plainLog) { $sources += 'homebase_log'; $chunks += "## Recent HomeBase log`n$plainLog" }

    $context = ($chunks -join "`n`n")
    if ($context.Length -gt $MaxContextChars) { $context = $context.Substring(0, $MaxContextChars) + " ...[context truncated]" }

    return @{ id = "snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"; sources = $sources; text = $context }
}

function Test-BlockedText {
    param([string]$Text)
    foreach ($p in $BlockedPatterns) {
        if ($Text -match $p) { return "blocked pattern: $p" }
    }
    return $null
}

function New-DryRunReply {
    param([string]$Message, [hashtable]$Context)
    $proposal = [ordered]@{
        proposal_id = "p-$(Get-Date -Format 'yyyyMMddHHmmss')"
        summary = 'Review next HomeBase migration action'
        intent = 'review_next_safe_action'
        writes_intent = 0
        risk_level = 'low'
        commands = @(@{ type = 'observe'; payload = @{ note = 'Dry-run chat proposal only; no command row created automatically.' } })
        explanation = 'Dry-run provider is enabled, so this is a proposal-only mock response. No writes were performed.'
        blocked_reason = $null
    }
    return @{ reply = "HomeBase chat runtime is online in dry-run mode. I can see context sources: $($Context.sources -join ', '). I will propose actions only; I will not write without approval."; proposals = @($proposal) }
}

function Invoke-OpenAICompatibleChat {
    param([string]$Message, [hashtable]$Context)
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'HB_AI_API_KEY or LLM_API_KEY is not set. Use dry-run provider or set an API key.' }

    $system = @"
You are HomeBase AI Chat Runtime v0.1 inside Atom's cockpit.
Use the provided HomeBase context to answer.
Safety rules:
- Proposal-first only. Do not claim an action was executed.
- Never request or expose secrets, tokens, billing changes, domains, public posts, destructive deletes, broad shell, or autonomous loops.
- If suggesting an action, include low-risk command proposals only.
- All proposals must have writes_intent 0 unless the operator explicitly asks for a command row proposal.
- Return concise operational guidance.
Context:
$($Context.text)
"@

    $body = @{
        model = $Model
        temperature = 0.1
        messages = @(
            @{ role = 'system'; content = $system },
            @{ role = 'user'; content = $Message }
        )
    } | ConvertTo-Json -Depth 12

    $headers = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
    $res = Invoke-RestMethod -Method POST -Uri $Endpoint -Headers $headers -Body $body -TimeoutSec 45
    $text = [string]$res.choices[0].message.content

    $blocked = Test-BlockedText $text
    if ($blocked) {
        return @{ reply = "Blocked by HomeBase safety gate: $blocked"; proposals = @(@{ proposal_id = "blocked-$(Get-Date -Format 'yyyyMMddHHmmss')"; summary = 'Blocked unsafe proposal'; intent = 'blocked'; writes_intent = 0; risk_level = 'high'; commands = @(); explanation = 'The model output matched a blocked safety category.'; blocked_reason = $blocked }) }
    }

    return @{ reply = $text; proposals = @() }
}

function Invoke-HomeBaseChat {
    param([hashtable]$Body)
    $message = [string]$Body.message
    if ([string]::IsNullOrWhiteSpace($message)) { return @{ ok=$false; error='missing message' } }
    $sessionId = if ($Body.session_id) { [string]$Body.session_id } else { "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    $userId = if ($Body.user_id) { [string]$Body.user_id } else { 'atom' }

    $blockedInput = Test-BlockedText $message
    if ($blockedInput) {
        $result = @{ ok=$false; blocked=$true; reply="Blocked by HomeBase safety gate: $blockedInput"; proposals=@(); meta=@{ provider=$Provider; model=$Model } }
    } else {
        $context = Get-HomeBaseChatContext
        if ($Provider -eq 'dry-run' -or $env:HB_AI_DRY_RUN -eq '1' -or $env:LLM_DRY_RUN -eq 'true') {
            $r = New-DryRunReply -Message $message -Context $context
        } else {
            $r = Invoke-OpenAICompatibleChat -Message $message -Context $context
        }
        $result = @{ ok=$true; reply=$r.reply; proposals=$r.proposals; requires_approval=(@($r.proposals).Count -gt 0); meta=@{ context_snapshot_id=$context.id; context_sources=$context.sources; provider=$Provider; model=$Model; writes=0 } }
        Write-ChatAudit -Row @{ ts=(Get-Date).ToString('o'); session_id=$sessionId; user_id=$userId; provider=$Provider; model=$Model; message_snippet=$message.Substring(0, [Math]::Min(240,$message.Length)); reply_snippet=([string]$r.reply).Substring(0, [Math]::Min(360,([string]$r.reply).Length)); proposals_count=@($r.proposals).Count; proposals=$r.proposals; context_sources=$context.sources; writes=0 }
    }
    return $result
}

function Write-JsonResponse {
    param($Context, $Object, [int]$Status = 200)
    $json = $Object | ConvertTo-Json -Depth 14 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Write-TextResponse {
    param($Context, [string]$Text, [string]$ContentType = 'text/html; charset=utf-8')
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Read-JsonBody {
    param($Context)
    $reader = [IO.StreamReader]::new($Context.Request.InputStream, $Context.Request.ContentEncoding)
    $raw = $reader.ReadToEnd(); $reader.Close()
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return ($raw | ConvertFrom-Json -AsHashtable)
}

$ChatHtml = @'
<!doctype html><html><head><meta charset="utf-8"><title>HomeBase AI Chat</title><style>
body{font-family:ui-monospace,Consolas,monospace;background:#0b0d10;color:#e6e6e6;margin:0;padding:22px}textarea{width:100%;height:90px;background:#13171c;color:#e6e6e6;border:1px solid #26313d;border-radius:8px;padding:10px}button{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:8px 12px;margin-top:8px}pre{white-space:pre-wrap;background:#13171c;border:1px solid #26313d;border-radius:8px;padding:12px}.prop{border:1px solid #8a6d00;background:#2a2207;border-radius:8px;padding:10px;margin-top:8px}</style></head><body>
<h1>HomeBase AI Chat Runtime v0.1</h1><p>Proposal-first. No autonomous writes.</p><textarea id="msg">What should we do next for HomeBase migration?</textarea><br><button onclick="send()">Send</button><pre id="reply">Ready.</pre><div id="props"></div><script>
async function send(){document.getElementById('reply').textContent='Thinking...';const message=document.getElementById('msg').value;const r=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message,user_id:'atom',session_id:'homebase-ui'})});const j=await r.json();document.getElementById('reply').textContent=j.reply||JSON.stringify(j,null,2);document.getElementById('props').innerHTML=(j.proposals||[]).map(p=>'<div class="prop"><b>'+p.summary+'</b><br>risk: '+p.risk_level+' | writes_intent: '+p.writes_intent+'<br><pre>'+JSON.stringify(p,null,2)+'</pre><button disabled title="v0.1 proposal only">Create command row (disabled in v0.1)</button></div>').join('')}
</script></body></html>
'@

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "HomeBase AI Chat Runtime v0.1 listening on http://localhost:$Port/"
Write-Host "Provider=$Provider Model=$Model AuditLog=$AuditLog"
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        $method = $ctx.Request.HttpMethod
        try {
            if ($method -eq 'GET' -and $path -eq '/') { Write-TextResponse -Context $ctx -Text $ChatHtml }
            elseif ($method -eq 'GET' -and $path -eq '/api/chat/status') { Write-JsonResponse -Context $ctx -Object @{ ok=$true; provider=$Provider; model=$Model; port=$Port; audit_log=$AuditLog; writes=0 } }
            elseif ($method -eq 'POST' -and $path -eq '/api/chat') { $body = Read-JsonBody $ctx; Write-JsonResponse -Context $ctx -Object (Invoke-HomeBaseChat -Body $body) }
            else { Write-JsonResponse -Context $ctx -Status 404 -Object @{ ok=$false; error='not found'; path=$path } }
        } catch { Write-JsonResponse -Context $ctx -Status 500 -Object @{ ok=$false; error=$_.Exception.Message } }
    }
} finally { $listener.Stop(); $listener.Close() }
