# Notion → HomeBase → Viktor command target

This is the minimal-moving-parts Viktor integration for the existing HomeBase Command Bus.

## Architecture

```text
Notion Bridge Commands row
→ HomeBase poller
→ Invoke-BridgeCommand
→ viktor.run target
→ local Python / Viktor CLI script
→ result written back to Notion
```

HomeBase remains the single execution engine. VIKTOR is treated as another local tool target.

## Install

From the repo root on the HomeBase machine:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\install-viktor-homebase.ps1
```

This applies `tools/ensure-viktor-command.ps1`, creates `viktor/scripts/test.py`, and attempts `pip install viktor` if Python is available.

## Bridge Commands row

Use either of these forms.

Preferred explicit form:

| Property | Value |
|---|---|
| Command | `run` |
| Kind | `viktor` |
| Risk | `low` |
| Args | `{ "script": "viktor/scripts/test.py", "args": ["--hello", "homebase"], "mode": "python", "timeout_sec": 60 }` |

Compact compatible form:

| Property | Value |
|---|---|
| Command | `viktor.run` |
| Kind | `viktor` |
| Risk | `low` |
| Args | `{ "script": "viktor/scripts/test.py", "args": ["--hello", "homebase"], "mode": "python", "timeout_sec": 60 }` |

## Args schema

```json
{
  "script": "viktor/scripts/test.py",
  "args": ["--foo", "bar"],
  "mode": "python",
  "timeout_sec": 120
}
```

Fields:

- `script` — required. Must live under `viktor/scripts` by default.
- `args` — optional string array passed to the script.
- `mode` — `python` or `viktor-cli`.
- `timeout_sec` — optional, capped at 900 seconds.

## Safety

- Scripts are blocked unless they resolve under `viktor/scripts`.
- Set `ATOMARCADE_VIKTOR_ALLOW_OUTSIDE_ROOT=1` only if you intentionally want to permit absolute paths.
- The command target captures stdout, stderr, exit code, timeout state, and elapsed seconds.
- No arbitrary shell command is exposed.

## Expected test result

The test script returns JSON similar to:

```json
{
  "ok": true,
  "tool": "viktor.test",
  "message": "Hello from HomeBase -> Viktor script target",
  "argv": ["--hello", "homebase"]
}
```

That JSON is written into the Bridge Commands `Result` field by the existing HomeBase poller.
