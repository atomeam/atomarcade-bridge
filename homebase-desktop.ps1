# ============================================================
# AtomArcade Home Base — Desktop (v0.3)
# Single-file Windows Forms app. No HTTP server, no browser.
# Embedded Notion Command Bus + RetroArch UDP client.
# ============================================================

# --- Hide the console window PowerShell shows by default ---
try {
    $sig = @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int s);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
'@
    if (-not ('HB.HBHide' -as [type])) {
        Add-Type -MemberDefinition $sig -Name HBHide -Namespace HB | Out-Null
    }
    [HB.HBHide]::ShowWindow([HB.HBHide]::GetConsoleWindow(), 0) | Out-Null
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Continue'

# ============================================================
# Config
# ============================================================
$VERSION         = 'v0.3-desktop'
$RA_HOST         = '127.0.0.1'
$RA_PORT         = 55355
$UDP_TIMEOUT_MS  = 250
$NOTION_POLL_SEC = 5
$STATUS_POLL_MS  = 2000
$LOG_MAX         = 500
$NOTION_TOKEN    = $env:ATOMARCADE_NOTION_TOKEN
$NOTION_DB_ID    = $env:ATOMARCADE_NOTION_DB_ID
$NOTION_ENABLED  = (-not [string]::IsNullOrWhiteSpace($NOTION_TOKEN)) -and (-not [string]::IsNullOrWhiteSpace($NOTION_DB_ID))

$CURATOR_POLICY = @{
    'retroarch'  = $true
    'capture'    = $true
    'observe'    = $true
    'diagnostic' = $true
    'curator'    = $true
    'system'     = $true
    'shell-safe' = $false
}
$ALLOW_HIGH_RISK = ($env:ATOMARCADE_ALLOW_HIGH_RISK -eq '1')

# ============================================================
# State
# ============================================================
$script:Log            = [System.Collections.Generic.List[string]]::new()
$script:Started        = Get-Date
$script:Hostname       = $env:COMPUTERNAME
$script:LastNotionPoll = [datetime]::MinValue

function Log-Add($kind, $msg) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    $entry = ('[{0}] {1,-12}{2}' -f $ts, $kind, $msg)
    $script:Log.Add($entry) | Out-Null
    if ($script:Log.Count -gt $LOG_MAX) { $script:Log.RemoveRange(0, $script:Log.Count - $LOG_MAX) }
}

# ============================================================
# RetroArch UDP
# ============================================================
function Send-RA([string]$cmd) {
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $UDP_TIMEOUT_MS
        $b = [System.Text.Encoding]::ASCII.GetBytes($cmd)
        [void]$udp.Send($b, $b.Length, $RA_HOST, $RA_PORT)
        try {
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $r = $udp.Receive([ref]$ep)
            return @{ ok=$true; reply=[System.Text.Encoding]::ASCII.GetString($r).Trim() }
        } catch [System.Net.Sockets.SocketException] {
            return @{ ok=$true; reply=$null }
        }
    } catch {
        return @{ ok=$false; error=$_.Exception.Message }
    } finally { $udp.Close() }
}

# ============================================================
# Whitelisted dispatcher
# ============================================================
function Invoke-Bridge([string]$cmd, [string]$kind, [string]$risk) {
    if (-not $CURATOR_POLICY[$kind]) {
        return @{ ok=$false; blocked=$true; reason="Curator: kind '$kind' disabled" }
    }
    if ($risk -eq 'high' -and -not $ALLOW_HIGH_RISK) {
        return @{ ok=$false; blocked=$true; reason='Curator: high risk blocked (set ATOMARCADE_ALLOW_HIGH_RISK=1)' }
    }
    switch ($kind) {
        'retroarch'  { return Send-RA $cmd }
        'capture'    { return Send-RA $cmd }
        'diagnostic' {
            switch ($cmd) {
                'PING'   { return @{ ok=$true; reply='pong'; version=$VERSION; hostname=$script:Hostname } }
                'UPTIME' { return @{ ok=$true; uptime_seconds=[int]((Get-Date)-$script:Started).TotalSeconds } }
                default  { return Send-RA $cmd }
            }
        }
        'observe'    { Log-Add 'OBSERVE' $cmd; return @{ ok=$true; note=$cmd } }
        'curator'    {
            if ($cmd -eq 'POLICY_DUMP') { return @{ ok=$true; policy=$CURATOR_POLICY; allow_high_risk=$ALLOW_HIGH_RISK } }
            return @{ ok=$false; error='unknown curator command' }
        }
        'system'     {
            if ($cmd -eq 'LOG_CLEAR') { $script:Log.Clear(); return @{ ok=$true } }
            if ($cmd -eq 'LOG_COUNT') { return @{ ok=$true; count=$script:Log.Count } }
            return @{ ok=$false; error='unknown system command' }
        }
        default { return @{ ok=$false; error="unknown kind: $kind" } }
    }
}

# ============================================================
# Notion API
# ============================================================
$script:NotionHeaders = @{
    'Authorization'  = "Bearer $NOTION_TOKEN"
    'Notion-Version' = '2022-06-28'
    'Content-Type'   = 'application/json'
}

function Get-Prop($p) {
    if (-not $p) { return $null }
    if ($p.title     -and $p.title.Count -gt 0)     { return ($p.title     | ForEach-Object { $_.plain_text }) -join '' }
    if ($p.rich_text -and $p.rich_text.Count -gt 0) { return ($p.rich_text | ForEach-Object { $_.plain_text }) -join '' }
    if ($p.select)                                  { return $p.select.name }
    return $null
}

function Update-Row($pageId, $status, $result, $stamp) {
    $props = @{ Status = @{ select = @{ name = $status } } }
    if ($result) {
        $t = if ($result.Length -gt 1900) { $result.Substring(0,1900) + ' ...[truncated]' } else { $result }
        $props.Result = @{ rich_text = @(@{ text = @{ content = $t } }) }
    }
    if ($stamp) {
        $props.'Executed At' = @{ date = @{ start = (Get-Date).ToString('o') } }
        $props.Executor      = @{ rich_text = @(@{ text = @{ content = "$($script:Hostname)/$VERSION" } }) }
    }
    $body = @{ properties = $props } | ConvertTo-Json -Depth 8
    Invoke-RestMethod -Uri "https://api.notion.com/v1/pages/$pageId" `
        -Method Patch -Headers $script:NotionHeaders -Body $body -TimeoutSec 10 | Out-Null
}

function Tick-Notion {
    if (-not $NOTION_ENABLED) { return }
    try {
        $body = @{
            filter    = @{ property = 'Status'; select = @{ equals = 'Pending' } }
            sorts     = @(@{ timestamp = 'created_time'; direction = 'ascending' })
            page_size = 10
        } | ConvertTo-Json -Depth 6
        $r = Invoke-RestMethod -Uri "https://api.notion.com/v1/databases/$NOTION_DB_ID/query" `
             -Method Post -Headers $script:NotionHeaders -Body $body -TimeoutSec 10
        foreach ($row in $r.results) {
            $pageId  = $row.id
            $cmd     = Get-Prop $row.properties.Command
            $kind    = Get-Prop $row.properties.Kind
            $risk    = Get-Prop $row.properties.Risk
            if (-not $cmd)  { Update-Row $pageId 'Failed'  'empty Command' $true; continue }
            if (-not $kind) { $kind = 'retroarch' }
            if (-not $risk) { $risk = 'low' }
            Update-Row $pageId 'Running' $null $false
            Log-Add 'NOTION' "$kind/$cmd"
            try {
                $res = Invoke-Bridge $cmd $kind $risk
                $resJson = $res | ConvertTo-Json -Depth 6 -Compress
                $st = if ($res.blocked) { 'Blocked' } elseif ($res.ok) { 'Completed' } else { 'Failed' }
                Update-Row $pageId $st $resJson $true
            } catch {
                Update-Row $pageId 'Failed' $_.Exception.Message $true
                Log-Add 'ERROR' $_.Exception.Message
            }
        }
    } catch {
        Log-Add 'NOTION_ERR' $_.Exception.Message
    }
}

# ============================================================
# UI
# ============================================================
$ColBg     = [System.Drawing.Color]::FromArgb(11,13,16)
$ColPanel  = [System.Drawing.Color]::FromArgb(19,23,28)
$ColText   = [System.Drawing.Color]::FromArgb(230,230,230)
$ColMuted  = [System.Drawing.Color]::FromArgb(155,176,197)
$ColOk     = [System.Drawing.Color]::FromArgb(126,231,135)
$ColWarn   = [System.Drawing.Color]::FromArgb(255,216,102)
$ColErr    = [System.Drawing.Color]::FromArgb(249,117,131)
$ColBlue   = [System.Drawing.Color]::FromArgb(31,111,235)
$ColDanger = [System.Drawing.Color]::FromArgb(163,38,27)
$Mono      = New-Object System.Drawing.Font('Consolas', 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = "AtomArcade Home Base $VERSION"
$form.Size = New-Object System.Drawing.Size(820, 600)
$form.MinimumSize = New-Object System.Drawing.Size(640, 480)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $ColBg
$form.ForeColor = $ColText
$form.Font = $Mono

# --- Status panel ---
$statusBox = New-Object System.Windows.Forms.GroupBox
$statusBox.Text = 'STATUS'
$statusBox.ForeColor = $ColMuted
$statusBox.Location = New-Object System.Drawing.Point(10,10)
$statusBox.Size = New-Object System.Drawing.Size(795,90)
$statusBox.Anchor = 'Top,Left,Right'
$form.Controls.Add($statusBox)

$lblBridge = New-Object System.Windows.Forms.Label
$lblBridge.Location = New-Object System.Drawing.Point(10,25); $lblBridge.Size = New-Object System.Drawing.Size(780,18)
$lblBridge.Text = 'Bridge:     booting...'
$statusBox.Controls.Add($lblBridge)

$lblRA = New-Object System.Windows.Forms.Label
$lblRA.Location = New-Object System.Drawing.Point(10,45); $lblRA.Size = New-Object System.Drawing.Size(780,18)
$lblRA.Text = 'RetroArch:  -'
$statusBox.Controls.Add($lblRA)

$lblBus = New-Object System.Windows.Forms.Label
$lblBus.Location = New-Object System.Drawing.Point(10,65); $lblBus.Size = New-Object System.Drawing.Size(780,18)
$lblBus.Text = 'Notion bus: -'
$statusBox.Controls.Add($lblBus)

# --- Buttons panel ---
$btnPanel = New-Object System.Windows.Forms.GroupBox
$btnPanel.Text = 'CONTROL'
$btnPanel.ForeColor = $ColMuted
$btnPanel.Location = New-Object System.Drawing.Point(10,110)
$btnPanel.Size = New-Object System.Drawing.Size(795,100)
$btnPanel.Anchor = 'Top,Left,Right'
$form.Controls.Add($btnPanel)

function Make-Btn($text, $x, $y, $w, $action, [bool]$danger=$false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 28)
    $b.FlatStyle = 'Flat'
    $b.BackColor = if ($danger) { $ColDanger } else { $ColBlue }
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.BorderSize = 0
    $b.Font = $Mono
    $b.Add_Click($action)
    return $b
}

$btnPanel.Controls.Add((Make-Btn 'Pause/Resume' 10  25 110 { $r = Send-RA 'PAUSE_TOGGLE'; Log-Add 'UI' ("PAUSE_TOGGLE -> " + $(if ($r.ok) {'ok'} else {$r.error})) }))
$btnPanel.Controls.Add((Make-Btn 'Save State'   125 25 100 { $r = Send-RA 'SAVE_STATE';   Log-Add 'UI' ("SAVE_STATE -> " + $(if ($r.ok) {'ok'} else {$r.error})) }))
$btnPanel.Controls.Add((Make-Btn 'Load State'   230 25 100 { $r = Send-RA 'LOAD_STATE';   Log-Add 'UI' ("LOAD_STATE -> " + $(if ($r.ok) {'ok'} else {$r.error})) }))
$btnPanel.Controls.Add((Make-Btn 'Screenshot'   335 25 100 { $r = Send-RA 'SCREENSHOT';   Log-Add 'UI' ("SCREENSHOT -> " + $(if ($r.ok) {'ok'} else {$r.error})) }))
$btnPanel.Controls.Add((Make-Btn 'Fast-Fwd'     440 25  95 { $r = Send-RA 'FAST_FORWARD'; Log-Add 'UI' "FAST_FORWARD" }))
$btnPanel.Controls.Add((Make-Btn 'Menu'         540 25  70 { $r = Send-RA 'MENU_TOGGLE'; Log-Add 'UI' 'MENU_TOGGLE' }))
$btnPanel.Controls.Add((Make-Btn 'Mute'         615 25  60 { $r = Send-RA 'MUTE'; Log-Add 'UI' 'MUTE' }))
$btnPanel.Controls.Add((Make-Btn 'Quit RA'      680 25 100 {
    if ([System.Windows.Forms.MessageBox]::Show('Quit RetroArch?','Confirm','YesNo','Question') -eq 'Yes') {
        $r = Send-RA 'QUIT'; Log-Add 'UI' 'QUIT sent'
    }
} $true))

# Raw command row
$lblRaw = New-Object System.Windows.Forms.Label
$lblRaw.Location = New-Object System.Drawing.Point(10,65); $lblRaw.Size = New-Object System.Drawing.Size(70,22)
$lblRaw.Text = 'Raw:'; $lblRaw.ForeColor = $ColMuted
$btnPanel.Controls.Add($lblRaw)

$txtRaw = New-Object System.Windows.Forms.TextBox
$txtRaw.Location = New-Object System.Drawing.Point(60,62); $txtRaw.Size = New-Object System.Drawing.Size(615,22)
$txtRaw.BackColor = $ColBg; $txtRaw.ForeColor = $ColText; $txtRaw.BorderStyle = 'FixedSingle'; $txtRaw.Font = $Mono
$btnPanel.Controls.Add($txtRaw)

$btnSend = Make-Btn 'Send' 680 60 100 {
    $c = $txtRaw.Text.Trim()
    if ($c) {
        $r = Send-RA $c
        $reply = if ($r.ok -and $r.reply) { $r.reply } elseif ($r.ok) { 'ok' } else { 'ERR: ' + $r.error }
        Log-Add 'RAW' "$c -> $reply"
        $txtRaw.Text = ''
    }
}
$btnPanel.Controls.Add($btnSend)
$txtRaw.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnSend.PerformClick(); $_.SuppressKeyPress = $true } })

# --- Log box ---
$logBox = New-Object System.Windows.Forms.GroupBox
$logBox.Text = 'EVENT LOG'
$logBox.ForeColor = $ColMuted
$logBox.Location = New-Object System.Drawing.Point(10,220)
$logBox.Size = New-Object System.Drawing.Size(795,330)
$logBox.Anchor = 'Top,Left,Right,Bottom'
$form.Controls.Add($logBox)

$logCtrl = New-Object System.Windows.Forms.TextBox
$logCtrl.Multiline = $true; $logCtrl.ScrollBars = 'Vertical'; $logCtrl.ReadOnly = $true
$logCtrl.Location = New-Object System.Drawing.Point(10,22)
$logCtrl.Size = New-Object System.Drawing.Size(775,300)
$logCtrl.Anchor = 'Top,Left,Right,Bottom'
$logCtrl.BackColor = $ColBg; $logCtrl.ForeColor = $ColText; $logCtrl.BorderStyle = 'FixedSingle'; $logCtrl.Font = $Mono
$logBox.Controls.Add($logCtrl)

# --- Boot log ---
Log-Add 'BOOT' "Home Base $VERSION on $($script:Hostname)"
if ($NOTION_ENABLED) {
    Log-Add 'BOOT' ("Notion bus enabled. DB " + $NOTION_DB_ID.Substring(0,[Math]::Min(8,$NOTION_DB_ID.Length)) + '...')
} else {
    Log-Add 'BOOT' 'Notion bus DISABLED — set ATOMARCADE_NOTION_TOKEN + ATOMARCADE_NOTION_DB_ID env vars'
}
if ($ALLOW_HIGH_RISK) { Log-Add 'BOOT' 'High-risk commands ARMED' }

# --- Timer ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $STATUS_POLL_MS
$timer.Add_Tick({
    # RetroArch status
    $ping = Send-RA 'GET_STATUS'
    if ($ping.ok -and $ping.reply) {
        $parts = $ping.reply -split ' ', 4
        $state   = if ($parts.Length -ge 2) { $parts[1] } else { '?' }
        $system  = if ($parts.Length -ge 3) { $parts[2] } else { '-' }
        $content = if ($parts.Length -ge 4) { $parts[3] } else { '-' }
        $lblRA.Text = "RetroArch:  $state   $system   $content"
        $lblRA.ForeColor = $ColOk
    } elseif ($ping.ok) {
        $lblRA.Text = "RetroArch:  not responding on UDP $($RA_PORT) (is RetroArch running with network_cmd_enable=true?)"
        $lblRA.ForeColor = $ColWarn
    } else {
        $lblRA.Text = "RetroArch:  error: $($ping.error)"
        $lblRA.ForeColor = $ColErr
    }

    # Bridge
    $up = [int]((Get-Date)-$script:Started).TotalSeconds
    $lblBridge.Text = "Bridge:     $VERSION   uptime ${up}s   host $($script:Hostname)"
    $lblBridge.ForeColor = $ColOk

    # Notion poll
    if ($NOTION_ENABLED) {
        if (((Get-Date) - $script:LastNotionPoll).TotalSeconds -ge $NOTION_POLL_SEC) {
            $script:LastNotionPoll = Get-Date
            Tick-Notion
        }
        $dbShort = $NOTION_DB_ID.Substring(0,[Math]::Min(8,$NOTION_DB_ID.Length))
        $lblBus.Text = "Notion bus: enabled   last poll $($script:LastNotionPoll.ToString('HH:mm:ss'))   db ${dbShort}..."
        $lblBus.ForeColor = $ColOk
    } else {
        $lblBus.Text = 'Notion bus: DISABLED — set ATOMARCADE_NOTION_TOKEN + ATOMARCADE_NOTION_DB_ID env vars'
        $lblBus.ForeColor = $ColWarn
    }

    # Log render
    $arr = $script:Log.ToArray()
    if ($arr.Length -gt 200) { $arr = $arr[-200..-1] }
    $newText = $arr -join "`r`n"
    if ($logCtrl.Text -ne $newText) {
        $logCtrl.Text = $newText
        $logCtrl.SelectionStart = $logCtrl.Text.Length
        $logCtrl.ScrollToCaret()
    }
})
$timer.Start()

$form.Add_FormClosed({ $timer.Stop() })
[System.Windows.Forms.Application]::Run($form)
