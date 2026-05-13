# HomeBase AI Chat Runtime v0.1

HomeBase AI Chat Runtime v0.1 is a proposal-first sidecar for the HomeBase cockpit.

It gives Atom a local chat surface that can see HomeBase context and return explicit command proposals, while keeping execution gated.

## Safety model

Default mode is **chat + propose only**.

Allowed in v0.1:

- Read local preview JSON.
- Read recent HomeBase logs.
- Return natural-language replies.
- Return structured command proposals.
- Append local chat audit log rows.

Blocked in v0.1:

- No autonomous command execution.
- No Notion mutation from chat endpoint.
- No secrets/tokens/billing/domains/public posts/destructive deletes.
- No broad shell commands.
- No autonomous loops.

## Environment variables

Preferred names:

```powershell
$env:HB_AI_PROVIDER = "dry-run" # or openai
$env:HB_AI_MODEL = "gpt-4o-mini"
$env:HB_AI_API_KEY = "" # only needed for real provider
$env:HB_AI_ENDPOINT = "https://api.openai.com/v1/chat/completions"
$env:HB_CHAT_PORT = "8081"
$env:HB_CHAT_AUDIT_LOG_PATH = "C:\\AtomArcade\\atomarcade-bridge\\homebase-chat.jsonl"
```

Compatibility aliases are also supported:

```powershell
$env:LLM_PROVIDER
$env:LLM_MODEL
$env:LLM_API_KEY
$env:LLM_BASE_URL
$env:LLM_DRY_RUN
```

## Run in dry-run mode

```powershell
cd C:\AtomArcade\atomarcade-bridge
$env:HB_AI_PROVIDER = "dry-run"
pwsh -File .\tools\homebase-ai-chat-runtime.ps1
```

Open:

```text
http://localhost:8081/
```

Or test with PowerShell:

```powershell
Invoke-RestMethod -Uri "http://localhost:8081/api/chat" `
  -Method POST `
  -ContentType "application/json" `
  -Body '{"session_id":"test-1","user_id":"atom","message":"What should we do next for migration?"}'
```

## Run with OpenAI-compatible endpoint

```powershell
cd C:\AtomArcade\atomarcade-bridge
$env:HB_AI_PROVIDER = "openai"
$env:HB_AI_MODEL = "gpt-4o-mini"
$env:HB_AI_API_KEY = "<set locally only; never commit>"
$env:HB_AI_ENDPOINT = "https://api.openai.com/v1/chat/completions"
pwsh -File .\tools\homebase-ai-chat-runtime.ps1
```

## API

### GET `/api/chat/status`

Returns provider/model/status. Does not expose keys.

### POST `/api/chat`

Request:

```json
{
  "session_id": "test-1",
  "user_id": "atom",
  "message": "What should we do next for migration?"
}
```

Response:

```json
{
  "ok": true,
  "reply": "...",
  "proposals": [],
  "requires_approval": false,
  "meta": {
    "context_snapshot_id": "snapshot-20260513-0503",
    "context_sources": ["workqueue_preview", "homebase_jsonl"],
    "provider": "dry-run",
    "model": "mock-homebase-v0.1",
    "writes": 0
  }
}
```

## Audit log

Every successful chat turn appends JSONL to `homebase-chat.jsonl` by default.

The audit row includes snippets only and never logs API keys.

## Acceptance test

1. Start runtime in dry-run.
2. Open `http://localhost:8081/`.
3. Ask: `What should we do next for migration?`
4. Confirm response returns a proposal with:
   - `writes_intent: 0`
   - `risk_level: low`
   - `requires_approval: true`
5. Confirm `homebase-chat.jsonl` was created.

## Next step

After v0.1 is stable, wire a proposal approval endpoint that creates command rows through the existing HomeBase command bus. Keep this behind explicit operator confirmation.
