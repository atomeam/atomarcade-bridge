# HomeBase AI Chat Runtime v0.1.2
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
$StrictSafety = ($env:HB_CHAT_STRICT_SAFETY -eq '1')

# Hard blocks only for explicit dangerous operator requests. Normal operational discussion is allowed.
$CriticalInputBlockedPatterns = @(
    '(?i)\b(show|print|dump|reveal|exfiltrate|send|copy)\b.*\b(secret|token|api[_ -]?key|password|credential)\b',
    '(?i)\b(delete|drop table|rm\s+-rf|format|wipe|destroy)\b.*\b(now|immediately|without approval|autonomously)\b',
    '(?i)\b(sudo|Invoke-Expression|iex|curl\s+.*\|\s*(bash|sh|pwsh))\b',
    '(?i)\b(loop forever|autonomous loop|run continuously without approval)\b'
)

$AdvisoryOutputPatterns = @(
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

function Test-CriticalBlockedInput {
    param([string]$Text)
    foreach ($p in $CriticalInputBlockedPatterns) {
        if ($Text -match $p) { return "blocked critical pattern: $p" }
    }
    return $null
}

function Get-AdvisorySafetyNotes {
    param([string]$Text)
    $notes = @()
    foreach ($p in $AdvisoryOutputPatterns) {
        if ($Text -match $p) { $notes += $p }
    }
    return $notes
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
    return @{ reply = "HomeBase chat runtime is online in dry-run mode. You said: $Message`n`nI can see context sources: $($Context.sources -join ', '). I can answer freely here and propose actions, but I will not execute writes automatically."; proposals = @($proposal); safety_notes=@() }
}

function Invoke-OpenAICompatibleChat {
    param([string]$Message, [hashtable]$Context)
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'HB_AI_API_KEY or LLM_API_KEY is not set. Use dry-run provider or set an API key.' }

    $system = @"
You are HomeBase AI Chat Runtime v0.1.2 inside Atom's cockpit.
Use the provided HomeBase context to answer and help operate HomeBase.
Operating rules:
- This is a free-form chat interface. Answer the operator's actual message, not only the default/pinned prompt.
- You may answer operational questions directly and conversationally.
- You may propose concrete next actions.
- Do not claim an action was executed unless the operator shows execution output.
- Do not expose secrets, tokens, API keys, passwords, or credentials.
- Do not autonomously perform destructive deletes, billing changes, domain/DNS changes, public posts, or broad shell commands.
- If suggesting a write/action, label it as a proposal and keep it low-risk unless the operator explicitly requests otherwise.
- HomeBase is not autonomous yet; keep execution gated through the existing command bus or explicit operator command.
- Return concise, useful operational guidance. Do not self-censor normal discussion of migration, providers, keys-as-concepts, billing-as-status, domains-as-roadmap, or deletes-as-risks.
Context:
$($Context.text)
"@

    $body = @{
        model = $Model
        temperature = 0.2
        messages = @(
            @{ role = 'system'; content = $system },
            @{ role = 'user'; content = $Message }
        )
    } | ConvertTo-Json -Depth 12

    $headers = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
    $res = Invoke-RestMethod -Method POST -Uri $Endpoint -Headers $headers -Body $body -TimeoutSec 45
    $text = [string]$res.choices[0].message.content

    $safetyNotes = Get-AdvisorySafetyNotes $text
    if ($StrictSafety -and $safetyNotes.Count -gt 0) {
        return @{ reply = "Blocked by HomeBase strict safety gate. Set HB_CHAT_STRICT_SAFETY=0 or unset it for normal proposal-first operation."; proposals = @(@{ proposal_id = "blocked-$(Get-Date -Format 'yyyyMMddHHmmss')"; summary = 'Blocked by strict safety mode'; intent = 'blocked'; writes_intent = 0; risk_level = 'high'; commands = @(); explanation = 'Strict mode blocked model output because it matched advisory safety terms.'; blocked_reason = ($safetyNotes -join '; ') }); safety_notes=$safetyNotes }
    }

    return @{ reply = $text; proposals = @(); safety_notes=$safetyNotes }
}

function Invoke-HomeBaseChat {
    param([hashtable]$Body)
    $message = [string]$Body.message
    if ([string]::IsNullOrWhiteSpace($message)) { return @{ ok=$false; error='missing message' } }
    $sessionId = if ($Body.session_id) { [string]$Body.session_id } else { "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    $userId = if ($Body.user_id) { [string]$Body.user_id } else { 'atom' }

    $blockedInput = Test-CriticalBlockedInput $message
    if ($blockedInput) {
        $result = @{ ok=$false; blocked=$true; reply="Blocked by HomeBase critical safety gate: $blockedInput"; proposals=@(); meta=@{ provider=$Provider; model=$Model; writes=0; strict_safety=$StrictSafety } }
    } else {
        $context = Get-HomeBaseChatContext
        if ($Provider -eq 'dry-run' -or $env:HB_AI_DRY_RUN -eq '1' -or $env:LLM_DRY_RUN -eq 'true') {
            $r = New-DryRunReply -Message $message -Context $context
        } else {
            $r = Invoke-OpenAICompatibleChat -Message $message -Context $context
        }
        $result = @{ ok=$true; reply=$r.reply; proposals=$r.proposals; requires_approval=(@($r.proposals).Count -gt 0); meta=@{ context_snapshot_id=$context.id; context_sources=$context.sources; provider=$Provider; model=$Model; writes=0; strict_safety=$StrictSafety; safety_notes=$r.safety_notes } }
        Write-ChatAudit -Row @{ ts=(Get-Date).ToString('o'); session_id=$sessionId; user_id=$userId; provider=$Provider; model=$Model; message_snippet=$message.Substring(0, [Math]::Min(240,$message.Length)); reply_snippet=([string]$r.reply).Substring(0, [Math]::Min(360,([string]$r.reply).Length)); proposals_count=@($r.proposals).Count; proposals=$r.proposals; context_sources=$context.sources; writes=0; strict_safety=$StrictSafety; safety_notes=$r.safety_notes }
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
:root{color-scheme:dark}*{box-sizing:border-box}body{font-family:ui-monospace,Consolas,monospace;background:#0b0d10;color:#e6e6e6;margin:0;padding:16px}.wrap{max-width:1000px;margin:0 auto}.top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;margin-bottom:12px}h1{font-size:18px;margin:0}.muted{color:#8b949e;font-size:12px}.chat{display:flex;flex-direction:column;gap:10px;min-height:280px;max-height:480px;overflow:auto;background:#090c10;border:1px solid #26313d;border-radius:10px;padding:12px}.msg{border:1px solid #26313d;border-radius:10px;padding:10px;white-space:pre-wrap}.user{background:#13233a;border-color:#1f6feb}.ai{background:#13171c}.sys{background:#1b1308;border-color:#8a6d00}.composer{display:flex;gap:8px;margin-top:10px;align-items:flex-end}textarea{flex:1;min-height:72px;max-height:180px;background:#13171c;color:#e6e6e6;border:1px solid #26313d;border-radius:8px;padding:10px;font-family:inherit}button{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:9px 12px;cursor:pointer}button:hover{background:#388bfd}.small{font-size:11px}.prop{border:1px solid #8a6d00;background:#2a2207;border-radius:8px;padding:10px;margin-top:8px}pre{white-space:pre-wrap;overflow:auto}.quick{display:flex;gap:6px;flex-wrap:wrap;margin:8px 0}.quick button{background:#21262d;color:#c9d1d9;padding:5px 8px;font-size:11px}</style></head><body><div class="wrap">
<div class="top"><div><h1>HomeBase AI Chat Runtime v0.1.2</h1><div class="muted">Free-form chat. Proposal-first. No autonomous writes.</div></div><div id="status" class="muted">checking...</div></div>
<div class="quick"><button onclick="seed('What is the current HomeBase state?')">State</button><button onclick="seed('What should we do next?')">Next</button><button onclick="seed('Help me debug the current blocker.')">Debug</button><button onclick="seed('List 5 safe AI-only migration actions.')">AI queue</button></div>
<div id="chat" class="chat"><div class="msg sys">Ready. Type anything below. Shift+Enter = new line. Enter = send.</div></div>
<div class="composer"><textarea id="msg" placeholder="Talk to HomeBase freely..."></textarea><button id="sendBtn" onclick="send()">Send</button></div>
<div id="props"></div>
</div><script>
const chat=document.getElementById('chat');const msg=document.getElementById('msg');const statusEl=document.getElementById('status');
function add(cls,text){const d=document.createElement('div');d.className='msg '+cls;d.textContent=text;chat.appendChild(d);chat.scrollTop=chat.scrollHeight;return d}
function seed(t){msg.value=t;msg.focus()}
msg.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();send()}})
async function loadStatus(){try{const r=await fetch('/api/chat/status');const j=await r.json();statusEl.textContent='provider='+j.provider+' model='+j.model+' writes='+j.writes+' version='+(j.version||'v0.1')}catch(e){statusEl.textContent='status unavailable'}}
async function send(){const message=msg.value.trim();if(!message)return;msg.value='';add('user',message);const holder=add('ai','Thinking...');document.getElementById('sendBtn').disabled=true;try{const r=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message,user_id:'atom',session_id:'homebase-ui'})});const j=await r.json();holder.textContent=j.reply||JSON.stringify(j,null,2);document.getElementById('props').innerHTML=(j.proposals||[]).map(p=>'<div class="prop"><b>'+p.summary+'</b><br>risk: '+p.risk_level+' | writes_intent: '+p.writes_intent+'<br><pre>'+JSON.stringify(p,null,2)+'</pre><button disabled title="proposal only">Create command row (disabled)</button></div>').join('');if(j.meta){statusEl.textContent='provider='+j.meta.provider+' model='+j.meta.model+' writes='+j.meta.writes+' strict='+j.meta.strict_safety}}catch(e){holder.textContent='Error: '+e.message}finally{document.getElementById('sendBtn').disabled=false;msg.focus()}}
loadStatus();msg.focus();
</script></body></html>
'@

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "HomeBase AI Chat Runtime v0.1.2 listening on http://localhost:$Port/"
Write-Host "Provider=$Provider Model=$Model AuditLog=$AuditLog StrictSafety=$StrictSafety"
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        $method = $ctx.Request.HttpMethod
        try {
            if ($method -eq 'GET' -and $path -eq '/') { Write-TextResponse -Context $ctx -Text $ChatHtml }
            elseif ($method -eq 'GET' -and $path -eq '/api/chat/status') { Write-JsonResponse -Context $ctx -Object @{ ok=$true; provider=$Provider; model=$Model; port=$Port; audit_log=$AuditLog; writes=0; strict_safety=$StrictSafety; version='v0.1.2' } }
            elseif ($method -eq 'POST' -and $path -eq '/api/chat') { $body = Read-JsonBody $ctx; Write-JsonResponse -Context $ctx -Object (Invoke-HomeBaseChat -Body $body) }
            else { Write-JsonResponse -Context $ctx -Status 404 -Object @{ ok=$false; error='not found'; path=$path } }
        } catch { Write-JsonResponse -Context $ctx -Status 500 -Object @{ ok=$false; error=$_.Exception.Message } }
    }
} finally { $listener.Stop(); $listener.Close() }
