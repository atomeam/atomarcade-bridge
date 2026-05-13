# VIKTOR cockpit UI and proxy endpoints

This adds a visible VIKTOR spot to the existing single-file HomeBase cockpit.

Because HomeBase currently serves a static HTML string from PowerShell, the patch uses native HTML/JS instead of a separate React build. The UX is equivalent to the proposed lightweight chatbar but fits the current architecture.

## Install

```powershell
Push-Location C:\AtomArcade\atomarcade-bridge
git pull --ff-only origin main
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\install-viktor-homebase.ps1
```

Restart HomeBase after install.

## Added cockpit features

- VIKTOR panel/card
- Python/VIKTOR CLI status
- scripts/queue paths
- `Queue Viktor test` button
- VIKTOR chat proxy bar
- `viktor` option in the Command Queue kind dropdown

## Added endpoints

```text
GET  /api/viktor/status
POST /api/viktor/test
POST /api/viktor/proxy
```

## Proxy behavior

`POST /api/viktor/proxy` accepts:

```json
{ "text": "hello" }
```

It forwards the text to the local `viktor/scripts/test.py` script as:

```text
--chat "hello"
```

Later, this can be swapped to `mode=viktor-cli` or a real local Viktor app endpoint without changing the cockpit UI.

## Safety

- `viktor.run` scripts remain restricted to `viktor/scripts` by default.
- No arbitrary shell endpoint is exposed.
- Long jobs should use the queued `handlers/viktor.run.ps1` / `handlers/run-viktor-task.ps1` wrapper.
