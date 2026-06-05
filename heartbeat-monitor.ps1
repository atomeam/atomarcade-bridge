# Heartbeat Monitor for AtomArcade Bridge
# Monitors bridge heartbeat gap and alerts if > 30 minutes
# Intended to be run via Task Scheduler every 10 minutes
# Usage: pwsh -File heartbeat-monitor.ps1

$ErrorActionPreference = 'Stop'

# Config
$BRIDGE_URL = 'http://localhost:8080'
$ALERT_THRESHOLD_MINUTES = 30
$NOTION_TOKEN = $env:ATOMARCADE_NOTION_TOKEN
$NOTION_LOG_DB_ID = if ([string]::IsNullOrWhiteSpace($env:ATOMARCADE_NOTION_LOG_DB_ID)) { '4ee3980e62fa4abea716c7d6656011ba' } else { $env:ATOMARCADE_NOTION_LOG_DB_ID }
$NOTION_API_VERSION = '2022-06-28'

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$timestamp `t $Message" | Out-File -FilePath 'heartbeat-monitor.log' -Encoding UTF8 -Append
    Write-Host $Message
}

function Send-NotionAlert {
    param([string]$Message, [string]$Level = 'error')

    if ([string]::IsNullOrWhiteSpace($NOTION_TOKEN)) {
        Write-Log "Cannot send alert: ATOMARCADE_NOTION_TOKEN not set"
        return
    }

    $headers = @{
        'Authorization'  = "Bearer $NOTION_TOKEN"
        'Notion-Version' = $NOTION_API_VERSION
        'Content-Type'   = 'application/json'
    }

    $props = @{
        Event = @{ title = @(@{ text = @{ content = "HEARTBEAT ALERT" } }) }
        Level = @{ select = @{ name = $Level } }
        Timestamp = @{ date = @{ start = (Get-Date).ToString('o') } }
        Kind = @{ rich_text = @(@{ text = @{ content = 'heartbeat-monitor' } }) }
        Source = @{ rich_text = @(@{ text = @{ content = 'heartbeat-monitor-script' } }) }
        Executor = @{ rich_text = @(@{ text = @{ content = "$env:COMPUTERNAME / heartbeat-monitor" } }) }
        Payload = @{ rich_text = @(@{ text = @{ content = $Message } }) }
    }

    $body = @{
        parent = @{ database_id = $NOTION_LOG_DB_ID }
        properties = $props
    } | ConvertTo-Json -Depth 10

    try {
        $r = Invoke-RestMethod -Uri 'https://api.notion.com/v1/pages' `
            -Method Post -Headers $headers -Body $body -TimeoutSec 15
        Write-Log "Alert sent to Notion: $($r.id)"
        return @{ ok=$true; page_id=$r.id }
    } catch {
        Write-Log "Failed to send alert: $($_.Exception.Message)"
        return @{ ok=$false; error=$_.Exception.Message }
    }
}

try {
    Write-Log "Starting heartbeat check..."

    # Check bridge heartbeat status
    $response = Invoke-RestMethod -Uri "$BRIDGE_URL/api/heartbeat/status" -TimeoutSec 10

    if ($response.is_stale) {
        $alertMsg = "Bridge heartbeat is STALE! Last heartbeat: $($response.last_heartbeat), Gap: $($response.gap_seconds)s (threshold: ${ALERT_THRESHOLD_MINUTES}m). This indicates the bridge process may have died."
        Write-Log "ALERT: $alertMsg"
        Send-NotionAlert -Message $alertMsg -Level 'error'
    } else {
        Write-Log "Heartbeat OK - Last: $($response.last_heartbeat), Gap: $($response.gap_seconds)s"
    }

} catch {
    $errorMsg = "Failed to check heartbeat: $($_.Exception.Message). Bridge may be down or not responding."
    Write-Log "ERROR: $errorMsg"
    Send-NotionAlert -Message $errorMsg -Level 'error'
}

Write-Log "Heartbeat check completed"
