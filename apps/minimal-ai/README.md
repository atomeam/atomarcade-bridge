# Minimal AI App (`apps/minimal-ai`)

Single-file VIKTOR app that replaces `homebase.ps1` as the AtoMind HomeBase cockpit.

Flow: browser -> `app.py` -> local Ollama. No tunnel, no cloud round-trip.

## Files

| File | Purpose |
|---|---|
| `app.py` | VIKTOR app. Exported from the VIKTOR App Builder. Serves the cockpit UI and the four endpoints below. |
| `viktor/scripts/test.py` | Canonical hello script invoked by `/api/viktor/test`. |
| `tools/install-minimal-ai.ps1` | Idempotent operator setup (Python check, VIKTOR install, Ollama check, env vars). |
| `tools/smoke-minimal-ai.ps1` | Post-`viktor start` smoke test. Asserts `/api/chat/status` and `/api/viktor/test` are green. |
| `requirements.txt` | Reference only. The VIKTOR runtime ships `requests`. |

## HTTP contract

| Method | Path | Returns |
|---|---|---|
| GET | `/` | Cockpit UI (chat panel + VIKTOR Test button). |
| GET | `/api/chat/status` | `{ ok, provider, endpoint, model, ollama_reachable }` |
| POST | `/api/chat` | `{ ok, reply, meta }` -- relays the message to Ollama. |
| POST | `/api/viktor/test` | `{ ok, reply, exit_code, stdout, stderr, elapsed_sec }` -- runs `viktor/scripts/test.py --hello homebase`. |

## Environment

| Var | Default |
|---|---|
| `HB_AI_PROVIDER` | `ollama` |
| `HB_AI_ENDPOINT` | `http://localhost:11434/v1/chat/completions` |
| `HB_AI_MODEL` | `qwen2.5:7b-instruct` |
| `HB_AI_API_KEY` | `ollama-local` |
| `HB_AI_TIMEOUT_SEC` | `300` |
| `HB_AI_KEEP_ALIVE` | `30m` |

## Run (fresh Windows PC)

```powershell
# one-time setup
.\tools\install-minimal-ai.ps1 -PullModel

# every time
cd apps\minimal-ai
viktor start
# in a separate terminal:
.\tools\smoke-minimal-ai.ps1
```

## Acceptance criteria

1. Operator runs `viktor start`. Browser opens to the cockpit UI.
2. Within 5s: status pill turns green because `/api/tags` on local Ollama responds.
3. Operator types "hi" -> real Ollama reply in <30s cold or <5s warm (model resident via `keep_alive=30m`).
4. Operator clicks "Run VIKTOR Test" -> within 10s the hello JSON appears in the VIKTOR card.

## Out of scope (deferred)

Slash dispatcher, context envelope, session JSONL on disk, energy checkpoint, `/api/viktor/run` with arbitrary scripts, Curator risk-gating. Wire these only after the minimal loop is green on the operator's PC.

## How to drop in a new `app.py`

`app.py` is owned by the VIKTOR App Builder. To update this folder with the latest build:

1. Open the app in the VIKTOR App Builder.
2. Copy the full contents of `app.py` from the editor.
3. Paste into `apps/minimal-ai/app.py` on this branch and commit.
4. Push and update the PR.
