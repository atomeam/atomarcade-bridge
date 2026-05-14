# HomeBase Minimal Core (`rebuild/minimal-core`)

Clean rebuild of `homebase.ps1`. Two tools only:

1. **AI chat** via Ollama (OpenAI-compatible `/v1/chat/completions`)
2. **VIKTOR** local Python script runner

Everything else from earlier builds (Notion bus, automation center, log UI, PWA, splash, the `tools/ensure-*.ps1` patchers) was removed on purpose. Add features back one at a time once these two are stable.

## What's in this branch

- `homebase.ps1` — single-file HTTP cockpit on `localhost:8080` (~280 lines).
- `homebase-launcher.ps1` — kills stale `homebase.ps1` processes, starts the bridge, opens Edge `--app`. **No patchers.**
- `viktor/scripts/test.py` — sanity script, auto-created on first boot if missing.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET  | `/`                     | Cockpit UI (AI chat + VIKTOR cards) |
| GET  | `/api/status`           | Liveness + uptime |
| GET  | `/api/health/snapshot`  | Full status (AI + VIKTOR) |
| GET  | `/api/chat/status`      | AI provider config + Ollama reachability |
| POST | `/api/chat`             | `{ "message": "..." }` |
| GET  | `/api/viktor/status`    | VIKTOR runtime status |
| POST | `/api/viktor/test`      | Runs `viktor/scripts/test.py --hello homebase` |
| POST | `/api/viktor/proxy`     | `{ "text": "..." }` → runs script with `--chat <text>` |
| POST | `/api/viktor/run`       | `{ "script": "...", "args": [...], "timeout_sec": N }` |

## Configuration (env vars)

AI:
- `HB_AI_PROVIDER` (default `ollama`)
- `HB_AI_ENDPOINT` (default `http://localhost:11434/v1/chat/completions`)
- `HB_AI_MODEL` (default `qwen2.5:7b-instruct`)
- `HB_AI_API_KEY` (default `ollama-local`)
- `HB_AI_TIMEOUT_SEC` (default `300`)
- `HB_AI_KEEP_ALIVE` (default `30m` — keeps model resident between turns)

VIKTOR:
- `ATOMARCADE_VIKTOR_ROOT` (default `<repo>/viktor`)
- `ATOMARCADE_VIKTOR_TIMEOUT_SEC` (default `120`)
- `ATOMARCADE_VIKTOR_ALLOW_OUTSIDE_ROOT` (default off; set `1` to allow scripts outside `viktor/scripts`)

## Switch to this branch and boot

```powershell
cd C:\AtomArcade\atomarcade-bridge
git fetch origin
git checkout rebuild/minimal-core
git pull --ff-only origin rebuild/minimal-core

# pull the default model (~4.7 GB, one-time)
ollama pull qwen2.5:7b-instruct

# launch
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\homebase-launcher.ps1
```

## First-boot expectations

- Cockpit opens with two cards: **AI Chat** (green `ready` if Ollama is up) and **VIKTOR** (green `ready` if Python is on PATH).
- First message to AI Chat may take 5–30 s while Ollama loads `qwen2.5:7b-instruct`. Subsequent turns are fast (model stays resident via `keep_alive=30m`).
- `Run viktor.test` returns JSON: `{"ok": true, "tool": "viktor.test", ...}`.

## If AI shows "ollama offline"

```powershell
ollama serve              # in a separate window, or via the tray app
ollama pull qwen2.5:7b-instruct
```

## Choosing a different model

Lighter (CPU or low VRAM):
```powershell
setx HB_AI_MODEL "llama3.2:3b"
ollama pull llama3.2:3b
```

Heavier (12 GB+ VRAM):
```powershell
setx HB_AI_MODEL "qwen2.5:14b-instruct"
ollama pull qwen2.5:14b-instruct
```

After changing, restart HomeBase so the env var is picked up.
