# HomeBase AI Chat Runtime v0.1

HomeBase AI Chat Runtime v0.1 is the first AI chat surface for the HomeBase app.

It runs as a local app sidecar on `localhost:8081` and is started by the HomeBase launcher. It can connect to a real OpenAI-compatible AI provider through environment variables, or fall back to dry-run mode when no key is present.

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

## In-app behavior

Launching HomeBase through `launch-homebase.ps1` or `homebase-desktop.ps1` now starts both:

- Main cockpit: `http://localhost:8080/`
- AI chat runtime: `http://localhost:8081/`

This puts the chat surface in the HomeBase app flow without requiring a second manual server command.

## Real AI setup

Set these locally before launching HomeBase. Never paste keys into Notion and never commit them.

```powershell
[Environment]::SetEnvironmentVariable('HB_AI_PROVIDER', 'openai', 'User')
[Environment]::SetEnvironmentVariable('HB_AI_MODEL', 'gpt-4o-mini', 'User')
[Environment]::SetEnvironmentVariable('HB_AI_API_KEY', '<your provider key>', 'User')
[Environment]::SetEnvironmentVariable('HB_AI_ENDPOINT', 'https://api.openai.com/v1/chat/completions', 'User')
```

Open a fresh PowerShell session or relaunch HomeBase after setting the variables.

## Dry-run mode

If no real key is available yet:

```powershell
$env:HB_AI_PROVIDER = "dry-run"
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
    "provider": "openai",
    "model": "gpt-4o-mini",
    "writes": 0
  }
}
```

## Smoke test

```powershell
Invoke-RestMethod -Uri "http://localhost:8081/api/chat" `
  -Method POST `
  -ContentType "application/json" `
  -Body '{"session_id":"test-1","user_id":"atom","message":"What should we do next for migration?"}'
```

## Audit log

Every successful chat turn appends JSONL to `homebase-chat.jsonl` by default.

The audit row includes snippets only and never logs API keys.

## Acceptance test

1. Set real provider env vars or use dry-run.
2. Launch HomeBase normally.
3. Confirm `http://localhost:8081/api/chat/status` returns `ok: true`.
4. Open `http://localhost:8081/`.
5. Ask: `What should we do next for migration?`
6. Confirm response returns from real provider when `HB_AI_PROVIDER=openai` and `HB_AI_API_KEY` is set.
7. Confirm any proposal remains proposal-only with no autonomous writes.

## Next step

After real chat is stable, embed the chat panel directly into the main `localhost:8080` cockpit page and add a typed-confirmation approval endpoint that can create command rows through the existing HomeBase command bus.
