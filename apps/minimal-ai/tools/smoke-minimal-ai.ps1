# apps/minimal-ai/tools/smoke-minimal-ai.ps1
# Smoke test for the minimal HomeBase VIKTOR app.
# Run AFTER `viktor start` is up on http://localhost:8080
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:8080'

Write-Host "Waiting 5s for viktor start to be ready..."
Start-Sleep -Seconds 5

try {
    $status = Invoke-RestMethod "$base/api/chat/status" -TimeoutSec 10
    if ($status.ollama_reachable) {
        Write-Host "[OK] Ollama reachable @ $($status.endpoint) (model=$($status.model))" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Ollama NOT reachable -- is ``ollama serve`` running?" -ForegroundColor Red
    }
} catch {
    Write-Host "[FAIL] /api/chat/status failed: $_" -ForegroundColor Red
    exit 1
}

try {
    $test = Invoke-RestMethod -Method POST "$base/api/viktor/test" -TimeoutSec 30
    if ($test.ok) {
        Write-Host "[OK] VIKTOR test passed (exit=$($test.exit_code), elapsed=$($test.elapsed_sec)s)" -ForegroundColor Green
        Write-Host "     reply: $($test.reply)"
    } else {
        Write-Host "[FAIL] VIKTOR test failed: $($test.error)" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "[FAIL] /api/viktor/test failed: $_" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Smoke test passed. Cockpit is healthy.' -ForegroundColor Green
