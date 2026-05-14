# AtomArcade Home Base — v0.6.3-log-db-fallback
# Single-file PowerShell HTTP server + Notion Command Bus + write-capable Automation Center.
# Run with: pwsh -File homebase.ps1
# Requires: PowerShell 7+, Windows, RetroArch with network_cmd_enable = "true".

$ErrorActionPreference = 'Stop'

# ============================================================
# Config
# ============================================================
$HTTP_PORT       = 8080
$RETROARCH_HOST  = '127.0.0.1'
$RETROARCH_PORT  = 55355
$UDP_TIMEOUT_MS  = 800
$LOG_MAX         = 500
$VERSION         = 'v0.6.3-log-db-fallback'
$GOVERNANCE_HASH = 'curator-policy-v0.6'

# --- Notion Command Bus ---
$NOTION_TOKEN          = $env:ATOMARCADE_NOTION_TOKEN
$NOTION_DATABASE_ID    = $env:ATOMARCADE_NOTION_DB_ID
$NOTION_AUTO_DB_ID     = $env:ATOMARCADE_NOTION_AUTO_DB_ID
# v0.6.3: hardcoded fallback for the Logs DB UUID (workspace-public,
# not a secret). Removes a class of operator error where the bridge
# silently fails to log because ATOMARCADE_NOTION_LOG_DB_ID was never
# set on the user environment. Env var still takes precedence when present.
$NOTION_LOG_DB_ID_FALLBACK = '4ee3980e62fa4abea716c7d6656011ba'
$NOTION_LOG_DB_ID      = if ([string]::IsNullOrWhiteSpace($env:ATOMARCADE_NOTION_LOG_DB_ID)) { $NOTION_LOG_DB_ID_FALLBACK } else { $env:ATOMARCADE_NOTION_LOG_DB_ID }
$NOTION_POLL_SECONDS   = 5
$NOTION_API_VERSION    = '2022-06-28'
$NOTION_ENABLED        = -not [string]::IsNullOrWhiteSpace($NOTION_TOKEN) -and -not [string]::IsNullOrWhiteSpace($NOTION_DATABASE_ID)

# --- Curator policy ---
$CURATOR_POLICY = @{
    'retroarch'   = $true
    'capture'     = $true
    'observe'     = $true
    'diagnostic'  = $true
    'shell-safe'  = $false
    'curator'     = $true
    'system'      = $true
    'git-pull'    = $true
    'notion-log'  = $true
}
$ALLOW_HIGH_RISK = ($env:ATOMARCADE_ALLOW_HIGH_RISK -eq '1')

$SHELL_SAFE_ALLOWLIST = @(
    'echo',
    'hostname',
    'whoami',
    'Get-Date',
    'Get-Process retroarch'
)

# --- Remote-ops paths ---
$REPO_ROOT = $PSScriptRoot

# ============================================================
# Local file logger (v0.6.1)
# Tiny single-pass helper: timestamped append to homebase.log in script folder.
# Fails silently so logging never breaks the main script.
# DO NOT pass secrets or tokens.
# ============================================================
function Write-Log {
    param([string]$Message)
    try {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $logFile   = Join-Path $scriptDir 'homebase.log'
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        "$timestamp `t $Message" | Out-File -FilePath $logFile -Encoding UTF8 -Append -ErrorAction Stop
    } catch {
        # Fail silently so logging never breaks the main script.
    }
}

# ============================================================
# Local JSONL log (v0.6.2 — chorus-driven local-first source of truth)
# DeepSeek + Gemini convergence: write structured event rows to a local
# append-only JSONL file. This is the durable source of truth; Notion is
# the human-readable mirror. Migration off Notion later becomes a non-event.
# Schema follows Gemini's "Chain of Intent":
#   ts, event, level, kind, origin, author_id, governance_hash,
#   command, status, result, payload
# Fails silently. NEVER pass tokens or secrets.
# ============================================================
function Write-LocalJsonLog {
    param(
        [string]$Event,
        [string]$Level     = 'info',
        [string]$Kind      = '',
        [string]$Origin    = 'bridge',
        [string]$AuthorId  = '',
        [string]$Command   = '',
        [string]$Status    = '',
        [string]$Result    = '',
        [string]$Payload   = ''
    )
    try {
        $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $logFile   = Join-Path $scriptDir 'homebase-logs.jsonl'
        if ([string]::IsNullOrWhiteSpace($AuthorId)) {
            $AuthorId = "homebase/$VERSION@$($script:Hostname)"
        }
        $row = [ordered]@{
            ts               = (Get-Date).ToString('o')
            event            = $Event
            level            = $Level
            kind             = $Kind
            origin           = $Origin
            author_id        = $AuthorId
            governance_hash  = $GOVERNANCE_HASH
            command          = $Command
            status           = $Status
            result           = $Result
            payload          = $Payload
        }
        $line = ($row | ConvertTo-Json -Compress -Depth 6)
        $line | Out-File -FilePath $logFile -Encoding UTF8 -Append -ErrorAction Stop
    } catch {
        # Fail silently.
    }
}

# ============================================================
# In-memory state
# ============================================================
$script:Log     = [System.Collections.Generic.List[object]]::new()
$script:Started = Get-Date
$script:Hostname = $env:COMPUTERNAME
$script:Metrics = @{
    requests_total       = 0
    requests_errors      = 0
    writes_by_origin     = @{ cockpit=0; 'notion-direct'=0; automation=0; external=0; unknown=0 }
    last_request_ms      = 0
    queue_writes_total   = 0
    retry_writes_total   = 0
    toggle_writes_total  = 0
}

function Add-LogEntry {
    param([string]$Kind, [string]$Message, [object]$Data = $null)
    $entry = [pscustomobject]@{
        ts      = (Get-Date).ToString('o')
        kind    = $Kind
        message = $Message
        data    = $Data
    }
    $script:Log.Add($entry) | Out-Null
    if ($script:Log.Count -gt $LOG_MAX) {
        $script:Log.RemoveRange(0, $script:Log.Count - $LOG_MAX)
    }
    Write-Host ("[{0}] {1} -- {2}" -f $entry.ts, $Kind, $Message)
}

# ============================================================
# RetroArch UDP helpers
# ============================================================
function Send-RetroArchCommand {
    param([Parameter(Mandatory)][string]$Command)
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $UDP_TIMEOUT_MS
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Command)
        [void]$udp.Send($bytes, $bytes.Length, $RETROARCH_HOST, $RETROARCH_PORT)
        try {
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $resp = $udp.Receive([ref]$ep)
            return @{ ok = $true; reply = [System.Text.Encoding]::ASCII.GetString($resp).Trim() }
        } catch [System.Net.Sockets.SocketException] {
            return @{ ok = $true; reply = $null }
        }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    } finally {
        $udp.Close()
    }
}

# ============================================================
# v0.5.2 Remote-ops helpers
# ============================================================
function Invoke-GitPull {
    if ([string]::IsNullOrWhiteSpace($REPO_ROOT)) {
        return @{ ok=$false; error='REPO_ROOT not set' }
    }
    if (-not (Test-Path (Join-Path $REPO_ROOT '.git'))) {
        return @{ ok=$false; error="not a git repo: $REPO_ROOT" }
    }
    try {
        $before = (& git -C $REPO_ROOT rev-parse HEAD 2>&1) -join ''
        if ($LASTEXITCODE -ne 0) {
            return @{ ok=$false; error="rev-parse before failed: $before" }
        }
        $pullOutput = (& git -C $REPO_ROOT pull --ff-only origin main 2>&1) -join "`n"
        $pullExit = $LASTEXITCODE
        $after = (& git -C $REPO_ROOT rev-parse HEAD 2>&1) -join ''
        $changed = ($before.Trim() -ne $after.Trim())
        return @{
            ok               = ($pullExit -eq 0)
            changed          = $changed
            before           = $before.Trim()
            after            = $after.Trim()
            pull_exit_code   = $pullExit
            output           = $pullOutput
            requires_restart = $changed
            repo_root        = $REPO_ROOT
        }
    } catch {
        return @{ ok=$false; error=$_.Exception.Message }
    }
}

function Invoke-NotionLog {
    param(
        [string]$Event,
        [string]$ArgsJson
    )
    if ([string]::IsNullOrWhiteSpace($NOTION_TOKEN)) {
        return @{ ok=$false; error='ATOMARCADE_NOTION_TOKEN not set' }
    }
    if ([string]::IsNullOrWhiteSpace($NOTION_LOG_DB_ID)) {
        return @{ ok=$false; error='ATOMARCADE_NOTION_LOG_DB_ID not set' }
    }

    $argsObj = @{}
    if (-not [string]::IsNullOrWhiteSpace($ArgsJson)) {
        try { $argsObj = $ArgsJson | ConvertFrom-Json -AsHashtable } catch { $argsObj = @{} }
    }

    $eventText = if (-not [string]::IsNullOrWhiteSpace($Event)) { $Event } elseif ($argsObj.event) { [string]$argsObj.event } else { 'remote-log' }
    $level     = if ($argsObj.level)   { [string]$argsObj.level }   else { 'info' }
    $logKind   = if ($argsObj.kind)    { [string]$argsObj.kind }    else { 'notion-log' }
    $source    = if ($argsObj.source)  { [string]$argsObj.source }  else { 'home-base' }
    $payload   = if ($argsObj.payload) { [string]$argsObj.payload } else { '' }

    $maxLen = 1900
    if ($payload.Length -gt $maxLen) { $payload = $payload.Substring(0,$maxLen) + ' ...[truncated]' }
    if ($eventText.Length -gt 190)   { $eventText = $eventText.Substring(0,190) + '…' }

    $props = @{
        Event     = @{ title     = @(@{ text = @{ content = $eventText } }) }
        Level     = @{ select    = @{ name = $level } }
        Timestamp = @{ date      = @{ start = (Get-Date).ToString('o') } }
        Kind      = @{ rich_text = @(@{ text = @{ content = $logKind } }) }
        Source    = @{ rich_text = @(@{ text = @{ content = $source } }) }
        Executor  = @{ rich_text = @(@{ text = @{ content = "$($script:Hostname) / $VERSION" } }) }
        Payload   = @{ rich_text = @(@{ text = @{ content = $payload } }) }
    }

    $body = @{
        parent     = @{ database_id = $NOTION_LOG_DB_ID }
        properties = $props
    } | ConvertTo-Json -Depth 10

    try {
        $r = Invoke-RestMethod -Uri 'https://api.notion.com/v1/pages' `
            -Method Post -Headers $script:NotionHeaders -Body $body -TimeoutSec 15
        Write-LocalJsonLog -Event $eventText -Level $level -Kind $logKind -Origin 'notion-log' -Command 'notion-log' -Status 'ok' -Result $r.id -Payload $payload
        return @{ ok=$true; page_id=$r.id; event=$eventText; level=$level; kind=$logKind; source=$source }
    } catch {
        Write-LocalJsonLog -Event $eventText -Level 'error' -Kind $logKind -Origin 'notion-log' -Command 'notion-log' -Status 'fail' -Result $_.Exception.Message -Payload $payload
        return @{ ok=$false; error=$_.Exception.Message }
    }
}

# ============================================================
# Bridge Command dispatcher
# ============================================================
function Invoke-BridgeCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Kind = 'retroarch',
        [string]$Risk = 'low',
        [string]$ArgsJson = $null
    )

    if (-not $CURATOR_POLICY[$Kind]) {
        return @{ ok=$false; blocked=$true; reason="Curator: kind '$Kind' is disabled" }
    }
    if ($Risk -eq 'high' -and -not $ALLOW_HIGH_RISK) {
        return @{ ok=$false; blocked=$true; reason="Curator: risk=high blocked. Set ATOMARCADE_ALLOW_HIGH_RISK=1 to permit." }
    }

    $argsObj = @{}
    if ($ArgsJson) {
        try { $argsObj = $ArgsJson | ConvertFrom-Json -AsHashtable } catch { $argsObj = @{} }
    }

    switch ($Kind) {
        'retroarch'   { return Send-RetroArchCommand -Command $Command }
        'diagnostic'  {
            switch ($Command) {
                'PING'        { return @{ ok=$true; reply='pong'; version=$VERSION; hostname=$script:Hostname } }
                'VERSION'     { return Send-RetroArchCommand -Command 'VERSION' }
                'GET_STATUS'  { return Send-RetroArchCommand -Command 'GET_STATUS' }
                'UPTIME'      { return @{ ok=$true; uptime_seconds=[int]((Get-Date)-$script:Started).TotalSeconds } }
                default       { return @{ ok=$false; error="unknown diagnostic: $Command" } }
            }
        }
        'capture'     {
            switch ($Command) {
                'SCREENSHOT'  { return Send-RetroArchCommand -Command 'SCREENSHOT' }
                'SAVE_STATE'  { return Send-RetroArchCommand -Command 'SAVE_STATE' }
                'LOAD_STATE'  { return Send-RetroArchCommand -Command 'LOAD_STATE' }
                default       { return @{ ok=$false; error="unknown capture: $Command" } }
            }
        }
        'observe'     {
            $note = if ($argsObj.note) { $argsObj.note } else { $Command }
            Add-LogEntry -Kind 'OBSERVE' -Message $note
            return @{ ok=$true; note=$note; recorded_at=(Get-Date).ToString('o') }
        }
        'shell-safe'  {
            if ($SHELL_SAFE_ALLOWLIST -notcontains $Command) {
                return @{ ok=$false; blocked=$true; reason="shell-safe command not on allowlist" }
            }
            try {
                $out = Invoke-Expression $Command 2>&1 | Out-String
                return @{ ok=$true; reply=$out.Trim() }
            } catch {
                return @{ ok=$false; error=$_.Exception.Message }
            }
        }
        'curator'     {
            switch ($Command) {
                'POLICY_DUMP' { return @{ ok=$true; policy=$CURATOR_POLICY; allow_high_risk=$ALLOW_HIGH_RISK; governance_hash=$GOVERNANCE_HASH } }
                default       { return @{ ok=$false; error="unknown curator command: $Command" } }
            }
        }
        'system'      {
            switch ($Command) {
                'LOG_CLEAR'   { $script:Log.Clear(); return @{ ok=$true; cleared=$true } }
                'LOG_COUNT'   { return @{ ok=$true; count=$script:Log.Count } }
                default       { return @{ ok=$false; error="unknown system command: $Command" } }
            }
        }
        'git-pull'    {
            Add-LogEntry -Kind 'GIT_PULL' -Message "requested via $Command"
            return Invoke-GitPull
        }
        'notion-log'  {
            Add-LogEntry -Kind 'NOTION_LOG' -Message "event=$Command"
            return Invoke-NotionLog -Event $Command -ArgsJson $ArgsJson
        }
        default { return @{ ok=$false; error="unknown kind: $Kind" } }
    }
}

# ============================================================
# Notion Command Bus
# ============================================================
$script:NotionHeaders = @{
    'Authorization'  = "Bearer $NOTION_TOKEN"
    'Notion-Version' = $NOTION_API_VERSION
    'Content-Type'   = 'application/json'
}

function Get-NotionPropText {
    param($Property)
    if ($null -eq $Property) { return $null }
    if ($Property.title -and $Property.title.Count -gt 0)        { return ($Property.title       | ForEach-Object { $_.plain_text }) -join '' }
    if ($Property.rich_text -and $Property.rich_text.Count -gt 0){ return ($Property.rich_text   | ForEach-Object { $_.plain_text }) -join '' }
    if ($Property.select)                                        { return $Property.select.name }
    return $null
}

function Query-PendingCommands {
    $body = @{
        filter = @{ property = 'Status'; select = @{ equals = 'Pending' } }
        sorts  = @(@{ timestamp = 'created_time'; direction = 'ascending' })
        page_size = 10
    } | ConvertTo-Json -Depth 8

    $r = Invoke-RestMethod -Uri "https://api.notion.com/v1/databases/$NOTION_DATABASE_ID/query" `
        -Method Post -Headers $script:NotionHeaders -Body $body
    return $r.results
}

function Update-CommandRow {
    param(
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$Status,
        [string]$Result = $null,
        [switch]$SetExecutedAt
    )
    $props = @{ Status = @{ select = @{ name = $Status } } }
    if ($Result) {
        $truncated = if ($Result.Length -gt 1900) { $Result.Substring(0,1900) + ' ...[truncated]' } else { $Result }
        $props.Result = @{ rich_text = @(@{ text = @{ content = $truncated } }) }
    }
    if ($SetExecutedAt) {
        $props.'Executed At' = @{ date = @{ start = (Get-Date).ToString('o') } }
        $props.Executor      = @{ rich_text = @(@{ text = @{ content = "$($script:Hostname) / $VERSION" } }) }
    }
    $body = @{ properties = $props } | ConvertTo-Json -Depth 8
    Invoke-RestMethod -Uri "https://api.notion.com/v1/pages/$PageId" `
        -Method Patch -Headers $script:NotionHeaders -Body $body | Out-Null
}

function Tick-NotionPoller {
    try {
        $rows = Query-PendingCommands
        foreach ($row in $rows) {
            $pageId  = $row.id
            $command = Get-NotionPropText $row.properties.Command
            $kind    = Get-NotionPropText $row.properties.Kind
            $risk    = Get-NotionPropText $row.properties.Risk
            $argsRaw = Get-NotionPropText $row.properties.Args

            if ([string]::IsNullOrWhiteSpace($command)) {
                Update-CommandRow -PageId $pageId -Status 'Failed' -Result 'empty Command' -SetExecutedAt
                Write-LocalJsonLog -Event 'notion-poll-empty-cmd' -Level 'warn' -Kind 'poller' -Origin 'notion-direct' -Command '' -Status 'fail' -Result 'empty Command'
                continue
            }
            if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'retroarch' }
            if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'low' }

            Update-CommandRow -PageId $pageId -Status 'Running'
            Add-LogEntry -Kind 'NOTION_CMD' -Message "$kind/$command" -Data @{ risk=$risk; args=$argsRaw }

            try {
                $result = Invoke-BridgeCommand -Command $command -Kind $kind -Risk $risk -ArgsJson $argsRaw
                $json = $result | ConvertTo-Json -Depth 6 -Compress
                if ($result.blocked) {
                    Update-CommandRow -PageId $pageId -Status 'Blocked' -Result $json -SetExecutedAt
                    Write-LocalJsonLog -Event 'notion-cmd' -Level 'warn' -Kind $kind -Origin 'notion-direct' -Command $command -Status 'blocked' -Result $json
                } elseif ($result.ok) {
                    Update-CommandRow -PageId $pageId -Status 'Completed' -Result $json -SetExecutedAt
                    Write-LocalJsonLog -Event 'notion-cmd' -Level 'info' -Kind $kind -Origin 'notion-direct' -Command $command -Status 'ok' -Result $json
                } else {
                    Update-CommandRow -PageId $pageId -Status 'Failed' -Result $json -SetExecutedAt
                    Write-LocalJsonLog -Event 'notion-cmd' -Level 'error' -Kind $kind -Origin 'notion-direct' -Command $command -Status 'fail' -Result $json
                }
            } catch {
                Update-CommandRow -PageId $pageId -Status 'Failed' -Result $_.Exception.Message -SetExecutedAt
                Add-LogEntry -Kind 'ERROR' -Message $_.Exception.Message
                Write-LocalJsonLog -Event 'notion-cmd' -Level 'error' -Kind $kind -Origin 'notion-direct' -Command $command -Status 'exception' -Result $_.Exception.Message
            }
        }
    } catch {
        Add-LogEntry -Kind 'NOTION_ERR' -Message $_.Exception.Message
        Write-LocalJsonLog -Event 'notion-poller-error' -Level 'error' -Kind 'poller' -Origin 'bridge' -Status 'fail' -Result $_.Exception.Message
    }
}

# ============================================================
# Home Base v0.5 — Read-only Automation Center API
# ============================================================
function Get-ConfigStatus {
    return @{
        token_present          = -not [string]::IsNullOrWhiteSpace($NOTION_TOKEN)
        commands_db_present    = -not [string]::IsNullOrWhiteSpace($NOTION_DATABASE_ID)
        automations_db_present = -not [string]::IsNullOrWhiteSpace($NOTION_AUTO_DB_ID)
        logs_db_present        = -not [string]::IsNullOrWhiteSpace($NOTION_LOG_DB_ID)
    }
}

function Get-PlainText {
    param($RichTextArray)
    if ($null -eq $RichTextArray) { return $null }
    if ($RichTextArray.Count -eq 0) { return $null }
    return (($RichTextArray | ForEach-Object { $_.plain_text }) -join "")
}

function Get-TitleText {
    param($TitleArray)
    if ($null -eq $TitleArray) { return $null }
    if ($TitleArray.Count -eq 0) { return $null }
    return (($TitleArray | ForEach-Object { $_.plain_text }) -join "")
}

function Invoke-NotionDatabaseQuery {
    param(
        [Parameter(Mandatory)][string]$DatabaseId,
        [hashtable]$Body = @{}
    )

    if ([string]::IsNullOrWhiteSpace($NOTION_TOKEN)) {
        return @{ ok = $false; error = "Missing ATOMARCADE_NOTION_TOKEN" }
    }
    if ([string]::IsNullOrWhiteSpace($DatabaseId)) {
        return @{ ok = $false; error = "Missing database id" }
    }

    $uri = "https://api.notion.com/v1/databases/$DatabaseId/query"
    $headers = @{
        "Authorization"  = "Bearer $NOTION_TOKEN"
        "Notion-Version" = $NOTION_API_VERSION
        "Content-Type"   = "application/json"
    }

    if ($Body.Count -eq 0) { $Body = @{ page_size = 20 } }

    try {
        $json = $Body | ConvertTo-Json -Depth 20
        $res = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $json -ErrorAction Stop
        return @{ ok = $true; data = $res }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

function Get-NotionHealth {
    $config = Get-ConfigStatus
    $cmd  = Invoke-NotionDatabaseQuery -DatabaseId $NOTION_DATABASE_ID -Body @{ page_size = 1 }
    $auto = Invoke-NotionDatabaseQuery -DatabaseId $NOTION_AUTO_DB_ID  -Body @{ page_size = 1 }
    $logs = Invoke-NotionDatabaseQuery -DatabaseId $NOTION_LOG_DB_ID   -Body @{ page_size = 1 }
    return @{
        ok = ($cmd.ok -and $auto.ok -and $logs.ok)
        checked_at = (Get-Date).ToString("o")
        config = $config
        databases = @{
            commands = @{ ok = $cmd.ok;  error = $cmd.error }
            automations = @{ ok = $auto.ok; error = $auto.error }
            logs = @{ ok = $logs.ok; error = $logs.error }
        }
    }
}

function Get-AutomationsReadOnly {
    $body = @{ page_size = 50; sorts = @(@{ property = "Last Run"; direction = "descending" }) }
    $res = Invoke-NotionDatabaseQuery -DatabaseId $NOTION_AUTO_DB_ID -Body $body
    if (-not $res.ok) { return @{ ok = $false; error = $res.error; count = 0; rows = @() } }
    $rows = $res.data.results | ForEach-Object {
        $p = $_.properties
        @{
            url = $_.url
            id = $_.id
            name = Get-TitleText $p.Name.title
            enabled = $p.Enabled.checkbox
            kind = $p.Kind.select.name
            command = Get-PlainText $p.Command.rich_text
            interval_sec = $p."Interval (sec)".number
            last_run = $p."Last Run".date.start
            run_count = $p."Run Count".number
            last_result = Get-PlainText $p."Last Result".rich_text
        }
    }
    return @{ ok = $true; count = @($rows).Count; rows = $rows }
}

function Get-CommandsRecent {
    $body = @{ page_size = 10; sorts = @(@{ property = "Created At"; direction = "descending" }) }
    $res = Invoke-NotionDatabaseQuery -DatabaseId $NOTION_DATABASE_ID -Body $body
    if (-not $res.ok) { return @{ ok = $false; error = $res.error; count = 0; rows = @() } }
    $rows = $res.data.results | ForEach-Object {
        $p = $_.properties
        @{
            url = $_.url
            id = $_.id
            command = Get-TitleText $p.Command.title
            status = $p.Status.select.name
            kind = $p.Kind.select.name
            risk = $p.Risk.select.name
            result = Get-PlainText $p.Result.rich_text
            executor = Get-PlainText $p.Executor.rich_text
            created_at = $p."Created At".created_time
            executed_at = $p."Executed At".date.start
        }
    }
    return @{ ok = $true; count = @($rows).Count; rows = $rows }
}

function Get-CommandsProblem {
    $body = @{
        page_size = 50
        filter = @{ or = @(
            @{ property = "Status"; select = @{ equals = "Pending" } }
            @{ property = "Status"; select = @{ equals = "Running" } }
            @{ property = "Status"; select = @{ equals = "Failed" } }
            @{ property = "Status"; select = @{ equals = "Blocked" } }
        ) }
        sorts = @(@{ property = "Created At"; direction = "descending" })
    }
    $res = Invoke-NotionDatabaseQuery -DatabaseId $NOTION_DATABASE_ID -Body $body
    if (-not $res.ok) { return @{ ok = $false; error = $res.error; count = 0; rows = @() } }
    $rows = $res.data.results | ForEach-Object {
        $p = $_.properties
        @{
            url = $_.url
            id = $_.id
            command = Get-TitleText $p.Command.title
            status = $p.Status.select.name
            kind = $p.Kind.select.name
            risk = $p.Risk.select.name
            result = Get-PlainText $p.Result.rich_text
            created_at = $p."Created At".created_time
        }
    }
    return @{ ok = $true; count = @($rows).Count; rows = $rows }
}

function Get-LogsRecent {
    $body = @{ page_size = 20; sorts = @(@{ property = "Timestamp"; direction = "descending" }) }
    $res = Invoke-NotionDatabaseQuery -DatabaseId $NOTION_LOG_DB_ID -Body $body
    if (-not $res.ok) { return @{ ok = $false; error = $res.error; count = 0; rows = @() } }
    $rows = $res.data.results | ForEach-Object {
        $p = $_.properties
        @{
            url = $_.url
            id = $_.id
            event = Get-TitleText $p.Event.title
            level = $p.Level.select.name
            timestamp = $p.Timestamp.date.start
            kind = Get-PlainText $p.Kind.rich_text
            source = Get-PlainText $p.Source.rich_text
            executor = Get-PlainText $p.Executor.rich_text
            payload = Get-PlainText $p.Payload.rich_text
            created_at = $_.created_time
        }
    }
    return @{ ok = $true; count = @($rows).Count; rows = $rows }
}

function Get-SoakStatus {
    $soakStart = [datetime]"2026-05-12T08:00:00Z"
    $now = (Get-Date).ToUniversalTime()
    $h6  = $soakStart.AddHours(6)
    $h18 = $soakStart.AddHours(18)
    $h24 = $soakStart.AddHours(24)
    $next = if ($now -lt $h6) { $h6 } elseif ($now -lt $h18) { $h18 } elseif ($now -lt $h24) { $h24 } else { $null }
    return @{
        ok = $true
        phase = if ($now -lt $h24) { "active" } else { "complete_or_extension_needed" }
        soak_start = $soakStart.ToString("o")
        now = $now.ToString("o")
        h6 = $h6.ToString("o")
        h18 = $h18.ToString("o")
        h24 = $h24.ToString("o")
        next_checkpoint = if ($next) { $next.ToString("o") } else { $null }
        checkpoints_et = @{
            alpha_h6 = "2026-05-12 10:00 AM ET"
            beta_h18 = "2026-05-12 10:00 PM ET"
            gamma_h24 = "2026-05-13 04:00 AM ET"
        }
        rollback_trigger = "Any P0 or repeated P1 within 30 minutes"
    }
}

# ============================================================
# Four Golden Signals snapshot (Gemini SRE/SPOG)
# Approximate latency / traffic / errors / saturation from
# in-process counters. Cheap, always available, no extra DB calls.
# ============================================================
function Get-HealthSnapshot {
    $proc = Get-Process -Id $PID
    $uptimeSec = [int]((Get-Date) - $script:Started).TotalSeconds
    $traffic   = if ($uptimeSec -gt 0) { [math]::Round($script:Metrics.requests_total / [math]::Max($uptimeSec,1), 4) } else { 0 }
    $errRate   = if ($script:Metrics.requests_total -gt 0) {
        [math]::Round($script:Metrics.requests_errors / $script:Metrics.requests_total, 4)
    } else { 0 }
    $jsonlPath = Join-Path $REPO_ROOT 'homebase-logs.jsonl'
    $jsonlBytes = if (Test-Path $jsonlPath) { (Get-Item $jsonlPath).Length } else { 0 }
    return @{
        ok               = $true
        checked_at       = (Get-Date).ToString('o')
        version          = $VERSION
        governance_hash  = $GOVERNANCE_HASH
        golden_signals   = @{
            latency_last_ms = $script:Metrics.last_request_ms
            traffic_rps     = $traffic
            error_rate      = $errRate
            saturation = @{
                working_set_mb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                cpu_seconds    = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 1)
                uptime_seconds = $uptimeSec
                log_in_memory  = $script:Log.Count
            }
        }
        writes_by_origin = $script:Metrics.writes_by_origin
        write_totals     = @{
            queue  = $script:Metrics.queue_writes_total
            retry  = $script:Metrics.retry_writes_total
            toggle = $script:Metrics.toggle_writes_total
        }
        local_jsonl      = @{ path = $jsonlPath; bytes = $jsonlBytes; exists = (Test-Path $jsonlPath) }
    }
}

# ============================================================
# v0.6.0 Write-capable Automation Center API
# v0.6.2: + origin tag + local JSONL mirror + provenance fields
# ============================================================
function Invoke-CommandsQueue {
    param([hashtable]$Body)
    if ([string]::IsNullOrWhiteSpace($NOTION_TOKEN))       { return @{ ok=$false; error='ATOMARCADE_NOTION_TOKEN not set' } }
    if ([string]::IsNullOrWhiteSpace($NOTION_DATABASE_ID)) { return @{ ok=$false; error='ATOMARCADE_NOTION_DB_ID not set' } }
    if ($null -eq $Body) { $Body = @{} }

    $command = [string]$Body.command
    if ([string]::IsNullOrWhiteSpace($command)) { return @{ ok=$false; error='missing command' } }

    $kind     = if ($Body.kind)     { [string]$Body.kind }     else { 'diagnostic' }
    $risk     = if ($Body.risk)     { [string]$Body.risk }     else { 'low' }
    $argsText = if ($Body.args)     { [string]$Body.args }     else { '' }
    $notes    = if ($Body.notes)    { [string]$Body.notes }    else { 'queued via Home Base dashboard' }
    $origin   = if ($Body.origin)   { [string]$Body.origin }   else { 'cockpit' }
    $trigger  = if ($Body.trigger)  { [string]$Body.trigger }  else { 'user_explicit_invocation' }

    if (-not $CURATOR_POLICY.ContainsKey($kind)) {
        Write-LocalJsonLog -Event 'queue-blocked' -Level 'warn' -Kind $kind -Origin $origin -Command $command -Status 'blocked' -Result "unknown kind '$kind'"
        return @{ ok=$false; blocked=$true; reason="Curator: unknown kind '$kind'" }
    }
    if (-not $CURATOR_POLICY[$kind]) {
        Write-LocalJsonLog -Event 'queue-blocked' -Level 'warn' -Kind $kind -Origin $origin -Command $command -Status 'blocked' -Result "kind '$kind' disabled"
        return @{ ok=$false; blocked=$true; reason="Curator: kind '$kind' is disabled" }
    }
    if ($risk -eq 'high' -and -not $ALLOW_HIGH_RISK) {
        Write-LocalJsonLog -Event 'queue-blocked' -Level 'warn' -Kind $kind -Origin $origin -Command $command -Status 'blocked' -Result 'risk=high blocked'
        return @{ ok=$false; blocked=$true; reason='Curator: risk=high blocked. Set ATOMARCADE_ALLOW_HIGH_RISK=1 to permit.' }
    }

    # Embed origin + trigger into Notes so day-30 KPI is recoverable from Notion mirror without schema changes.
    $notesWithProvenance = "$notes | origin=$origin | trigger=$trigger | gov=$GOVERNANCE_HASH"

    $props = @{
        Command = @{ title     = @(@{ text = @{ content = $command } }) }
        Status  = @{ select    = @{ name = 'Pending' } }
        Kind    = @{ select    = @{ name = $kind } }
        Risk    = @{ select    = @{ name = $risk } }
        Notes   = @{ rich_text = @(@{ text = @{ content = $notesWithProvenance } }) }
    }
    if (-not [string]::IsNullOrWhiteSpace($argsText)) {
        $props.Args = @{ rich_text = @(@{ text = @{ content = $argsText } }) }
    }
    $reqBody = @{ parent = @{ database_id = $NOTION_DATABASE_ID }; properties = $props } | ConvertTo-Json -Depth 10
    try {
        $r = Invoke-RestMethod -Uri 'https://api.notion.com/v1/pages' `
            -Method Post -Headers $script:NotionHeaders -Body $reqBody -TimeoutSec 15
        Add-LogEntry -Kind 'WRITE_QUEUE' -Message "$kind/$command [$origin]" -Data @{ page_id=$r.id; origin=$origin }
        $script:Metrics.queue_writes_total++
        if ($script:Metrics.writes_by_origin.ContainsKey($origin)) { $script:Metrics.writes_by_origin[$origin]++ } else { $script:Metrics.writes_by_origin['unknown']++ }
        Write-LocalJsonLog -Event 'queue' -Level 'info' -Kind $kind -Origin $origin -Command $command -Status 'ok' -Result $r.id -Payload $argsText
        return @{ ok=$true; page_id=$r.id; url=$r.url; command=$command; kind=$kind; risk=$risk; origin=$origin; trigger=$trigger }
    } catch {
        Write-LocalJsonLog -Event 'queue' -Level 'error' -Kind $kind -Origin $origin -Command $command -Status 'fail' -Result $_.Exception.Message -Payload $argsText
        return @{ ok=$false; error=$_.Exception.Message }
    }
}

function Invoke-CommandsRetry {
    param([hashtable]$Body)
    if ($null -eq $Body) { $Body = @{} }
    if (-not $Body.origin)  { $Body.origin  = 'cockpit' }
    if (-not $Body.trigger) { $Body.trigger = 'user_explicit_retry' }
    $script:Metrics.retry_writes_total++
    return Invoke-CommandsQueue -Body $Body
}

function Invoke-AutomationsToggle {
    param([hashtable]$Body)
    if ([string]::IsNullOrWhiteSpace($NOTION_TOKEN)) { return @{ ok=$false; error='ATOMARCADE_NOTION_TOKEN not set' } }
    if ($null -eq $Body) { $Body = @{} }

    $pageId = [string]$Body.pageId
    if ([string]::IsNullOrWhiteSpace($pageId)) { return @{ ok=$false; error='missing pageId' } }
    $enabled = if ($null -ne $Body.enabled) { [bool]$Body.enabled } else { $false }
    $origin  = if ($Body.origin) { [string]$Body.origin } else { 'cockpit' }

    $reqBody = @{ properties = @{ Enabled = @{ checkbox = $enabled } } } | ConvertTo-Json -Depth 8
    try {
        $r = Invoke-RestMethod -Uri "https://api.notion.com/v1/pages/$pageId" `
            -Method Patch -Headers $script:NotionHeaders -Body $reqBody -TimeoutSec 15
        Add-LogEntry -Kind 'WRITE_TOGGLE' -Message "$pageId enabled=$enabled [$origin]"
        $script:Metrics.toggle_writes_total++
        if ($script:Metrics.writes_by_origin.ContainsKey($origin)) { $script:Metrics.writes_by_origin[$origin]++ }
        Write-LocalJsonLog -Event 'toggle' -Level 'info' -Kind 'automation' -Origin $origin -Command "toggle/$pageId" -Status 'ok' -Result "enabled=$enabled"
        return @{ ok=$true; page_id=$r.id; enabled=$enabled; origin=$origin }
    } catch {
        Write-LocalJsonLog -Event 'toggle' -Level 'error' -Kind 'automation' -Origin $origin -Command "toggle/$pageId" -Status 'fail' -Result $_.Exception.Message
        return @{ ok=$false; error=$_.Exception.Message }
    }
}

# ============================================================
# PWA manifest + service worker stub (v0.6.2 — Copilot's canonical fix)
# Serves a Web App Manifest so Edge offers "Install as App." Service worker
# is intentionally minimal — just enough for Edge to treat the site as
# installable. No offline cache (cockpit must always reflect live state).
# ============================================================
function Get-PwaManifest {
    return @{
        name              = 'AtomArcade Home Base'
        short_name        = 'Home Base'
        description       = 'AtomArcade cockpit / automation center'
        start_url         = '/'
        display           = 'standalone'
        background_color  = '#0b0d10'
        theme_color       = '#0b0d10'
        scope             = '/'
        orientation       = 'any'
        icons             = @(
            @{ src='/icon.svg'; sizes='any'; type='image/svg+xml'; purpose='any' }
        )
    } | ConvertTo-Json -Depth 6
}

$SERVICE_WORKER_JS = @'
// Home Base service worker (v0.6.2) — minimal, no cache.
// Required for Edge "Install as App." Intentionally does NOT cache responses
// so the cockpit always reflects live bridge state.
self.addEventListener("install", (e) => { self.skipWaiting(); });
self.addEventListener("activate", (e) => { self.clients.claim(); });
self.addEventListener("fetch", () => { /* network only */ });
'@

$ICON_SVG = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" rx="64" fill="#0b0d10"/><circle cx="256" cy="256" r="168" fill="none" stroke="#1f6feb" stroke-width="24"/><circle cx="256" cy="256" r="72" fill="#1f6feb"/><circle cx="256" cy="256" r="24" fill="#0b0d10"/></svg>
'@

# ============================================================
# HTML dashboard
# ============================================================
$DASHBOARD_HTML = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"/><title>AtomArcade Home Base</title>
<link rel="manifest" href="/manifest.webmanifest"/>
<meta name="theme-color" content="#0b0d10"/>
<link rel="icon" type="image/svg+xml" href="/icon.svg"/>
<style>
 :root{color-scheme:dark}
 body{font-family:ui-monospace,Menlo,Consolas,monospace;background:#0b0d10;color:#e6e6e6;margin:0;padding:24px}
 h1{margin:0 0 8px;font-size:20px;letter-spacing:.5px}
 .sub{color:#7a8a99;font-size:12px;margin-bottom:24px}
 .grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
 .card{background:#13171c;border:1px solid #1f262e;border-radius:8px;padding:16px}
 .card h2{margin:0 0 12px;font-size:13px;text-transform:uppercase;letter-spacing:1px;color:#9bb0c5}
 .kv{display:grid;grid-template-columns:160px 1fr;gap:4px 12px;font-size:13px}
 .kv div:nth-child(odd){color:#7a8a99}
 .ok{color:#7ee787}.bad{color:#f97583}.warn{color:#ffd866}
 button{background:#1f6feb;color:#fff;border:0;padding:6px 12px;border-radius:6px;font-family:inherit;cursor:pointer;margin:2px;font-size:12px}
 button:hover{background:#388bfd}button.danger{background:#a3261b}
 button.mini{padding:3px 8px;font-size:11px;margin:2px 0 0 0}
 pre{background:#0b0d10;border:1px solid #1f262e;border-radius:6px;padding:10px;font-size:11px;max-height:300px;overflow:auto;margin:0}
 .log-entry{padding:2px 0;border-bottom:1px solid #1f262e}.log-kind{display:inline-block;width:110px;color:#9bb0c5}
 input[type=text],select{background:#0b0d10;border:1px solid #1f262e;color:#e6e6e6;padding:6px 8px;border-radius:6px;font-family:inherit;font-size:12px}
 input[type=text]{width:60%}
 .status-pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;margin-left:6px}
 .pill-ok{background:#123d22;color:#7ee787;border:1px solid #1f6f3a}
 .pill-warn{background:#4a3600;color:#ffd866;border:1px solid #8a6d00}
 .pill-bad{background:#4a1111;color:#f97583;border:1px solid #8a1f1f}
 .mini-list{display:flex;flex-direction:column;gap:6px;font-size:12px}
 .mini-row{border:1px solid #1f262e;background:#0b0d10;border-radius:6px;padding:8px}
 .mini-title{color:#e6e6e6;font-weight:700}
 .mini-meta{color:#7a8a99;margin-top:2px;font-size:11px;white-space:pre-wrap;overflow-wrap:anywhere}
 .card-error{border-color:#8a1f1f}
 .card-warn{border-color:#8a6d00}
 .small-muted{color:#7a8a99;font-size:11px}
 .queue-form{display:flex;gap:4px;flex-wrap:wrap;align-items:center;margin-bottom:10px}
 .queue-form input[type=text]{flex:1;min-width:120px;width:auto}
 .queue-form select{font-size:11px}
</style></head><body>
<h1>HOME BASE — AUTOMATION CENTER</h1><div class="sub" id="sub">Booting...</div>
<div class="grid">
  <div class="card"><h2>Bridge status</h2><div class="kv" id="bridge-kv"></div></div>
  <div class="card"><h2>RetroArch</h2><div class="kv" id="ra-kv"></div>
    <div style="margin-top:12px">
      <button onclick="cmd('PAUSE_TOGGLE')">Pause/Resume</button>
      <button onclick="cmd('SAVE_STATE')">Save state</button>
      <button onclick="cmd('LOAD_STATE')">Load state</button>
      <button onclick="cmd('SCREENSHOT')">Screenshot</button>
      <button class="danger" onclick="if(confirm('Quit RetroArch?')) cmd('QUIT')">Quit</button>
    </div>
    <div style="margin-top:12px"><input id="raw-cmd" type="text" placeholder="raw command"/><button onclick="cmdRaw()">Send</button></div>
  </div>
  <div class="card" style="grid-column:span 2"><h2>Notion Command Bus</h2><div class="kv" id="bus-kv"></div></div>

  <div class="card">
    <h2>System Pulse <span id="notion-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="kv" id="notion-health-kv"></div>
  </div>

  <div class="card">
    <h2>Golden Signals <span id="golden-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="kv" id="golden-kv"></div>
  </div>

  <div class="card">
    <h2>Soak Window <span id="soak-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="kv" id="soak-kv"></div>
  </div>

  <div class="card">
    <h2>Day-30 KPI <span id="kpi-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="kv" id="kpi-kv"></div>
    <div class="small-muted" style="margin-top:6px">Target: cockpit-originated writes ≥ 70% of total. (DeepSeek day-30 gate.)</div>
  </div>

  <div class="card">
    <h2>Command Queue <span id="commands-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="queue-form">
      <input id="q-command" type="text" placeholder="Command (e.g. PING)"/>
      <select id="q-kind">
        <option>diagnostic</option><option>retroarch</option><option>capture</option><option>observe</option>
        <option>curator</option><option>system</option><option>git-pull</option><option>notion-log</option>
      </select>
      <select id="q-risk">
        <option>low</option><option>medium</option><option>high</option>
      </select>
      <input id="q-args" type="text" placeholder='args JSON (optional)'/>
      <button onclick="queueNewCommand()">Queue</button>
    </div>
    <div class="mini-list" id="commands-problem-list"></div>
    <div style="margin-top:12px" class="small-muted">Recent commands</div>
    <div class="mini-list" id="commands-recent-list" style="margin-top:6px"></div>
  </div>

  <div class="card">
    <h2>Automation Runner <span id="autos-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="mini-list" id="automations-list"></div>
  </div>

  <div class="card" style="grid-column: span 2">
    <h2>Latest Bridge Logs <span id="logs-pill" class="status-pill pill-warn">checking</span></h2>
    <div class="mini-list" id="logs-list"></div>
  </div>

  <div class="card" style="grid-column:span 2"><h2>Event log</h2><pre id="log"></pre></div>
</div>
<script>
if ('serviceWorker' in navigator) { navigator.serviceWorker.register('/sw.js').catch(()=>{}); }
async function j(u,o){const r=await fetch(u,o);return r.json()}
async function apiPost(path,body){try{const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});return await r.json()}catch(e){return {ok:false,error:e.message}}}
async function cmd(c){await j('/api/retroarch/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({cmd:c})});refresh()}
async function cmdRaw(){const v=document.getElementById('raw-cmd').value.trim();if(!v)return;await cmd(v);document.getElementById('raw-cmd').value=''}
async function queueNewCommand(){const c=document.getElementById('q-command').value.trim();if(!c){alert('command required');return}const k=document.getElementById('q-kind').value;const risk=document.getElementById('q-risk').value;const a=document.getElementById('q-args').value.trim();const r=await apiPost('/api/commands/queue',{command:c,kind:k,risk:risk,args:a,origin:'cockpit',trigger:'user_explicit_invocation'});if(r.ok){document.getElementById('q-command').value='';document.getElementById('q-args').value='';setTimeout(refreshAutomationCenter,400)}else{alert('Queue failed: '+(r.error||r.reason||'unknown'))}}
async function retryCommand(command,kind,risk){const r=await apiPost('/api/commands/retry',{command:command,kind:kind,risk:risk,origin:'cockpit',trigger:'user_explicit_retry'});if(r.ok){setTimeout(refreshAutomationCenter,400)}else{alert('Retry failed: '+(r.error||r.reason||'unknown'))}}
async function toggleAutomation(pageId,curEnabled){const r=await apiPost('/api/automations/toggle',{pageId:pageId,enabled:!curEnabled,origin:'cockpit'});if(r.ok){setTimeout(refreshAutomationCenter,500)}else{alert('Toggle failed: '+(r.error||'unknown'))}}
function kv(el,obj){if(!el)return;el.innerHTML='';for(const[k,v]of Object.entries(obj)){const a=document.createElement('div');a.textContent=k;const b=document.createElement('div');if(v===true){b.textContent='yes';b.className='ok'}else if(v===false){b.textContent='no';b.className='bad'}else b.textContent=(v??'-');el.appendChild(a);el.appendChild(b)}}
function esc(v){if(v===null||v===undefined)return '';return String(v).replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]))}
function jstr(v){return JSON.stringify(v===null||v===undefined?'':String(v))}
function setPill(id,state,text){const el=document.getElementById(id);if(!el)return;el.className='status-pill '+(state==='ok'?'pill-ok':state==='bad'?'pill-bad':'pill-warn');el.textContent=text}
function shortText(v,max=90){if(v===null||v===undefined||v==='')return '—';const s=String(v);return s.length>max?s.slice(0,max-1)+'…':s}
function fmtTime(v){if(!v)return '—';try{return new Date(v).toLocaleString()}catch{return v}}
function renderMiniList(id,rows,emptyText,renderer){const el=document.getElementById(id);if(!el)return;if(!rows||rows.length===0){el.innerHTML=`<div class="mini-row"><span class="small-muted">${esc(emptyText)}</span></div>`;return}el.innerHTML=rows.map(renderer).join('')}

async function refresh(){try{const s=await j('/api/status');document.getElementById('sub').textContent='Uptime: '+s.bridge.uptime_seconds+'s  '+s.bridge.version+'  '+new Date().toLocaleTimeString();kv(document.getElementById('bridge-kv'),s.bridge);kv(document.getElementById('ra-kv'),s.retroarch);kv(document.getElementById('bus-kv'),s.notion_bus);const log=await j('/api/log');document.getElementById('log').innerHTML=log.slice(-40).reverse().map(e=>`<div class="log-entry"><span class="log-kind">${esc(e.kind)}</span>${esc(new Date(e.ts).toLocaleTimeString())} -- ${esc(e.message)}</div>`).join('')}catch(e){document.getElementById('sub').textContent='Disconnected: '+e.message}}

async function refreshAutomationCenter(){
  try{
    const health=await j('/api/notion/health');
    setPill('notion-pill',health.ok?'ok':'bad',health.ok?'healthy':'degraded');
    kv(document.getElementById('notion-health-kv'),{
      'Notion':health.ok?'reachable':'unreachable',
      'Token':health.config?.token_present?'present':'missing',
      'Commands DB':health.databases?.commands?.ok?'ok':'fail',
      'Automations DB':health.databases?.automations?.ok?'ok':'fail',
      'Logs DB':health.databases?.logs?.ok?'ok':'fail',
      'Checked':fmtTime(health.checked_at)
    });
  }catch(e){setPill('notion-pill','bad','error')}

  try{
    const snap=await j('/api/health/snapshot');
    const gs=snap.golden_signals||{};
    const errPct=Math.round((gs.error_rate||0)*1000)/10;
    setPill('golden-pill',errPct>5?'bad':errPct>1?'warn':'ok',errPct+'% err');
    kv(document.getElementById('golden-kv'),{
      'Latency (last)':(gs.latency_last_ms||0)+' ms',
      'Traffic':(gs.traffic_rps||0)+' req/s',
      'Error rate':errPct+'%',
      'Memory':((gs.saturation||{}).working_set_mb||0)+' MB',
      'CPU sec':(gs.saturation||{}).cpu_seconds||0,
      'JSONL bytes':(snap.local_jsonl||{}).bytes||0
    });
    const wbo=snap.writes_by_origin||{};
    const total=Object.values(wbo).reduce((a,b)=>a+(b||0),0);
    const cockpit=wbo.cockpit||0;
    const pct=total>0?Math.round((cockpit/total)*1000)/10:0;
    setPill('kpi-pill',pct>=70?'ok':pct>=30?'warn':'bad',pct+'%');
    kv(document.getElementById('kpi-kv'),{
      'Cockpit writes':cockpit,
      'Notion-direct':wbo['notion-direct']||0,
      'Automation':wbo.automation||0,
      'Other':(wbo.external||0)+(wbo.unknown||0),
      'Total writes':total,
      'Cockpit %':pct+'%'
    });
  }catch(e){setPill('golden-pill','bad','error');setPill('kpi-pill','bad','error')}

  try{
    const soak=await j('/api/soak/status');
    setPill('soak-pill',soak.phase==='active'?'ok':'warn',soak.phase||'unknown');
    kv(document.getElementById('soak-kv'),{
      'Start':fmtTime(soak.soak_start),
      'Now':fmtTime(soak.now),
      'H+6':soak.checkpoints_et?.alpha_h6||fmtTime(soak.h6),
      'H+18':soak.checkpoints_et?.beta_h18||fmtTime(soak.h18),
      'H+24':soak.checkpoints_et?.gamma_h24||fmtTime(soak.h24),
      'Next':fmtTime(soak.next_checkpoint),
      'Rollback':soak.rollback_trigger||'—'
    });
  }catch(e){setPill('soak-pill','bad','error')}

  try{
    const problems=await j('/api/commands/problem');
    const rows=problems.rows||[];
    setPill('commands-pill',rows.length===0?'ok':'bad',rows.length===0?'clean':`${rows.length} problem`);
    renderMiniList('commands-problem-list',rows.slice(0,5),'No pending/running/failed/blocked commands.',r=>`
      <div class="mini-row card-error">
        <div class="mini-title">${esc(shortText(r.command))}</div>
        <div class="mini-meta">${esc(r.status)} · ${esc(r.kind||'—')} · ${esc(fmtTime(r.created_at))}</div>
        <div class="mini-meta">${esc(shortText(r.result))}</div>
        <button class="mini" onclick="retryCommand(${jstr(r.command)},${jstr(r.kind)},${jstr(r.risk)})">Retry</button>
      </div>`);
  }catch(e){setPill('commands-pill','bad','error')}

  try{
    const recent=await j('/api/commands/recent');
    renderMiniList('commands-recent-list',(recent.rows||[]).slice(0,5),'No recent commands.',r=>`
      <div class="mini-row">
        <div class="mini-title">${esc(shortText(r.command))}</div>
        <div class="mini-meta">${esc(r.status)} · ${esc(r.kind||'—')} · ${esc(r.risk||'—')} · ${esc(fmtTime(r.created_at))}</div>
        <button class="mini" onclick="retryCommand(${jstr(r.command)},${jstr(r.kind)},${jstr(r.risk)})">Retry</button>
      </div>`);
  }catch(e){renderMiniList('commands-recent-list',[],'Recent commands unavailable.',()=> '')}

  try{
    const autos=await j('/api/automations');
    const rows=autos.rows||[];
    const enabled=rows.filter(r=>r.enabled);
    setPill('autos-pill',enabled.length>0?'ok':'warn',`${enabled.length} enabled`);
    renderMiniList('automations-list',rows,'No automations found.',r=>`
      <div class="mini-row ${r.enabled?'':'card-warn'}">
        <div class="mini-title">${esc(shortText(r.name))} ${r.enabled?'✅':'⏸️'}</div>
        <div class="mini-meta">${esc(r.kind||'—')} · every ${esc(r.interval_sec||'—')}s · run #${esc(r.run_count??'—')}</div>
        <div class="mini-meta">Last: ${esc(fmtTime(r.last_run))}</div>
        <div class="mini-meta">${esc(shortText(r.last_result,120))}</div>
        <button class="mini" onclick="toggleAutomation(${jstr(r.id)},${r.enabled?'true':'false'})">${r.enabled?'Disable':'Enable'}</button>
      </div>`);
  }catch(e){setPill('autos-pill','bad','error')}

  try{
    const logs=await j('/api/logs/recent');
    const rows=logs.rows||[];
    const hasErrors=rows.some(r=>r.level==='error');
    const hasWarns=rows.some(r=>r.level==='warn');
    setPill('logs-pill',hasErrors?'bad':hasWarns?'warn':'ok',hasErrors?'errors':hasWarns?'warnings':`${rows.length} logs`);
    renderMiniList('logs-list',rows.slice(0,8),'No logs found.',r=>`
      <div class="mini-row ${r.level==='error'?'card-error':r.level==='warn'?'card-warn':''}">
        <div class="mini-title">${esc(shortText(r.event))}</div>
        <div class="mini-meta">${esc(r.level||'—')} · ${esc(r.kind||'—')} · ${esc(fmtTime(r.timestamp))}</div>
        <div class="mini-meta">${esc(shortText(r.payload,160))}</div>
      </div>`);
  }catch(e){setPill('logs-pill','bad','error')}
}

refresh();
refreshAutomationCenter();
setInterval(refresh,2000);
setInterval(refreshAutomationCenter,30000);
</script></body></html>
'@

# ============================================================
# HTTP server
# ============================================================
function Write-Json { param($Context, $Object, [int]$Status = 200)
    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}
function Write-Html { param($Context, [string]$Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'text/html; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}
function Write-Text { param($Context, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Status = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}
function Read-JsonBody { param($Context)
    $reader = [System.IO.StreamReader]::new($Context.Request.InputStream, $Context.Request.ContentEncoding)
    $body = $reader.ReadToEnd(); $reader.Close()
    if ([string]::IsNullOrWhiteSpace($body)) { return @{} }
    return ($body | ConvertFrom-Json -AsHashtable)
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$HTTP_PORT/")
try { $listener.Start() } catch {
    Write-Error "Failed to bind http://localhost:$HTTP_PORT/. If access denied, run once as admin: netsh http add urlacl url=http://localhost:$HTTP_PORT/ user=$env:USERNAME"
    throw
}
Add-LogEntry -Kind 'BOOT' -Message "Home Base $VERSION listening on http://localhost:$HTTP_PORT/"
Write-Log "BOOT homebase.ps1 $VERSION started by $env:USERNAME on $($script:Hostname) listening on http://localhost:$HTTP_PORT/"
Write-LocalJsonLog -Event 'boot' -Level 'info' -Kind 'lifecycle' -Origin 'bridge' -Status 'ok' -Result "$VERSION listening on http://localhost:$HTTP_PORT/"
if ($NOTION_ENABLED) {
    Add-LogEntry -Kind 'BOOT' -Message "Notion Command Bus enabled (poll every ${NOTION_POLL_SECONDS}s)"
} else {
    Add-LogEntry -Kind 'BOOT' -Message 'Notion Command Bus DISABLED -- set ATOMARCADE_NOTION_TOKEN and ATOMARCADE_NOTION_DB_ID env vars to enable.'
}
Write-Host ""; Write-Host "  Open: http://localhost:$HTTP_PORT/"; Write-Host "  Stop: Ctrl+C"; Write-Host ""

if ($NOTION_ENABLED) { $script:LastNotionPoll = [datetime]::MinValue }

try {
    while ($listener.IsListening) {
        if ($NOTION_ENABLED -and ((Get-Date) - $script:LastNotionPoll).TotalSeconds -ge $NOTION_POLL_SECONDS) {
            $script:LastNotionPoll = Get-Date
            Tick-NotionPoller
        }

        $asyncResult = $listener.BeginGetContext($null, $null)
        $signaled = $asyncResult.AsyncWaitHandle.WaitOne(1000)
        if (-not $signaled) { continue }
        $ctx = $listener.EndGetContext($asyncResult)

        $req = $ctx.Request; $path = $req.Url.AbsolutePath; $method = $req.HttpMethod
        $reqStart = Get-Date
        $script:Metrics.requests_total++
        try {
            switch -Regex ("$method $path") {
                '^GET /$' { Write-Html -Context $ctx -Html $DASHBOARD_HTML; break }
                '^GET /manifest\.webmanifest$' { Write-Text -Context $ctx -Text (Get-PwaManifest) -ContentType 'application/manifest+json; charset=utf-8'; break }
                '^GET /sw\.js$' { Write-Text -Context $ctx -Text $SERVICE_WORKER_JS -ContentType 'application/javascript; charset=utf-8'; break }
                '^GET /icon\.svg$' { Write-Text -Context $ctx -Text $ICON_SVG -ContentType 'image/svg+xml; charset=utf-8'; break }
                '^GET /api/status$' {
                    $ping = Send-RetroArchCommand -Command 'GET_STATUS'
                    $ra = @{ reachable = $ping.ok; raw = $ping.reply; error = $ping.error }
                    if ($ping.reply) {
                        $parts = $ping.reply -split ' ', 4
                        if ($parts.Length -ge 3) { $ra.state = $parts[1]; $ra.system = $parts[2]; $ra.content = if ($parts.Length -ge 4) { $parts[3] } else { $null } }
                    }
                    $payload = @{
                        bridge = @{
                            ok=$true; version=$VERSION; uptime_seconds=[int]((Get-Date)-$script:Started).TotalSeconds
                            log_count=$script:Log.Count; hostname=$script:Hostname; governance_hash=$GOVERNANCE_HASH
                        }
                        retroarch = $ra
                        notion_bus = @{
                            enabled = $NOTION_ENABLED
                            poll_seconds = $NOTION_POLL_SECONDS
                            last_poll = if ($script:LastNotionPoll -eq [datetime]::MinValue) { 'never' } else { $script:LastNotionPoll.ToString('o') }
                            allow_high_risk = $ALLOW_HIGH_RISK
                            policy_kinds_enabled = ($CURATOR_POLICY.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key }) -join ','
                        }
                    }
                    Write-Json -Context $ctx -Object $payload; break
                }
                '^GET /api/log$' { Write-Json -Context $ctx -Object $script:Log; break }

                '^GET /api/notion/health$' { Write-Json -Context $ctx -Object (Get-NotionHealth); break }
                '^GET /api/health/snapshot$' { Write-Json -Context $ctx -Object (Get-HealthSnapshot); break }
                '^GET /api/automations$' { Write-Json -Context $ctx -Object (Get-AutomationsReadOnly); break }
                '^GET /api/commands/recent$' { Write-Json -Context $ctx -Object (Get-CommandsRecent); break }
                '^GET /api/commands/problem$' { Write-Json -Context $ctx -Object (Get-CommandsProblem); break }
                '^GET /api/logs/recent$' { Write-Json -Context $ctx -Object (Get-LogsRecent); break }
                '^GET /api/soak/status$' { Write-Json -Context $ctx -Object (Get-SoakStatus); break }

                '^POST /api/commands/queue$' {
                    $body = Read-JsonBody -Context $ctx
                    Write-Json -Context $ctx -Object (Invoke-CommandsQueue -Body $body); break
                }
                '^POST /api/commands/retry$' {
                    $body = Read-JsonBody -Context $ctx
                    Write-Json -Context $ctx -Object (Invoke-CommandsRetry -Body $body); break
                }
                '^POST /api/automations/toggle$' {
                    $body = Read-JsonBody -Context $ctx
                    Write-Json -Context $ctx -Object (Invoke-AutomationsToggle -Body $body); break
                }

                '^POST /api/retroarch/command$' {
                    $body = Read-JsonBody -Context $ctx
                    $cmd = [string]$body.cmd
                    if ([string]::IsNullOrWhiteSpace($cmd)) { Write-Json -Context $ctx -Status 400 -Object @{ ok=$false; error='missing cmd' }; break }
                    $result = Send-RetroArchCommand -Command $cmd
                    Add-LogEntry -Kind 'RA_CMD' -Message $cmd -Data $result
                    Write-Json -Context $ctx -Object $result; break
                }
                '^GET /api/retroarch/ping$' {
                    $result = Send-RetroArchCommand -Command 'GET_STATUS'
                    Add-LogEntry -Kind 'RA_PING' -Message ($result.reply ?? '(no reply)') -Data $result
                    Write-Json -Context $ctx -Object $result; break
                }
                '^POST /api/notion/poll$' {
                    if (-not $NOTION_ENABLED) { Write-Json -Context $ctx -Status 409 -Object @{ ok=$false; error='Notion bus not configured' }; break }
                    Tick-NotionPoller
                    Write-Json -Context $ctx -Object @{ ok=$true; polled_at=(Get-Date).ToString('o') }; break
                }
                default { $script:Metrics.requests_errors++; Write-Json -Context $ctx -Status 404 -Object @{ error='not found'; path=$path } }
            }
        } catch {
            $script:Metrics.requests_errors++
            Add-LogEntry -Kind 'ERROR' -Message $_.Exception.Message
            Write-LocalJsonLog -Event 'http-error' -Level 'error' -Kind 'http' -Origin 'bridge' -Command "$method $path" -Status 'fail' -Result $_.Exception.Message
            try { Write-Json -Context $ctx -Status 500 -Object @{ error = $_.Exception.Message } } catch {}
        } finally {
            $script:Metrics.last_request_ms = [int]((Get-Date) - $reqStart).TotalMilliseconds
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
    Add-LogEntry -Kind 'SHUTDOWN' -Message 'Home Base stopped'
    Write-Log "SHUTDOWN homebase.ps1 $VERSION stopped"
    Write-LocalJsonLog -Event 'shutdown' -Level 'info' -Kind 'lifecycle' -Origin 'bridge' -Status 'ok' -Result "$VERSION stopped cleanly"
}
