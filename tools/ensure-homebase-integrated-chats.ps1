# Ensures HomeBase serves both in-cockpit AI chat and VIKTOR chat from the main localhost:8080 app.
# This is intentionally a patch-orchestrator for the current single-file HomeBase runtime.
#
# Run from repo root:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\ensure-homebase-integrated-chats.ps1

param(
    [switch]$SkipViktor
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HomeBasePath = Join-Path $RepoRoot 'homebase.ps1'

function Say([string]$Message) {
    Write-Host "[homebase-integrated-chats] $Message"
}

function Run-Patcher {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if (-not (Test-Path $Path)) {
        throw "Missing $Name patcher at $Path"
    }

    Say "Running $Name..."
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path
    if ($LASTEXITCODE -ne 0) {
        throw "$Name patcher exited with code $LASTEXITCODE"
    }
}

function Assert-HomeBaseContains {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Pattern,
        [Parameter(Mandatory=$true)][string]$Label
    )

    if ($Text -notmatch $Pattern) {
        throw "Validation failed: $Label not found in homebase.ps1"
    }

    Say "Verified: $Label"
}

if (-not (Test-Path $HomeBasePath)) {
    throw "homebase.ps1 not found at $HomeBasePath"
}

New-Item -ItemType Directory -Force -Path `
    (Join-Path $RepoRoot 'viktor'), `
    (Join-Path $RepoRoot 'viktor\scripts'), `
    (Join-Path $RepoRoot 'viktor\queue'), `
    (Join-Path $RepoRoot 'viktor\worker'), `
    (Join-Path $RepoRoot 'viktor\chatlogs'), `
    (Join-Path $RepoRoot 'handlers') | Out-Null

$chatPatcher = Join-Path $PSScriptRoot 'ensure-in-cockpit-chat.ps1'
$viktorCommandPatcher = Join-Path $PSScriptRoot 'ensure-viktor-command.ps1'
$viktorUiPatcher = Join-Path $PSScriptRoot 'ensure-viktor-ui.ps1'

# Order matters:
# 1. AI chat owns /api/chat and the AI card.
# 2. VIKTOR command target adds Invoke-ViktorRun and Curator kind support.
# 3. VIKTOR UI adds /api/viktor/* endpoints and the VIKTOR chat panel.
Run-Patcher -Path $chatPatcher -Name 'native AI chat'

if (-not $SkipViktor) {
    Run-Patcher -Path $viktorCommandPatcher -Name 'VIKTOR command target'
    Run-Patcher -Path $viktorUiPatcher -Name 'VIKTOR cockpit UI/proxy'
} else {
    Say 'SkipViktor set; only AI chat was patched.'
}

$text = Get-Content -Path $HomeBasePath -Raw

Assert-HomeBaseContains -Text $text -Pattern 'function Get-HomeBaseNativeChatStatus' -Label 'AI chat status function'
Assert-HomeBaseContains -Text $text -Pattern '\^GET /api/chat/status\$' -Label 'AI chat status route'
Assert-HomeBaseContains -Text $text -Pattern '\^POST /api/chat\$' -Label 'AI chat POST route'
Assert-HomeBaseContains -Text $text -Pattern 'id="homebase-chat-card"' -Label 'AI chat card'

if (-not $SkipViktor) {
    Assert-HomeBaseContains -Text $text -Pattern 'function Invoke-ViktorRun' -Label 'VIKTOR command runner'
    Assert-HomeBaseContains -Text $text -Pattern "'viktor'\s*=\s*\`$true" -Label 'VIKTOR Curator kind'
    Assert-HomeBaseContains -Text $text -Pattern '\^GET /api/viktor/status\$' -Label 'VIKTOR status route'
    Assert-HomeBaseContains -Text $text -Pattern '\^POST /api/viktor/proxy\$' -Label 'VIKTOR proxy route'
    Assert-HomeBaseContains -Text $text -Pattern 'id="viktor-chat-log"' -Label 'VIKTOR chat panel'
}

Say 'Integrated HomeBase chats are patched into homebase.ps1.'
Say 'Restart HomeBase so the running localhost:8080 process serves the updated runtime.'