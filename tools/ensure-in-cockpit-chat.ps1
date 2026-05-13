# HomeBase v0.6.8.7 — force native real-AI chat patcher
# Purpose: make AI chat run inside the main HomeBase cockpit on port 8080.
# Single app. No iframe. No localhost:8081 dependency.
# Fixes: Ollama/OpenAI-compatible response parsing, hidden context timeout, and stuck Thinking UI.

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
# HomeBase Native Real AI Chat (v0.6.8.7)
# Runs directly on the main 8080 cockpit. No iframe, no 8081 dependency.
# Provider controlled by HB_AI_* env vars. Use Ollama/Groq/OpenAI-compatible endpoints.
# ============================================================
$HB_CHAT_VERSION = 'v0.6.8.7-native-real-ai-stable'
$HB_AI_PROVIDER_NATIVE = if ($env:HB_AI_PROVIDER) { $env:HB_AI_PROVIDER } elseif ($env:LLM_PROVIDER) { $env:LLM_PROVIDER } else { 'ollama' }
$HB_AI_MODEL_NATIVE = if ($env:HB_AI_MODEL) { $env:HB_AI_MODEL } elseif ($env:LLM_MODEL) { $env:LLM_MODEL } else { 'gpt-oss:20b' }
$HB_AI_ENDPOINT_NATIVE = if ($env:HB_AI_ENDPOINT) { $env:HB_AI_ENDPOINT } elseif ($env:LLM_BASE_URL) { $env:LLM_BASE_URL.TrimEnd('/') + '/chat/completions' } elseif ($HB_AI_PROVIDER_NATIVE -eq 'ollama') { 'http://localhost:11434/v1/chat/completions' } else { 'https://api.groq.com/openai/v1/chat/completions' }
$HB_AI_KEY_NATIVE = if ($env:HB_AI_API_KEY) { $env:HB_AI_API_KEY } elseif ($env:LLM_API_KEY) { $env:LLM_API_KEY } elseif ($HB_AI_PROVIDER_NATIVE -eq 'ollama') { 'ollama-local' } else { '' }
$HB_AI_TIMEOUT_NATIVE = if ($env:HB_AI_TIMEOUT_SEC) { [int]$env:HB_AI_TIMEOUT_SEC } else { 180 }
$HB_AI_INCLUDE_CONTEXT_NATIVE = ($env:HB_AI_INCLUDE_CONTEXT -eq '1')
$HB_CHAT_AUDIT_NATIVE = if ($env:HB_CHAT_AUDIT_LOG_PATH) { $env:HB_CHAT_AUDIT_LOG_PATH } else { Join-Path $REPO_ROOT 'homebase-chat.jsonl' }
$script:HB_NATIVE_CHAT_TURNS = if ($script:HB_NATIVE_CHAT_TURNS) { $script:HB_NATIVE_CHAT_TURNS } else { [System.Collections.Generic.List[hashtable]]::new() }

function Write-NativeChatAudit {
    param([hashtable]$Row)
    try {
        $dir = Split-Path -Parent $HB_CHAT_AUDIT_NATIVE
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($Row | ConvertTo-Json -Depth 12 -Compress) | Out-File -FilePath $HB_CHAT_AUDIT_NATIVE -Encoding UTF8 -Append -Force
    } catch {}
}

function Get-HomeBaseNativeChatContext {
    # Context is OFF by default because large hidden context caused simple messages like "hi" to time out.
    # Re-enable with HB_AI_INCLUDE_CONTEXT=1 after the provider path is stable.
    if (-not $HB_AI_INCLUDE_CONTEXT_NATIVE) {
        return @{ id="native-no-context-$(Get-Date -Format 'yyyyMMdd-HHmmss')"; sources=@(); text='' }
    }

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
                $raw = if ($p.name -like '*log*') { (Get-Content -Path $p.path -Tail 10 -ErrorAction Stop) -join "`n" } else { Get-Content -Path $p.path -Raw -ErrorAction Stop }
                if ($raw.Length -gt 800) { $raw = $raw.Substring(0,800) + ' ...[truncated]' }
                $sources += $p.name
                $chunks += "## $($p.name)`n$raw"
            } catch {}
        }
    }
    $ctx = ($chunks -join "`n`n")
    if ($ctx.Length -gt 2000) { $ctx = $ctx.Substring(0,2000) + ' ...[context truncated]' }
    return @{ id="native-$(Get-Date -Format 'yyyyMMdd-HHmmss')"; sources=$sources; text=$ctx }
}

function Get-HomeBaseNativeChatStatus {
    return @{
        ok = $true
        version = $HB_CHAT_VERSION
        mode = 'native-8080-real-ai'
        provider = $HB_AI_PROVIDER_NATIVE
        model = $HB_AI_MODEL_NATIVE
        endpoint = $HB_AI_ENDPOINT_NATIVE
        key_set = -not [string]::IsNullOrWhiteSpace($HB_AI_KEY_NATIVE)
        timeout_sec = $HB_AI_TIMEOUT_NATIVE
        context_enabled = $HB_AI_INCLUDE_CONTEXT_NATIVE
        dry_run = $false
        writes = 0
        audit_log = $HB_CHAT_AUDIT_NATIVE
        memory_turns = $script:HB_NATIVE_CHAT_TURNS.Count
    }
}

function Get-HomeBaseProviderReply {
    param($ResponseObject, [string]$RawPreview)

    $reply = $null

    if ($null -ne $ResponseObject.choices) {
        $choices = @($ResponseObject.choices)
        if ($choices.Count -gt 0) {
            $choice = $choices[0]
            if ($null -ne $choice.message -and -not [string]::IsNullOrWhiteSpace([string]$choice.message.content)) {
                $reply = [string]$choice.message.content
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$choice.text)) {
                $reply = [string]$choice.text
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($reply) -and -not [string]::IsNullOrWhiteSpace([string]$ResponseObject.response)) {
        $reply = [string]$ResponseObject.response
    }

    if ([string]::IsNullOrWhiteSpace($reply)) {
        throw "Provider returned an unrecognized or empty response shape. Raw preview: $RawPreview"
    }

    return $reply
}

function Invoke-HomeBaseNativeChat {
    param([hashtable]$Body)
    $message = [string]$Body.message
    if ([string]::IsNullOrWhiteSpace($message)) { return @{ ok=$false; error='missing message' } }
    $sessionId = if ($Body.session_id) { [string]$Body.session_id } else { 'homebase-native-ui' }
    $userId = if ($Body.user_id) { [string]$Body.user_id } else { 'atom' }
    $context = Get-HomeBaseNativeChatContext

    try {
        if ([string]::IsNullOrWhiteSpace($HB_AI_KEY_NATIVE)) { throw 'No real AI key configured. Set HB_AI_API_KEY or use local Ollama with HB_AI_PROVIDER=ollama.' }

        $system = @"
You are HomeBase AI running inside Atom's local HomeBase app.
Be a real assistant: answer the user's actual message directly, naturally, and usefully.
Use HomeBase context only if it is provided. Do not pretend you executed actions unless results are shown.
For now, you can talk, reason, plan, and propose actions. Do not autonomously execute commands.
Never reveal API keys, passwords, or secrets.
"@
        $messages = @(@{ role='system'; content=$system })
        if ($context.text) { $messages += @{ role='system'; content=("HomeBase context snapshot:`n" + $context.text) } }
        foreach ($turn in @($script:HB_NATIVE_CHAT_TURNS | Select-Object -Last 6)) {
            $messages += @{ role=$turn.role; content=$turn.content }
        }
        $messages += @{ role='user'; content=$message }

        $reqBody = @{
            model = $HB_AI_MODEL_NATIVE
            temperature = 0.3
            stream = $false
            messages = $messages
        } | ConvertTo-Json -Depth 12
        $headers = @{ Authorization = "Bearer $HB_AI_KEY_NATIVE"; 'Content-Type' = 'application/json' }

        $http = Invoke-WebRequest -Method POST -Uri $HB_AI_ENDPOINT_NATIVE -Headers $headers -Body $reqBody -TimeoutSec $HB_AI_TIMEOUT_NATIVE -ErrorAction Stop
        $raw = if ($null -ne $http.Content) { [string]$http.Content } else { '' }
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Provider returned an empty HTTP response.' }
        $preview = if ($raw.Length -gt 1200) { $raw.Substring(0,1200) + ' ...[truncated]' } else { $raw }
        $res = $raw | ConvertFrom-Json
        $reply = Get-HomeBaseProviderReply -ResponseObject $res -RawPreview $preview

        $script:HB_NATIVE_CHAT_TURNS.Add(@{ role='user'; content=$message }) | Out-Null
        $script:HB_NATIVE_CHAT_TURNS.Add(@{ role='assistant'; content=$reply }) | Out-Null
        while ($script:HB_NATIVE_CHAT_TURNS.Count -gt 12) { $script:HB_NATIVE_CHAT_TURNS.RemoveAt(0) }

        $result = @{ ok=$true; reply=$reply; proposals=@(); requires_approval=$false; meta=@{ version=$HB_CHAT_VERSION; mode='native-8080-real-ai'; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; writes=0; context_snapshot_id=$context.id; context_sources=$context.sources; context_enabled=$HB_AI_INCLUDE_CONTEXT_NATIVE; memory_turns=$script:HB_NATIVE_CHAT_TURNS.Count } }
        Write-NativeChatAudit -Row @{ ts=(Get-Date).ToString('o'); session_id=$sessionId; user_id=$userId; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; mode='native-8080-real-ai'; message_snippet=$message.Substring(0,[Math]::Min(240,$message.Length)); reply_snippet=([string]$reply).Substring(0,[Math]::Min(360,([string]$reply).Length)); writes=0; context_sources=$context.sources; context_enabled=$HB_AI_INCLUDE_CONTEXT_NATIVE }
        return $result
    } catch {
        return @{ ok=$false; error=$_.Exception.Message; meta=@{ version=$HB_CHAT_VERSION; mode='native-8080-real-ai'; provider=$HB_AI_PROVIDER_NATIVE; model=$HB_AI_MODEL_NATIVE; endpoint=$HB_AI_ENDPOINT_NATIVE; timeout_sec=$HB_AI_TIMEOUT_NATIVE; context_enabled=$HB_AI_INCLUDE_CONTEXT_NATIVE; writes=0 } }
    }
}
'@

# Remove any previous native function block and insert the current one.
$text = [regex]::Replace($text, '(?s)\n# ============================================================\r?\n# HomeBase Native.*?function Invoke-HomeBaseNativeChat \{.*?\n\}\r?\n(?=# ============================================================\r?\n# HTTP server)', "`n")
$marker = '# ============================================================
# HTTP server
# ============================================================'
if (-not $text.Contains($marker)) {
    Write-Host 'Could not find HTTP server insertion point.'
    exit 1
}
$text = $text.Replace($marker, $nativeFunctions + "`n" + $marker)

$chatCard = @'

  <div class="card" id="homebase-chat-card" style="grid-column:span 2">
    <h2>AI Chat <span class="status-pill pill-ok">native real AI</span></h2>
    <div class="small-muted" style="margin-bottom:10px">
      Native HomeBase chat on <code>localhost:8080</code>. No iframe. No 8081 dependency. Uses your configured real provider via <code>HB_AI_*</code>. Writes remain <code>0</code> until explicit command execution is added.
    </div>
    <div id="hb-chat-status" class="small-muted" style="margin-bottom:8px">checking...</div>
    <div id="hb-chat-log" style="background:#090c10;border:1px solid #1f262e;border-radius:8px;padding:10px;min-height:240px;max-height:460px;overflow:auto;font-size:12px;white-space:pre-wrap"></div>
    <div style="display:flex;gap:6px;margin-top:8px;align-items:flex-end">
      <textarea id="hb-chat-input" placeholder="Talk to HomeBase freely..." style="flex:1;min-height:72px;background:#0b0d10;border:1px solid #1f262e;color:#e6e6e6;border-radius:6px;padding:8px;font-family:inherit"></textarea>
      <button onclick="hbSendChat()">Send</button>
    </div>
    <div style="margin-top:6px">
      <button class="mini" onclick="hbSeedChat('What is the current HomeBase state?')">State</button>
      <button class="mini" onclick="hbSeedChat('What should we do next?')">Next</button>
      <button class="mini" onclick="hbSeedChat('Help me debug the current blocker.')">Debug</button>
      <button class="mini" onclick="hbSeedChat('Talk to me normally. What can you do from inside HomeBase right now?')">Talk</button>
    </div>
  </div>
'@

# Force-remove old iframe/native chat card. Then insert the clean native card after Command Bus.
$text = [regex]::Replace($text, '(?s)\s*<div class="card" id="homebase-chat-card".*?</div>\s*(?=\n\s*<div class="card")', "`n")
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

# Force-remove any previous native chat routes, then add clean routes before /api/log.
$text = [regex]::Replace($text, '(?m)^\s*''\^GET /api/chat/status\$''.*?\r?\n\s*''\^POST /api/chat\$'' \{\r?\n\s*\$body = Read-JsonBody -Context \$ctx\r?\n\s*Write-Json -Context \$ctx -Object \(Invoke-HomeBaseNativeChat -Body \$body\); break\r?\n\s*\}\r?\n', '')
$routes = @'
                '^GET /api/chat/status$' { Write-Json -Context $ctx -Object (Get-HomeBaseNativeChatStatus); break }
                '^POST /api/chat$' {
                    $body = Read-JsonBody -Context $ctx
                    Write-Json -Context $ctx -Object (Invoke-HomeBaseNativeChat -Body $body); break
                }
'@
$routeAnchor = "                '^GET /api/log$' { Write-Json -Context `$ctx -Object `$script:Log; break }"
if (-not $text.Contains($routeAnchor)) {
    Write-Host 'Could not find route insertion point.'
    exit 1
}
$text = $text.Replace($routeAnchor, $routes + $routeAnchor)

# Force-remove previous hb chat client functions, then add clean functions before refresh().
$text = [regex]::Replace($text, '(?s)\nasync function hbLoadChatStatus\(\).*?async function hbSendChat\(\).*?\}\r?\n', "`n")
$text = $text.Replace('hbLoadChatStatus();' + "`n", '')
$clientJs = @'

async function hbLoadChatStatus(){try{const s=await j('/api/chat/status');document.getElementById('hb-chat-status').textContent='provider='+s.provider+' model='+s.model+' mode='+s.mode+' writes='+s.writes+' version='+s.version+' key_set='+s.key_set+' context='+s.context_enabled+' timeout='+s.timeout_sec+'s'}catch(e){document.getElementById('hb-chat-status').textContent='chat status error: '+e.message}}
function hbAppendChat(who,text){const el=document.getElementById('hb-chat-log');if(!el)return;el.textContent += (el.textContent?'\n\n':'') + who+': '+text;el.scrollTop=el.scrollHeight}
function hbSeedChat(t){const el=document.getElementById('hb-chat-input');el.value=t;el.focus()}
function hbReplaceThinking(text){const log=document.getElementById('hb-chat-log');if(!log)return;const replacement='HomeBase: '+text;if(log.textContent.match(/HomeBase: Thinking\.\.\.$/)){log.textContent=log.textContent.replace(/HomeBase: Thinking\.\.\.$/,replacement)}else{hbAppendChat('HomeBase',text)}log.scrollTop=log.scrollHeight}
async function hbChatPost(body){const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),190000);try{const r=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{}),signal:controller.signal});const text=await r.text();try{return JSON.parse(text)}catch(e){return {ok:false,error:'HomeBase returned non-JSON response: '+text.slice(0,500)}}}catch(e){return {ok:false,error:(e.name==='AbortError'?'Browser timed out waiting for HomeBase chat after 190s':(e.message||String(e)))}}finally{clearTimeout(timer)}}
async function hbSendChat(){const input=document.getElementById('hb-chat-input');const msg=(input.value||'').trim();if(!msg)return;input.value='';hbAppendChat('Atom',msg);hbAppendChat('HomeBase','Thinking...');const r=await hbChatPost({message:msg,user_id:'atom',session_id:'homebase-native-ui'});hbReplaceThinking(r.reply||('ERROR: '+(r.error||JSON.stringify(r,null,2))));if(r.meta){document.getElementById('hb-chat-status').textContent='provider='+r.meta.provider+' model='+r.meta.model+' mode='+r.meta.mode+' writes='+r.meta.writes+' version='+r.meta.version+' memory='+(r.meta.memory_turns||0)+' context='+r.meta.context_enabled+' timeout='+(r.meta.timeout_sec||'?')+'s'}}
'@
$scriptAnchor = 'refresh();
refreshAutomationCenter();'
if (-not $text.Contains($scriptAnchor)) {
    Write-Host 'Could not find client JS insertion point.'
    exit 1
}
$text = $text.Replace($scriptAnchor, $clientJs + "`n" + 'hbLoadChatStatus();' + "`n" + $scriptAnchor)

Set-Content -Path $HomeBasePath -Value $text -Encoding UTF8
Write-Host 'Forced stable native real-AI HomeBase chat into homebase.ps1; context defaults off; stuck Thinking fixed.'
