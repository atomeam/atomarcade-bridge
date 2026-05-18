# AtomArcade Bridge

A unified orchestration server that connects local AI runtimes (Ollama, Gemini) with Notion-based logging and diagnostics for the AtomArcade HomeBase ecosystem.

## Quick Start

```bash
# Install dependencies
cd unified-app
npm install

# Start the server
npm run dev
```

## Prerequisites

- **Node.js** 18+ with ESM support
- **Notion Integration** (optional for logging): Create at https://www.notion.so/my-integrations
- **Ollama** (optional): Local LLM runtime on `http://localhost:11434`
- **Gemini** (optional): Google AI API key from https://aistudio.google.com/app/apikey

## Configuration

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `NOTION_API_KEY` | Yes | Notion integration secret (starts with `ntn_`) |
| `ATOMARCADE_NOTION_LOG_DB_ID` | Yes | Notion database ID for logging |
| `GEMINI_API_KEY` | No | Google AI API key for Gemini fallback |
| `OLLAMA_URL` | No | Ollama endpoint (default: `http://localhost:11434`) |
| `HB_AI_MODEL` | No | Ollama model name (default: `gpt-oss:20b`) |
| `HB_LOG_FILE` | No | Path to log file (default: `C:\AtomArcade\homebase-logs.jsonl`) |
| `PORT` | No | Server port (default: `3000`) |

### Example `.env` File

```bash
# Required
NOTION_API_KEY=ntn_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ATOMARCADE_NOTION_LOG_DB_ID=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Optional
GEMINI_API_KEY=AIza_xxxxxxxxxxxxxxxxxxxxxxxx
OLLAMA_URL=http://localhost:11434
HB_AI_MODEL=gpt-oss:20b
HB_LOG_FILE=C:\AtomArcade\homebase-logs.jsonl
PORT=3000
```

## API Documentation

### GET `/api/health`

Returns a structured health check of all dependencies. Each check runs in parallel and **never throws** — always returns a valid JSON payload.

**Response Schema:**

```json
{
  "ok": boolean,
  "version": "1.0.0",
  "timestamp": "2026-05-18T11:25:17.109Z",
  "checks": {
    "env":    { "ok": boolean, "detail": string, "latencyMs": number },
    "notion": { "ok": boolean, "detail": string, "latencyMs": number },
    "ollama": { "ok": boolean, "detail": string, "latencyMs": number },
    "gemini": { "ok": boolean, "detail": string, "latencyMs": number }
  }
}
```

**Example Response:**

```json
{
  "ok": true,
  "version": {
    "service": "atomarcade-bridge",
    "semver": "1.0.0",
    "gitSha": "a1b2c3d",
    "node": "v22.22.2"
  },
  "timestamp": "2026-05-18T11:25:17.109Z",
  "checks": {
    "env":    { "ok": true,  "detail": "all required vars present", "latencyMs": 0 },
    "notion": { "ok": true,  "detail": "connected (DB verified)", "latencyMs": 45 },
    "ollama": { "ok": true,  "detail": "Model \"gpt-oss:20b\" ready (2 available)", "latencyMs": 23 },
    "gemini": { "ok": false, "detail": "not configured", "latencyMs": 0 }
  }
}
```

**Version Object Fields:**

| Field | Description |
|-------|-------------|
| `version` | Full version object |
| `version.service` | Always "atomarcade-bridge" |
| `version.semver` | Version from package.json or fallback |
| `version.gitSha` | Short git SHA or "unknown" |
| `version.node` | Node.js version |

**Interpreting Results:**

- `ok: true` — All required checks passed
- `ok: false` — One or more checks failed; inspect `checks` for details
- `"detail"` field explains the state (e.g., "connected (DB verified)", "Model not found locally")
- `"latencyMs"` shows response time for each dependency

## Troubleshooting

### Notion: Token invalid or expired

- Verify `NOTION_API_KEY` is correct (no extra quotes or spaces)
- Token must start with `ntn_`

### Notion: "Database not found" or "not shared with integration"

- Verify `ATOMARCADE_NOTION_LOG_DB_ID` is correct
- Confirm the integration has been **shared** with the target database in Notion

### Notion: "Permission denied to database"

- The integration has access but lacks required permissions

### Ollama: Model not found locally

- Verify `HB_AI_MODEL` matches an available model: `ollama list`
- The check verifies the configured model is actually pulled and available

### Ollama: "fetch failed"

- Verify `OLLAMA_URL` matches your running instance (commonly `http://127.0.0.1:11434`)
- Confirm Ollama is running: `ollama list`

### Gemini: "not configured"

- This is normal if no `GEMINI_API_KEY` was provided
- Add the key to enable Gemini fallback

## License

MIT