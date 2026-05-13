# Adds a visible VIKTOR panel + proxy endpoints to the single-file HomeBase cockpit.
# This is intentionally native JS/HTML (not React) because current HomeBase is a single PowerShell-served page.

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$HomeBasePath = Join-Path $RepoRoot 'homebase.ps1'
if (-not (Test-Path $HomeBasePath)) { throw "homebase.ps1 not found at $HomeBasePath" }

$text = Get-Content -Path $HomeBasePath -Raw
$changed = $false
function R([string]$n,[string]$r){ if($script:text.Contains($n)){ $script:text=$script:text.Replace($n,$r); $script:changed=$true; return $true}; return $false }

# Add backend helper functions before PWA block.
if ($text -notmatch 'function Get-ViktorStatus') {
$helpers = @'

function Get-ViktorStatus {
    $root = if ($VIKTOR_ROOT) { $VIKTOR_ROOT } else { Join-Path $REPO_ROOT 'viktor' }
    $scripts = Join-Path $root 'scripts'
    $queue = Join-Path $root 'queue'
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    $vk = Get-Command viktor -ErrorAction SilentlyContinue
    $recent = @()
    if (Test-Path $queue) {
        $recent = Get-ChildItem -Path $queue -Filter '*.result.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
                try { Get-Content -Raw -Path $_.FullName | ConvertFrom-Json } catch { @{ ok=$false; error=$_.Exception.Message; file=$_.FullName } }
            }
    }
    return @{
        ok = $true
        root = $root
        scripts_root = $scripts
        queue_root = $queue
        python_found = [bool]$py
        python_path = if ($py) { $py.Source } else { $null }
        viktor_cli_found = [bool]$vk
        viktor_cli_path = if ($vk) { $vk.Source } else { $null }
        recent_results = $recent
    }
}

function Invoke-ViktorProxy {
    param([hashtable]$Body)
    if ($null -eq $Body) { $Body = @{} }
    $text = [string]$Body.text
    if ([string]::IsNullOrWhiteSpace($text)) { return @{ ok=$false; error='missing text' } }

    $script = if ($Body.script) { [string]$Body.script } else { 'viktor/scripts/test.py' }
    $argsObj = @{ script=$script; args=@('--chat', $text); mode='python'; timeout_sec=60 } | ConvertTo-Json -Depth 8
    $result = Invoke-ViktorRun -ArgsJson $argsObj
    $reply = if ($result.stdout) { [string]$result.stdout } elseif ($result.stderr) { [string]$result.stderr } else { ($result | ConvertTo-Json -Compress -Depth 6) }
    return @{ ok=$result.ok; reply=$reply; raw=$result }
}
'@
$needle = "# ============================================================`r`n# PWA manifest"
if (-not (R $needle ($helpers + "`r`n`r`n" + $needle))) {
  $needleLf = "# ============================================================`n# PWA manifest"
  [void](R $needleLf ($helpers + "`n`n" + $needleLf))
}
}

# Add UI option to dropdown.
if ($text -notmatch '<option>viktor</option>') {
  $text = $text.Replace('<option>curator</option><option>system</option><option>git-pull</option><option>notion-log</option>', '<option>curator</option><option>system</option><option>git-pull</option><option>notion-log</option><option>viktor</option>')
  $changed = $true
}

# Add VIKTOR card after Notion Command Bus card.
if ($text -notmatch 'id="viktor-chat-log"') {
$card = @'

  <div class="card" style="grid-column:span 2">
    <h2>VIKTOR <span id="viktor-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="kv" id="viktor-kv"></div>
    <div style="margin-top:10px">
      <button onclick="queueViktorTest()">Queue Viktor test</button>
      <button onclick="refreshViktor()">Refresh Viktor</button>
    </div>
    <div style="margin-top:12px" class="small-muted">VIKTOR chat proxy</div>
    <div id="viktor-chat-log" class="mini-list" style="margin-top:6px"></div>
    <div class="queue-form" style="margin-top:8px">
      <input id="viktor-chat-input" type="text" placeholder="Ask Viktor / run local app proxy..."/>
      <button onclick="sendViktorChat()">Send to Viktor</button>
    </div>
  </div>
'@
$needle = '  <div class="card" style="grid-column:span 2"><h2>Notion Command Bus</h2><div class="kv" id="bus-kv"></div></div>'
[void](R $needle ($needle + $card))
}

# Add JS functions before refreshAutomationCenter.
if ($text -notmatch 'async function refreshViktor') {
$js = @'
async function refreshViktor(){
  try{
    const v=await j('/api/viktor/status');
    setPill('viktor-pill',v.python_found||v.viktor_cli_found?'ok':'warn',v.python_found||v.viktor_cli_found?'ready':'needs setup');
    kv(document.getElementById('viktor-kv'),{
      'Python':v.python_found?shortText(v.python_path,70):'not found',
      'Viktor CLI':v.viktor_cli_found?shortText(v.viktor_cli_path,70):'not found',
      'Scripts':shortText(v.scripts_root,80),
      'Queue':shortText(v.queue_root,80),
      'Recent jobs':(v.recent_results||[]).length
    });
  }catch(e){setPill('viktor-pill','bad','error')}
}
async function queueViktorTest(){
  const args='{"script":"viktor/scripts/test.py","args":["--hello","homebase"],"mode":"python","timeout_sec":60}';
  const r=await apiPost('/api/commands/queue',{command:'viktor.run',kind:'viktor',risk:'low',args:args,origin:'cockpit',trigger:'viktor_test_button'});
  if(r.ok){setTimeout(refreshAutomationCenter,500);setTimeout(refreshViktor,1000)}else{alert('Viktor queue failed: '+(r.error||r.reason||'unknown'))}
}
async function sendViktorChat(){
  const input=document.getElementById('viktor-chat-input'); const log=document.getElementById('viktor-chat-log');
  const msg=(input.value||'').trim(); if(!msg)return; input.value='';
  log.innerHTML+=`<div class="mini-row"><div class="mini-title">You</div><div class="mini-meta">${esc(msg)}</div></div>`;
  const r=await apiPost('/api/viktor/proxy',{text:msg});
  log.innerHTML+=`<div class="mini-row ${r.ok?'':'card-error'}"><div class="mini-title">VIKTOR</div><div class="mini-meta">${esc(r.reply||r.error||'no reply')}</div></div>`;
}

'@
$needle = 'async function refreshAutomationCenter(){'
[void](R $needle ($js + $needle))
}

# Make refresh calls include Viktor.
if ($text -notmatch 'refreshViktor\(\);\nrefresh\(\);') {
  $text = $text.Replace('refresh();
refreshAutomationCenter();', 'refreshViktor();
refresh();
refreshAutomationCenter();')
  $changed = $true
}
if ($text -notmatch 'setInterval\(refreshViktor,30000\)') {
  $text = $text.Replace('setInterval(refreshAutomationCenter,30000);', 'setInterval(refreshAutomationCenter,30000);
setInterval(refreshViktor,30000);')
  $changed = $true
}

# Add API endpoints before /api/notion/health.
if ($text -notmatch '\^GET /api/viktor/status\$') {
$routes = @'
                '^GET /api/viktor/status$' { Write-Json -Context $ctx -Object (Get-ViktorStatus); break }
                '^POST /api/viktor/test$' {
                    $argsJson = '{"script":"viktor/scripts/test.py","args":["--hello","homebase"],"mode":"python","timeout_sec":60}'
                    Write-Json -Context $ctx -Object (Invoke-ViktorRun -ArgsJson $argsJson); break
                }
                '^POST /api/viktor/proxy$' {
                    $body = Read-JsonBody -Context $ctx
                    Write-Json -Context $ctx -Object (Invoke-ViktorProxy -Body $body); break
                }

'@
$needle = "                '^GET /api/notion/health$'"
[void](R $needle ($routes + $needle))
}

if ($changed) {
  Copy-Item $HomeBasePath "$HomeBasePath.bak-viktor-ui" -Force
  Set-Content -Path $HomeBasePath -Value $text -Encoding UTF8
  Write-Host 'Installed VIKTOR cockpit panel and proxy endpoints.'
} else { Write-Host 'VIKTOR cockpit panel already installed.' }

Select-String -Path $HomeBasePath -Pattern '/api/viktor/status','/api/viktor/proxy','viktor-chat-log','refreshViktor','<option>viktor</option>' | Select-Object LineNumber, Line | Format-Table -AutoSize
