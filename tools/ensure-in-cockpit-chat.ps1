# HomeBase v0.6.8.5 — native in-cockpit chat patcher
# Purpose: make AI chat run inside the main HomeBase cockpit on port 8080.
# This removes the fragile iframe dependency on localhost:8081 for the embedded app.
# Idempotent: injects/replaces the cockpit card, native chat functions, and routes.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HomeBasePath = Join-Path $RepoRoot 'homebase.ps1'

if (-not (Test-Path $HomeBasePath)) {
    Write-Host "homebase.ps1 not found at $HomeBasePath"
    exit 1
}

$text = Get-Content -Path $HomeBasePath -Raw

$nativeFunctions = @'

# ============================================================
# HomeBase Native AI Chat (v0.6.8.5)
# Runs directly on the main 8080 cockpit. No iframe, no 8081 dependency.
# Free-form chat. No autonomous writes. Provider controlled by HB_AI_* env vars.
# ============================================================
$HB_CHAT_VERSION = 'v0.6.8.5-native-chat'
$HB_AI_PROVIDER_NATIVE = if ($env:HB_AI_PROVIDER) { $env:HB_AI_PROVIDER } elseif ($env:LLM_PROVIDER) { $env:LLM_PROVIDER } else { 'dry-run' }
$HB_AI_MODEL_NATIVE = if ($env:HB_AI_MODEL) { $env:HB_AI_MODEL } elseif ($env:LLM_MODEL) { $env:LLM_MODEL } else { 'mock-homebase-v0.1' }
$HB_AI_ENDPOINT_NATIVE = if ($env:HB_AI_ENDPOINT) { $env:HB_AI_ENDPOINT } elseif ($env:LLM_BASE_URL) { $env:LLM_BASE_URL.TrimEnd('/') + '/chat/completions' } else { 'https://api.openai.com/v1/chat/completions' }
$HB_AI_KEY_NATIVE = if ($env:HB_AI_API_KEY) { $env:HB_AI_API_KEY } elseif ($env:LLM_API_KEY) { $env:LLM_API_KEY } else { '' }
$HB_CHAT_AUDIT_NATIVE = if ($env:HB_CHAT_AUDIT_LOG_PATH) { $env:HB_CHAT_AUDIT_LOG_PATH } else { Join-Path $REPO_ROOT 'homebase-chat.jsonl' }

function Write-NativeChatAudit {
    param([hashtable]$Row)
    try {
        $dir = Split-Path -Parent $HB_CHAT_AUDIT_NATIVE
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($Row | ConvertTo-Json -Depth 12 -Compress) | Out-File -FilePath $HB_CHAT_AUDIT_NATIVE -Encoding UTF8 -Append -Force
    } catch {}
}

function Get-HomeBaseNativeChatContext {
    $sources = @()
    $chunks = @()
    $paths = @(
        @{ name='workqueue_preview'; path=(Join-Path $REPO_ROOT 'tools\homebase-workqueue-preview.json') },
        @{ name='workqueue_preview'; path=(Join-Path $REPO_ROOT 'tools\homebase-readonly-ingestion-workqueue-preview.json') },
        @{ name='profiletemplate_preview'; path=(Join-Path $REPO_ROOT 'tools\homebase-readonly-ingestion-profiletemplate-preview.json') },
        @{ name='homebase_jsonl'; path=(Join-Path $REPO_ROOT 'homebase-logs.jsonl') },
        @{ name='homebase_log'; path=(Join-Path $REPO_ROOT 'homebase.log') }
    )
    foreach ($p in $paths) {
        if (Test-Path $p.path) {
            try {
                $raw = if ($p.name -like '*log*') { (Get-Content -Path $p.path -Tail 80 -ErrorAction Stop) -join "`n" } else { Get-Content -Path $p.path -Raw -ErrorAction Stop }
                if ($raw.Length -gt 5000) { $raw = $raw.Substring(0,5000) + ' ...[truncated]' }
                $sources += $p.name
                $chunks += "## $($p.name)`n$raw"
            } catch {}
        }
    }
    $ctx = ($chunks -join "`n`n")
    if ($ctx.Length -gt 12000) { $ctx = $ctx.Substring(0,12000) + ' ...[context truncated]' }
    return @{ id="native-$(Get-Date -Format 'yyyyMMdd-HHmmss')"; sources=$sources; text=$ctx }
}

function Get-HomeBaseNativeChatStatus {
    return @{
        ok = $true
        version = $HB_CHAT_VERSION
        mode = 'native-8080'
        provider = $HB_AI_PROVIDER_NATIVE
        model = $HB_AI_MODEL_NATIVE
        endpoint = $HB_AI_ENDPOINT_NATIVE
        key_set = -not [string]::IsNullOrWhiteSpace($HB_AI_KEY_NATIVE)
        writes = 0
        audit_log = $HB_CHAT_AUDIT_NATIVE
    }
}

function Invoke-HomeBaseNativeChat {
    param([hashtable]$Body)
    $message = [string]$Body.message
    if ([string]::IsNullOrWhiteSpace($message)) { return @{ ok=$false; error='missing message' } }
    $sessionId = if ($Body.session_id) { [string]$Body.session_id } else { 'homebase-native-ui' }
    $userId = if ($Body.user_id) { [string]$Body.user_id } else { 'atom' }
    $context = Get-HomeBaseNativeChatContext

    try {
        if ($HB_AI_PROVIDER_NATIVE -eq 'dry-run') {
            $reply = "HomeBase native chat is online on port 8080. You said: $message`n`nThis is dry-run mode. Set HB_AI_PROVIDER/HB_AI_MODEL/HB_AI_API_KEY/HB_AI_ENDPOINT to use a real provider."
        } else {
            if ([string]::IsNullOrWhiteSpace($HB_AI_KEY_NATIVE)) { throw 'HB_AI_API_KEY or LLM_API_KEY is not set for native chat.' }
            $system = @"
You are HomeBase Native AI inside Atom's cockpit.
Behave like a practical operator chat inside HomeBase, similar to Notion AI but local-first.
Answer the operator's actual message freely and conversationally.
You may help plan, debug, summarize state, and propose concrete next steps.
Do not claim you executed an action unless execution output is present.
Do not reveal or request secrets/API keys. Do not autonomously perform destructive actions, billing/domain changes, public posts, broad shell commands, or infinite loops.
Execution is not autonomous yet; actions should be proposals or explicit command-bus steps.
Keep answers concise and useful.
HomeBase context:
$($context.text)
"@
            $reqBody = @{
                model = $HB_AI_MODEL_NATIVE
                temperature = 0.2
                messages = @(
                    @{ role='system'; content=$system },
                    @{ role='user'; content=$message }
                )
            } | ConvertTo-Json -Depth 12
            $headers = @{ Authorization = "Bearer $HB_AI_KEY_NATIVE"; 'Content-Type' = 'application/json' }
            $res = Invoke-RestMethod -Method POST -Uri $HB_AI_ENDPOINT_NATIVE -Headers $headers -Body $reqBody -TimeoutSec 45
            $reply = [string]$res.choices[0].message.content
        }
        $result = @{ ok=$true; reply=$reply; proposals=@(); requires_approval=$false; meta=@{ version=$HB_CHAT_VERSION; mode='native-8080'; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; writes=0; context_snapshot_id=$context.id; context_sources=$context.sources } }
        Write-NativeChatAudit -Row @{ ts=(Get-Date).ToString('o'); session_id=$sessionId; user_id=$userId; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; mode='native-8080'; message_snippet=$message.Substring(0,[Math]::Min(240,$message.Length)); reply_snippet=([string]$reply).Substring(0,[Math]::Min(360,([string]$reply).Length)); writes=0; context_sources=$context.sources }
        return $result
    } catch {
        return @{ ok=$false; error=$_.Exception.Message; meta=@{ version=$HB_CHAT_VERSION; mode='native-8080'; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; writes=0 } }
    }
}
'@

if ($text -notmatch 'function Invoke-HomeBaseNativeChat') {
    $marker = '# ============================================================
# HTTP server
# ============================================================'
    if (-not $text.Contains($marker)) {
        Write-Host 'Could not find HTTP server insertion point.'
        exit 1
    }
    $text = $text.Replace($marker, $nativeFunctions + "`n" + $marker)
}

$chatCard = @'

  <div class="card" id="homebase-chat-card" style="grid-column:span 2">
    <h2>AI Chat <span class="status-pill pill-ok">native 8080</span></h2>
    <div class="small-muted" style="margin-bottom:10px">
      Native HomeBase chat. No iframe. No second localhost dependency. Provider uses <code>HB_AI_*</code>. Writes remain <code>0</code> until explicit command-bus execution is added.
    </div>
    <div id="hb-chat-status" class="small-muted" style="margin-bottom:8px">checking...</div>
    <div id="hb-chat-log" style="background:#090c10;border:1px solid #1f262e;border-radius:8px;padding:10px;min-height:220px;max-height:420px;overflow:auto;font-size:12px;white-space:pre-wrap"></div>
    <div style="display:flex;gap:6px;margin-top:8px;align-items:flex-end">
      <textarea id="hb-chat-input" placeholder="Talk to HomeBase freely..." style="flex:1;min-height:72px;background:#0b0d10;border:1px solid #1f262e;color:#e6e6e6;border-radius:6px;padding:8px;font-family:inherit"></textarea>
      <button onclick="hbSendChat()">Send</button>
    </div>
    <div style="margin-top:6px">
      <button class="mini" onclick="hbSeedChat('What is the current HomeBase state?')">State</button>
      <button class="mini" onclick="hbSeedChat('What should we do next?')">Next</button>
      <button class="mini" onclick="hbSeedChat('Help me debug the current blocker.')">Debug</button>
      <button class="mini" onclick="hbSeedChat('List 5 safe AI-only migration actions.')">AI queue</button>
    </div>
  </div>
'@

# Replace previous iframe card if it was already injected locally; otherwise insert after Command Bus.
$start = $text.IndexOf('  <div class="card" id="homebase-chat-card"')
if ($start -ge 0) {
    $next = $text.IndexOf('  <div class="card">', $start + 1)
    if ($next -lt 0) { $next = $text.IndexOf('  <div class="card" style="grid-column: span 2">', $start + 1) }
    if ($next -gt $start) {
        $text = $text.Substring(0,$start) + $chatCard + "`n" + $text.Substring($next)
    }
} else {
    $anchor = '  <div class="card" style="grid-column:span 2"><h2>Notion Command Bus</h2><div class="kv" id="bus-kv"></div></div>'
    if ($text.Contains($anchor)) {
        $text = $text.Replace($anchor, $anchor + $chatCard)
    } else {
        $fallback = '<div class="grid">'
        if (-not $text.Contains($fallback)) {
            Write-Host 'Could not find dashboard insertion point.'
            exit 1
        }
        $text = $text.Replace($fallback, $fallback + $chatCard)
    }
}

$routes = @'
                '^GET /api/chat/status$' { Write-Json -Context $ctx -Object (Get-HomeBaseNativeChatStatus); break }
                '^POST /api/chat$' {
                    $body = Read-JsonBody -Context $ctx
                    Write-Json -Context $ctx -Object (Invoke-HomeBaseNativeChat -Body $body); break
                }
'@
if ($text -notmatch '\^GET /api/chat/status\$') {
    $routeAnchor = "                '^GET /api/log$' { Write-Json -Context `$ctx -Object `$script:Log; break }"
    if (-not $text.Contains($routeAnchor)) {
        Write-Host 'Could not find route insertion point.'
        exit 1
    }
    $text = $text.Replace($routeAnchor, $routes + $routeAnchor)
}

$clientJs = @'

async function hbLoadChatStatus(){try{const s=await j('/api/chat/status');document.getElementById('hb-chat-status').textContent='provider='+s.provider+' model='+s.model+' mode='+s.mode+' writes='+s.writes+' version='+s.version}catch(e){document.getElementById('hb-chat-status').textContent='chat status error: '+e.message}}
function hbAppendChat(who,text){const el=document.getElementById('hb-chat-log');if(!el)return;el.textContent += (el.textContent?'\n\n':'') + who+': '+text;el.scrollTop=el.scrollHeight}
function hbSeedChat(t){const el=document.getElementById('hb-chat-input');el.value=t;el.focus()}
async function hbSendChat(){const input=document.getElementById('hb-chat-input');const msg=(input.value||'').trim();if(!msg)return;input.value='';hbAppendChat('Atom',msg);hbAppendChat('HomeBase','Thinking...');try{const r=await apiPost('/api/chat',{message:msg,user_id:'atom',session_id:'homebase-native-ui'});const log=document.getElementById('hb-chat-log');log.textContent=log.textContent.replace(/HomeBase: Thinking\.\.\.$/,'HomeBase: '+(r.reply||JSON.stringify(r,null,2)));if(r.meta){document.getElementById('hb-chat-status').textContent='provider='+r.meta.provider+' model='+r.meta.model+' mode='+r.meta.mode+' writes='+r.meta.writes+' version='+r.meta.version}}catch(e){hbAppendChat('Error',e.message)}}
'@
if ($text -notmatch 'function hbSendChat\(') {
    $scriptAnchor = 'refresh();
refreshAutomationCenter();'
    if (-not $text.Contains($scriptAnchor)) {
        Write-Host 'Could not find client JS insertion point.'
        exit 1
    }
    $text = $text.Replace($scriptAnchor, $clientJs + "`n" + 'hbLoadChatStatus();' + "`n" + $scriptAnchor)
}

Set-Content -Path $HomeBasePath -Value $text -Encoding UTF8
Write-Host 'Injected native HomeBase 8080 AI chat into homebase.ps1.'
