# VIKTOR Generic Worker for AtoMind HomeBase

This adapts VIKTOR's `GenericAnalysis` / Generic worker pattern to AtoMind HomeBase.

The goal is not to make VIKTOR the chat model. The goal is to use VIKTOR as a controlled remote worker that can run allowlisted HomeBase diagnostics and repair scripts on a Windows host.

## Why this helps

HomeBase repair has local machine concerns that cloud chat cannot directly inspect:

- Windows `HTTP.sys` / URLACL state
- process owning `localhost:8080`
- stale PowerShell listeners
- local repo state
- whether `/api/status`, `/api/chat/status`, and `/api/chat` return

A VIKTOR Generic worker can run a fixed command on the machine and return `output.txt` plus `diagnostics.json`.

## Files added

- `tools/viktor-homebase-worker.ps1` — VIKTOR worker entrypoint. Runs one approved task and writes output files.
- `viktor-worker/config.yaml` — example Generic worker config for the worker host.

## Worker tasks

The config defines four allowlisted tasks:

| executable key | Purpose |
|---|---|
| `homebase_port_diagnose` | Inspect git state, URLACL snippets, and port 8080 owner. |
| `homebase_repair_smoke` | Pull latest main, run HomeBase repair in smoke mode, then test endpoints. |
| `homebase_repair_real` | Pull latest main, run HomeBase repair with real Ollama Cloud mode, then test endpoints. |
| `homebase_smoke_test` | Run the direct `/api/chat/status` and `/api/chat` smoke tester. |

`maxParallelProcesses` is set to `1` because HomeBase uses a stateful repo path and a single local port.

## VIKTOR app example

```python
import viktor as vkt
from viktor.external.generic import GenericAnalysis


def run_homebase_repair_smoke():
    analysis = GenericAnalysis(
        files=[],
        executable_key="homebase_repair_smoke",
        output_filenames=["output.txt", "diagnostics.json"],
    )
    analysis.execute(timeout=180)
    output_txt = analysis.get_output_file("output.txt")
    diagnostics_json = analysis.get_output_file("diagnostics.json")
    return output_txt, diagnostics_json
```

## Testing with VIKTOR

Use VIKTOR's `mock_GenericAnalysis` in app tests:

```python
import unittest
import viktor as vkt
from viktor.testing import mock_GenericAnalysis


class TestHomeBaseWorker(unittest.TestCase):
    @mock_GenericAnalysis(get_output_file={
        "output.txt": vkt.File.from_data(b"RESULT: OK"),
        "diagnostics.json": vkt.File.from_data(b'{"ok": true}'),
    })
    def test_worker_call(self):
        # call your VIKTOR controller/action here
        pass
```

## Security notes

- Do not add an arbitrary shell executable key.
- Keep all tasks explicit and allowlisted.
- Do not pass API keys as input files or output them.
- Use least-privilege worker permissions.
- Restart the VIKTOR worker after editing `config.yaml`.

## Current HomeBase relevance

For the current `Thinking...` issue, use this order:

1. `homebase_port_diagnose`
2. `homebase_repair_smoke`
3. `homebase_smoke_test`
4. only after smoke passes, `homebase_repair_real`

Smoke mode proves the local HomeBase route before any Ollama Cloud call is involved.
