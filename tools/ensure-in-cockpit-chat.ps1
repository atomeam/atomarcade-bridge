# HomeBase v0.6.8.2 — in-cockpit chat embed patcher
# Purpose: make the AI Chat Runtime visible inside the main HomeBase cockpit.
# This script is idempotent and only injects the card once.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HomeBasePath = Join-Path $RepoRoot 'homebase.ps1'

if (-not (Test-Path $HomeBasePath)) {
    Write-Host "homebase.ps1 not found at $HomeBasePath"
    exit 1
}

$text = Get-Content -Path $HomeBasePath -Raw

if ($text -match 'id="homebase-chat-card"') {
    Write-Host 'HomeBase cockpit chat card already present.'
    exit 0
}

$chatCard = @'

  <div class="card" id="homebase-chat-card" style="grid-column:span 2">
    <h2>AI Chat Runtime <span class="status-pill pill-ok">8081</span></h2>
    <div class="small-muted" style="margin-bottom:10px">
      Embedded HomeBase AI Chat. Runtime is served by <code>tools/homebase-ai-chat-runtime.ps1</code> on <code>localhost:8081</code>. Provider is controlled by <code>HB_AI_*</code> environment variables.
    </div>
    <iframe src="http://localhost:8081/" title="HomeBase AI Chat" style="width:100%;height:520px;border:1px solid #1f262e;border-radius:8px;background:#0b0d10"></iframe>
    <div style="margin-top:10px">
      <button onclick="window.open('http://localhost:8081/','_blank')">Open full chat</button>
      <button onclick="document.querySelector('#homebase-chat-card iframe').src='http://localhost:8081/?t='+Date.now()">Reload chat</button>
    </div>
    <div class="small-muted" style="margin-top:8px">Safety: chat remains proposal-first. Writes stay gated by the HomeBase command bus.</div>
  </div>
'@

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

Set-Content -Path $HomeBasePath -Value $text -Encoding UTF8
Write-Host 'Injected HomeBase in-cockpit AI chat card into homebase.ps1.'
