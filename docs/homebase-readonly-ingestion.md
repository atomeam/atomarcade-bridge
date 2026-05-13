# HomeBase read-only Diagnostic ingestion

This is the first macro migration move after making the HomeBase Talk Console the front door.

## Goal

Prove that HomeBase can read one canonical Notion template and produce a local `ProfileTemplate` preview without mutating Notion or persisting profile memory.

## Source page

Diagnostic Deliverable — Memory + Identity Plan template.

Default source page id:

```text
03cfeece-06f3-4135-8c63-0d52b91769ee
```

## Run

From the repo root:

```powershell
pwsh -File .\tools\homebase-readonly-ingestion.ps1
```

Optional explicit source:

```powershell
[Environment]::SetEnvironmentVariable(
  'HOMEBASEREADONLY_DIAGNOSTIC_TEMPLATE_PAGE_ID',
  '03cfeece-06f3-4135-8c63-0d52b91769ee',
  'User'
)
```

Then open a fresh PowerShell session and run the script.

## Expected output

The script prints and writes a local preview object:

```json
{
  "ok": true,
  "command": "INGEST_DIAGNOSTIC_TEMPLATE",
  "mode": "read_only",
  "object_type": "ProfileTemplate",
  "fields": {
    "operator_snapshot": "present",
    "context_inventory": "present",
    "context_flow_map": "present",
    "memory_schema_v0": "present",
    "identity_anchor": "present",
    "top_3_fixes": "present",
    "implementation_plan": "present"
  },
  "writes": 0
}
```

## Output file

By default:

```text
tools/homebase-readonly-ingestion-preview.json
```

## Guardrails

- No Notion writes.
- No profile persistence.
- No high-risk Bridge actions.
- No command queue required.
- Uses the existing `ATOMARCADE_NOTION_TOKEN`.
- Fails if required template sections are missing.

## Pass criteria

- `ok = true`
- `writes = 0`
- all required fields are `present`
- local JSON preview file exists
- no Notion page/database content changed

## Next step after pass

Wire this logic into `homebase.ps1` as `INGEST_DIAGNOSTIC_TEMPLATE` under `Kind: diagnostic`, still returning preview-only output.