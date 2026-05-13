# HomeBase chat smoke test helper
# Purpose: isolate UI/routing from provider latency.
# Run from repo root after HomeBase is running:
#   pwsh -File .\tools\homebase-chat-smoke-test.ps1

$ErrorActionPreference = 'Stop'

$statusUri = 'http://localhost:8080/api/chat/status'
$chatUri = 'http://localhost:8080/api/chat'

Write-Host '== HomeBase chat status =='
try {
    $status = Invoke-RestMethod -Uri $statusUri -TimeoutSec 10
    $status | ConvertTo-Json -Depth 10
} catch {
    Write-Host "STATUS ERROR: $($_.Exception.Message)"
    exit 1
}

Write-Host ''
Write-Host '== HomeBase direct /api/chat test =='
$body = @{ message = 'Reply with exactly OK' } | ConvertTo-Json
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $res = Invoke-RestMethod -Uri $chatUri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 190
    $sw.Stop()
    Write-Host ("SECONDS: {0:N1}" -f $sw.Elapsed.TotalSeconds)
    $res | ConvertTo-Json -Depth 20
} catch {
    $sw.Stop()
    Write-Host ("SECONDS: {0:N1}" -f $sw.Elapsed.TotalSeconds)
    Write-Host "CHAT ERROR: $($_.Exception.Message)"
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host "DETAILS: $($_.ErrorDetails.Message)" }
    exit 2
}
