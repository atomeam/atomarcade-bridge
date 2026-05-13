# HomeBase read-only Notion ingestion harness
# Purpose: prove HomeBase can read Notion pages and produce local preview objects.
# Writes: local JSON preview only. No Notion writes. No profile persistence.
#
# Modes:
#   profile - Diagnostic template -> ProfileTemplate preview
#   queue   - Keep Council Busy page -> HomeBaseWorkQueue preview

param(
    [ValidateSet("profile", "queue")]
    [string]$Mode = "profile",

    [string]$SourcePageId = "",

    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"

$Token = $env:ATOMARCADE_NOTION_TOKEN
$NotionVersion = "2022-06-28"

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "ATOMARCADE_NOTION_TOKEN is not set."
}

if ([string]::IsNullOrWhiteSpace($SourcePageId)) {
    if ($Mode -eq "profile") {
        if (-not [string]::IsNullOrWhiteSpace($env:HOMEBASEREADONLY_DIAGNOSTIC_TEMPLATE_PAGE_ID)) {
            $SourcePageId = $env:HOMEBASEREADONLY_DIAGNOSTIC_TEMPLATE_PAGE_ID
        } else {
            # Diagnostic Deliverable — Memory + Identity Plan (template)
            $SourcePageId = "03cfeece-06f3-4135-8c63-0d52b91769ee"
        }
    } else {
        $SourcePageId = $env:HOMEBASEREADONLY_QUEUE_PAGE_ID
    }
}

if ([string]::IsNullOrWhiteSpace($SourcePageId)) {
    throw "SourcePageId is required for Mode=queue. Pass -SourcePageId '<Notion page id or URL>' or set HOMEBASEREADONLY_QUEUE_PAGE_ID."
}

# Accept raw Notion UUIDs or URLs. Normalize to the 32-char page/block id expected by the API.
function Convert-ToNotionId {
    param([Parameter(Mandatory)][string]$Value)
    $v = $Value.Trim()

    if ($v -match "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") {
        return ($matches[1] -replace "-", "")
    }

    if ($v -match "([0-9a-fA-F]{32})") {
        return $matches[1]
    }

    throw "Could not extract a Notion page/block id from: $Value"
}

$SourcePageId = Convert-ToNotionId $SourcePageId

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $suffix = if ($Mode -eq "queue") { "workqueue" } else { "profiletemplate" }
    $OutFile = Join-Path $base "homebase-readonly-ingestion-$suffix-preview.json"
}

$Headers = @{
    "Authorization"  = "Bearer $Token"
    "Notion-Version" = $NotionVersion
    "Content-Type"   = "application/json"
}

function Invoke-NotionGet {
    param([Parameter(Mandatory)][string]$Uri)
    Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -TimeoutSec 20
}

function Get-RichTextPlain {
    param($RichTextArray)
    if ($null -eq $RichTextArray) { return "" }
    if ($RichTextArray.Count -eq 0) { return "" }
    return (($RichTextArray | ForEach-Object { $_.plain_text }) -join "")
}

function Get-BlockText {
    param($Block)

    switch ($Block.type) {
        "paragraph"          { return Get-RichTextPlain $Block.paragraph.rich_text }
        "heading_1"          { return "# " + (Get-RichTextPlain $Block.heading_1.rich_text) }
        "heading_2"          { return "## " + (Get-RichTextPlain $Block.heading_2.rich_text) }
        "heading_3"          { return "### " + (Get-RichTextPlain $Block.heading_3.rich_text) }
        "bulleted_list_item" { return "- " + (Get-RichTextPlain $Block.bulleted_list_item.rich_text) }
        "numbered_list_item" { return "1. " + (Get-RichTextPlain $Block.numbered_list_item.rich_text) }
        "to_do"              { return "- [" + ($(if ($Block.to_do.checked) { "x" } else { " " })) + "] " + (Get-RichTextPlain $Block.to_do.rich_text) }
        "quote"              { return "> " + (Get-RichTextPlain $Block.quote.rich_text) }
        "callout"            { return Get-RichTextPlain $Block.callout.rich_text }
        "code"               { return Get-RichTextPlain $Block.code.rich_text }
        "table_row"          {
            $cells = @()
            foreach ($cell in $Block.table_row.cells) { $cells += (Get-RichTextPlain $cell) }
            return ($cells -join " | ")
        }
        default              { return "" }
    }
}

function Get-ChildrenRecursive {
    param(
        [Parameter(Mandatory)][string]$BlockId,
        [int]$Depth = 0,
        [int]$MaxDepth = 6
    )

    $all = @()
    $cursor = $null

    do {
        $uri = "https://api.notion.com/v1/blocks/$BlockId/children?page_size=100"
        if ($cursor) { $uri = "$uri&start_cursor=$cursor" }

        $res = Invoke-NotionGet $uri
        foreach ($block in $res.results) {
            $all += $block
            if ($block.has_children -and $Depth -lt $MaxDepth) {
                $all += Get-ChildrenRecursive -BlockId $block.id -Depth ($Depth + 1) -MaxDepth $MaxDepth
            }
        }

        $cursor = $res.next_cursor
    } while ($cursor)

    return $all
}

function Convert-MarkdownTitleToPlain {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $s = $Text.Trim()
    $s = $s -replace "^- \[[ xX]\]\s*", ""
    $s = $s -replace "^\d+\.\s*", ""
    $s = $s -replace "\*\*", ""
    # Avoid PowerShell parser ambiguity around a literal backtick in quoted strings.
    $s = $s.Replace([string][char]96, "")
    $s = $s -replace "\s+", " "
    return $s.Trim()
}

function New-ProfileTemplatePreview {
    param(
        [string]$Content,
        [object[]]$Blocks,
        [string[]]$Lines,
        [datetime]$Started,
        [string]$SourcePageId
    )

    $fields = [ordered]@{
        operator_snapshot    = if ($Content -match "(?im)Operator Snapshot") { "present" } else { "missing" }
        context_inventory   = if ($Content -match "(?im)Context Inventory") { "present" } else { "missing" }
        context_flow_map    = if ($Content -match "(?im)Context Flow Map") { "present" } else { "missing" }
        memory_schema_v0    = if ($Content -match "(?im)Memory Schema v0") { "present" } else { "missing" }
        identity_anchor     = if ($Content -match "(?im)Identity Anchor") { "present" } else { "missing" }
        top_3_fixes         = if ($Content -match "(?im)Top 3 Fixes") { "present" } else { "missing" }
        implementation_plan = if ($Content -match "(?im)72-Hour Implementation Plan") { "present" } else { "missing" }
    }

    $missing = @($fields.GetEnumerator() | Where-Object { $_.Value -ne "present" } | ForEach-Object { $_.Key })
    $ok = ($missing.Count -eq 0)

    return [ordered]@{
        ok                   = $ok
        command              = "INGEST_DIAGNOSTIC_TEMPLATE"
        mode                 = "read_only"
        source_page_id       = $SourcePageId
        object_type          = "ProfileTemplate"
        fields               = $fields
        block_count          = @($Blocks).Count
        extracted_line_count = @($Lines).Count
        missing_fields       = $missing
        writes               = 0
        started_at           = $Started.ToString("o")
        finished_at          = (Get-Date).ToString("o")
    }
}

function New-HomeBaseWorkQueuePreview {
    param(
        [string]$Content,
        [object[]]$Blocks,
        [string[]]$Lines,
        [datetime]$Started,
        [string]$SourcePageId
    )

    $currentLane = $null
    $items = @()
    $laneCounters = @{
        "ai-only"    = 0
        "mcp-lane"   = 0
        "human-only" = 0
    }

    foreach ($line in $Lines) {
        if ($line -match "(?i)^##\s+AI-only migration doables") {
            $currentLane = "ai-only"
            continue
        }
        if ($line -match "(?i)^##\s+MCP lane") {
            $currentLane = "mcp-lane"
            continue
        }
        if ($line -match "(?i)^##\s+Human-only lane") {
            $currentLane = "human-only"
            continue
        }
        if ($line -match "(?i)^##\s+Default next action") {
            $currentLane = $null
            continue
        }

        if ($currentLane -and $line -match "^- \[[ xX]\]\s+") {
            $laneCounters[$currentLane] = [int]$laneCounters[$currentLane] + 1
            $status = if ($line -match "^- \[[xX]\]") { "done" } else { "pending" }
            $title = Convert-MarkdownTitleToPlain $line
            $priority = switch ($currentLane) {
                "ai-only"    { $laneCounters[$currentLane] }
                "mcp-lane"   { 100 + $laneCounters[$currentLane] }
                "human-only" { 200 + $laneCounters[$currentLane] }
                default      { 999 }
            }

            $items += [ordered]@{
                id             = ("{0}-{1:d2}" -f $currentLane, [int]$laneCounters[$currentLane])
                type           = $currentLane
                payload        = [ordered]@{
                    title  = $title
                    source = "Keep Council Busy — HomeBase Migration Queue"
                }
                priority       = $priority
                created_at     = $Started.ToString("o")
                status         = $status
                stop_condition = $null
                default_rule   = $null
                writes         = 0
            }
        }
    }

    $defaultRule = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "(?i)^##\s+Default next action") {
            $following = @()
            for ($j = $i + 1; $j -lt [Math]::Min($Lines.Count, $i + 8); $j++) {
                if ($Lines[$j] -match "^##\s+") { break }
                if (-not [string]::IsNullOrWhiteSpace($Lines[$j])) { $following += (Convert-MarkdownTitleToPlain $Lines[$j]) }
            }
            $defaultRule = ($following -join " ").Trim()
            break
        }
    }

    $stopConditionLines = @($Lines | Where-Object {
        $_ -match "(?i)Stop condition|Stop and ask|require approval|destructive|credential|billing|production|public|secret"
    })

    $laneSummary = [ordered]@{
        "ai-only"    = [int]$laneCounters["ai-only"]
        "mcp-lane"   = [int]$laneCounters["mcp-lane"]
        "human-only" = [int]$laneCounters["human-only"]
    }

    $missing = @()
    if ($laneSummary["ai-only"] -ne 10) { $missing += "ai_only_items_expected_10" }
    if ($laneSummary["mcp-lane"] -ne 10) { $missing += "mcp_lane_items_expected_10" }
    if ($laneSummary["human-only"] -ne 10) { $missing += "human_only_items_expected_10" }
    if ([string]::IsNullOrWhiteSpace($defaultRule)) { $missing += "default_rule" }
    if ($stopConditionLines.Count -eq 0) { $missing += "stop_conditions" }

    $ok = ($missing.Count -eq 0)

    return [ordered]@{
        ok                   = $ok
        command              = "INGEST_KEEP_COUNCIL_BUSY"
        mode                 = "read_only"
        source_page_id       = $SourcePageId
        object_type          = "HomeBaseWorkQueue"
        lanes                = $laneSummary
        item_count           = @($items).Count
        items                = $items
        default_rule         = $defaultRule
        stop_conditions      = $stopConditionLines
        block_count          = @($Blocks).Count
        extracted_line_count = @($Lines).Count
        missing_fields       = $missing
        writes               = 0
        started_at           = $Started.ToString("o")
        finished_at          = (Get-Date).ToString("o")
    }
}

$started = Get-Date
$blocks = Get-ChildrenRecursive -BlockId $SourcePageId
$lines = @()

foreach ($b in $blocks) {
    $t = Get-BlockText $b
    if (-not [string]::IsNullOrWhiteSpace($t)) {
        $lines += $t.Trim()
    }
}

$content = $lines -join "`n"

if ($Mode -eq "queue") {
    $preview = New-HomeBaseWorkQueuePreview -Content $content -Blocks $blocks -Lines $lines -Started $started -SourcePageId $SourcePageId
} else {
    $preview = New-ProfileTemplatePreview -Content $content -Blocks $blocks -Lines $lines -Started $started -SourcePageId $SourcePageId
}

if ($preview.writes -ne 0) {
    throw "Read-only violation: preview writes must be 0."
}

$previewJson = $preview | ConvertTo-Json -Depth 12
$previewJson | Out-File -FilePath $OutFile -Encoding UTF8 -Force

Write-Host $previewJson
if (-not $preview.ok) { exit 2 }
exit 0