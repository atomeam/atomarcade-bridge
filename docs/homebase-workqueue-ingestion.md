# HomeBase WorkQueue read-only ingestion

This generalizes the first Diagnostic read-only ingestion proof into a second parser mode: `queue`.

## Goal

Read the **Keep Council Busy — HomeBase Migration Queue** page and produce a local `HomeBaseWorkQueue` preview with:

- 10 AI-only items
- 10 MCP lane items
- 10 human-only items
- stop conditions present
- default rule present
- `writes: 0`

## Safety

This remains preview-only.

- No Notion writes.
- No task check-offs.
- No command queue writes.
- No MCP execution.
- No profile persistence.
- Fails if `writes` is anything other than `0`.

## Run

Set the Keep Council Busy page ID or pass it directly.

```powershell
pwsh -File .\tools\homebase-readonly-ingestion.ps1 `
  -Mode queue `
  -SourcePageId "<Keep Council Busy page id or full Notion URL>"
```

Optional environment variable:

```powershell
[Environment]::SetEnvironmentVariable(
  'HOMEBASEREADONLY_QUEUE_PAGE_ID',
  '<Keep Council Busy page id or full Notion URL>',
  'User'
)
```

Then open a fresh PowerShell session and run:

```powershell
pwsh -File .\tools\homebase-readonly-ingestion.ps1 -Mode queue
```

## Expected output

```json
{
  "ok": true,
  "command": "INGEST_KEEP_COUNCIL_BUSY",
  "mode": "read_only",
  "object_type": "HomeBaseWorkQueue",
  "lanes": {
    "ai-only": 10,
    "mcp-lane": 10,
    "human-only": 10
  },
  "item_count": 30,
  "writes": 0
}
```

## Output file

```text
tools/homebase-readonly-ingestion-workqueue-preview.json
```

## Pass criteria

- `ok = true`
- `object_type = HomeBaseWorkQueue`
- `lanes.ai-only = 10`
- `lanes.mcp-lane = 10`
- `lanes.human-only = 10`
- `item_count = 30`
- `writes = 0`
- source page is unchanged

## Next step after pass

Only after inspection, decide whether to wire `INGEST_KEEP_COUNCIL_BUSY` into `homebase.ps1` as a command. Keep it preview-only until the operator explicitly approves write-path experiments.