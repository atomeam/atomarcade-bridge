# HomeBase integrated chat smoke test helper
# Purpose: verify both HomeBase native AI chat and VIKTOR chat/proxy are served from localhost:8080.
#
# Run from repo root after HomeBase is running:
#   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\homebase-integrated-chat-smoke-test.ps1

param(
    [int]$ChatTimeoutSec = 190,
    [int]$ViktorTimeoutSec = 90
)

$ErrorActionPreference = 'Continue'

function Section([string]$Name) {
    Write-Host ""
    Write-Host "== $Name ==" -ForegroundColor Cyan
}

function Print-Json($Object) {
    $Object | ConvertTo-Json -Depth 20
}

$failures = 0

Section 'HomeBase status'
try {
    $status = Invoke-RestMethod -Uri 'http://localhost:8080/api/status' -TimeoutSec 10
    Print-Json $status
} catch {
    $failures++
    Write-Host "STATUS ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Section 'AI chat status'
try {
    $chatStatus = Invoke-RestMethod -Uri 'http://localhost:8080/api/chat/status' -TimeoutSec 10
    Print-Json $chatStatus
    if (-not $chatStatus.ok) { $failures++ }
} catch {
    $failures++
    Write-Host "CHAT STATUS ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Section 'AI chat ping'
try {
    $body = @{ message = 'Reply with exactly OK' } | ConvertTo-Json
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $chat = Invoke-RestMethod -Uri 'http://localhost:8080/api/chat' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $ChatTimeoutSec
    $sw.Stop()
    Write-Host ("SECONDS: {0:N1}" -f $sw.Elapsed.TotalSeconds)
    Print-Json $chat
    if (-not $chat.ok) { $failures++ }
} catch {
    $failures++
    Write-Host "CHAT ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host "DETAILS: $($_.ErrorDetails.Message)" }
}

Section 'VIKTOR status'
try {
    $viktorStatus = Invoke-RestMethod -Uri 'http://localhost:8080/api/viktor/status' -TimeoutSec 10
    Print-Json $viktorStatus
    if (-not $viktorStatus.ok) { $failures++ }
} catch {
    $failures++
    Write-Host "VIKTOR STATUS ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

Section 'VIKTOR proxy ping'
try {
    $body = @{ text = 'ping from integrated smoke test' } | ConvertTo-Json
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $viktor = Invoke-RestMethod -Uri 'http://localhost:8080/api/viktor/proxy' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $ViktorTimeoutSec
    $sw.Stop()
    Write-Host ("SECONDS: {0:N1}" -f $sw.Elapsed.TotalSeconds)
    Print-Json $viktor
    if (-not $viktor.ok) { $failures++ }
} catch {
    $failures++
    Write-Host "VIKTOR PROXY ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host "DETAILS: $($_.ErrorDetails.Message)" }
}

Section 'Verdict'
if ($failures -eq 0) {
    Write-Host 'OK — both chats are reachable from HomeBase localhost:8080.' -ForegroundColor Green
    exit 0
}

Write-Host "FAIL — $failures check(s) failed." -ForegroundColor Red
exit 2