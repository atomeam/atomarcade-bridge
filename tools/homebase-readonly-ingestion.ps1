# HomeBase read-only Diagnostic template ingestion test
# Purpose: prove Bridge/HomeBase can read one Notion page and build a ProfileTemplate preview.
# Writes: local JSON preview only. No Notion writes. No profile persistence.

param(
    [string]$SourcePageId = $env:HOMEBASEREADONLY_DIAGNOSTIC_TEMPLATE_PAGE_ID,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"

$Token = $env:ATOMARCADE_NOTION_TOKEN
$NotionVersion = "2022-06-28"

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "ATOMARCADE_NOTION_TOKEN is not set."
}

if ([string]::IsNullOrWhiteSpace($SourcePageId)) {
    # Diagnostic Deliverable — Memory + Identity Plan (template)
    $SourcePageId = "03cfeece-06f3-4135-8c63-0d52b91769ee"
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
    $OutFile = Join-Path $base "homebase-readonly-ingestion-preview.json"
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
        [int]$MaxDepth = 4
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

$fields = [ordered]@{
    operator_snapshot    = if ($content -match "(?im)Operator Snapshot") { "present" } else { "missing" }
    context_inventory   = if ($content -match "(?im)Context Inventory") { "present" } else { "missing" }
    context_flow_map    = if ($content -match "(?im)Context Flow Map") { "present" } else { "missing" }
    memory_schema_v0    = if ($content -match "(?im)Memory Schema v0") { "present" } else { "missing" }
    identity_anchor     = if ($content -match "(?im)Identity Anchor") { "present" } else { "missing" }
    top_3_fixes         = if ($content -match "(?im)Top 3 Fixes") { "present" } else { "missing" }
    implementation_plan = if ($content -match "(?im)72-Hour Implementation Plan") { "present" } else { "missing" }
}

$missing = @($fields.GetEnumerator() | Where-Object { $_.Value -ne "present" } | ForEach-Object { $_.Key })
$ok = ($missing.Count -eq 0)

$preview = [ordered]@{
    ok                   = $ok
    command              = "INGEST_DIAGNOSTIC_TEMPLATE"
    mode                 = "read_only"
    source_page_id       = $SourcePageId
    object_type          = "ProfileTemplate"
    fields               = $fields
    block_count          = @($blocks).Count
    extracted_line_count = @($lines).Count
    missing_fields       = $missing
    writes               = 0
    started_at           = $started.ToString("o")
    finished_at          = (Get-Date).ToString("o")
}

$previewJson = $preview | ConvertTo-Json -Depth 8
$previewJson | Out-File -FilePath $OutFile -Encoding UTF8 -Force

Write-Host $previewJson
if (-not $ok) { exit 2 }
exit 0