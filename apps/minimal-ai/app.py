import json
import logging
import os
import subprocess
import sys
import time

import requests
import viktor as vkt

logger = logging.getLogger("viktor")

# ---------------------------------------------------------------------------
# Configuration — read once at startup from env vars, fall back to defaults.
# These are the canonical HomeBase env vars; set them in your shell or a
# .env file before running `viktor start`.
# ---------------------------------------------------------------------------

HB_AI_ENDPOINT   = os.getenv("HB_AI_ENDPOINT",   "http://localhost:11434/v1/chat/completions")
_OLLAMA_BASE     = HB_AI_ENDPOINT.split("/v1/")[0]  # e.g. http://localhost:11434
HB_AI_MODEL      = os.getenv("HB_AI_MODEL",      "qwen2.5:7b-instruct")
HB_AI_TIMEOUT    = int(os.getenv("HB_AI_TIMEOUT_SEC", "300"))
HB_AI_KEEP_ALIVE = os.getenv("HB_AI_KEEP_ALIVE", "30m")

_APP_DIR     = os.path.dirname(os.path.abspath(__file__))
VIKTOR_ROOT  = os.getenv("ATOMARCADE_VIKTOR_ROOT", os.path.join(_APP_DIR, "viktor"))
SCRIPTS_ROOT = os.path.join(VIKTOR_ROOT, "scripts")
TEST_SCRIPT  = os.path.join(SCRIPTS_ROOT, "test.py")

_SYSTEM_PROMPT = (
    "You are HomeBase AI inside Atom's local cockpit. "
    "Be concise, helpful, direct. "
    "Do not pretend to execute commands you have not actually run."
)

logger.info(f"🏠 HomeBase starting — endpoint={HB_AI_ENDPOINT} model={HB_AI_MODEL}")
logger.info(f"📁 VIKTOR scripts root: {SCRIPTS_ROOT}")


# ---------------------------------------------------------------------------
# /api/chat/status  — ping Ollama's /api/tags with a 2-second timeout
# ---------------------------------------------------------------------------
def _ollama_status() -> dict:
    tags_url = f"{_OLLAMA_BASE}/api/tags"
    reachable = False
    try:
        resp = requests.get(tags_url, timeout=2)
        reachable = resp.status_code == 200
        logger.info(f"🔍 Ollama /api/tags → HTTP {resp.status_code}")
    except Exception as exc:
        logger.warning(f"⚠️ Ollama unreachable: {exc}")

    return {
        "ok":               reachable,
        "provider":         "ollama",
        "endpoint":         HB_AI_ENDPOINT,
        "model":            HB_AI_MODEL,
        "ollama_reachable": reachable,
    }


# ---------------------------------------------------------------------------
# /api/chat  — POST { message } -> { ok, reply, meta }
# ---------------------------------------------------------------------------
def _chat(message: str) -> dict:
    payload = {
        "model":      HB_AI_MODEL,
        "stream":     False,
        "keep_alive": HB_AI_KEEP_ALIVE,
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user",   "content": message},
        ],
    }

    logger.info(f"💬 Sending to Ollama: model={HB_AI_MODEL} message_len={len(message)}")
    t0 = time.time()
    try:
        resp = requests.post(HB_AI_ENDPOINT, json=payload, timeout=HB_AI_TIMEOUT)
        elapsed = round(time.time() - t0, 2)
        logger.info(f"💬 Ollama HTTP {resp.status_code} in {elapsed}s")

        # Surface non-200s as a clear error before attempting json parse.
        if resp.status_code != 200:
            snippet = resp.text[:200].replace("\n", " ").strip()
            return {
                "ok":    False,
                "error": f"Ollama returned HTTP {resp.status_code}: {snippet}",
            }

        data = resp.json()
        reply = (
            data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            or data.get("response", "")   # native Ollama shape fallback
            or json.dumps(data)
        )
        return {"ok": True, "reply": reply, "meta": {"model": HB_AI_MODEL, "elapsed_sec": elapsed}}
    except requests.exceptions.Timeout:
        logger.error("❌ Ollama request timed out")
        return {"ok": False, "error": f"Ollama did not respond within {HB_AI_TIMEOUT}s"}
    except Exception as exc:
        logger.error(f"❌ Chat error: {exc}")
        return {"ok": False, "error": str(exc)}


# ---------------------------------------------------------------------------
# /api/viktor/test  — run viktor/scripts/test.py, auto-create if missing
# ---------------------------------------------------------------------------
_TEST_SCRIPT_CONTENT = '''\
#!/usr/bin/env python3
"""
viktor/scripts/test.py
Canonical HomeBase hello script.
Usage: python test.py --hello homebase
"""
import json
import sys

args = sys.argv[1:]
if "--hello" in args:
    print(json.dumps({
        "ok": True,
        "tool": "viktor.test",
        "message": "Hello from HomeBase -> Viktor script target",
        "args": args,
    }))
else:
    print(json.dumps({"ok": False, "error": "Pass --hello homebase to run the test."}))
    sys.exit(1)
'''


def _ensure_test_script() -> bool:
    if os.path.exists(TEST_SCRIPT):
        return True
    try:
        os.makedirs(SCRIPTS_ROOT, exist_ok=True)
        with open(TEST_SCRIPT, "w", encoding="utf-8") as fh:
            fh.write(_TEST_SCRIPT_CONTENT)
        logger.info(f"📝 Auto-created {TEST_SCRIPT}")
        return True
    except OSError as exc:
        logger.warning(f"⚠️ Cannot create test script (read-only fs?): {exc}")
        return False


def _viktor_test() -> dict:
    _ensure_test_script()
    t0 = time.time()

    if not os.path.exists(TEST_SCRIPT):
        return {
            "ok": False,
            "error": (
                "viktor/scripts/test.py not found. "
                "This feature requires `viktor start` on your local Windows PC. "
                f"Expected path: {TEST_SCRIPT}"
            ),
            "exit_code": -1, "stdout": "", "stderr": "", "elapsed_sec": 0.0,
        }

    try:
        result = subprocess.run(
            [sys.executable, TEST_SCRIPT, "--hello", "homebase"],
            capture_output=True,
            text=True,
            timeout=60,
            cwd=_APP_DIR,  # run from the app's own directory, not the launcher's
        )
        elapsed = round(time.time() - t0, 2)
        ok = result.returncode == 0
        logger.info(f"🚀 test.py exit={result.returncode} elapsed={elapsed}s")

        reply_text = result.stdout.strip()
        try:
            reply = json.loads(reply_text)
        except json.JSONDecodeError:
            reply = reply_text

        return {
            "ok":          ok,
            "reply":       reply,
            "exit_code":   result.returncode,
            "stdout":      result.stdout,
            "stderr":      result.stderr,
            "elapsed_sec": elapsed,
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Script timed out after 60s", "exit_code": -1,
                "stdout": "", "stderr": "", "elapsed_sec": 60.0}
    except Exception as exc:
        return {"ok": False, "error": str(exc), "exit_code": -1,
                "stdout": "", "stderr": "", "elapsed_sec": 0.0}


# ---------------------------------------------------------------------------
# CSS (plain string — no f-string escaping needed)
# ---------------------------------------------------------------------------
_CSS_TEMPLATE = """
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #f0f2f5;
            color: #333;
            padding: 24px;
            max-width: 860px;
        }
        h1 { font-size: 1.8rem; margin-bottom: 4px; color: #1a1a2e; }
        .subtitle { color: #666; margin-bottom: 22px; font-size: 0.9rem; }
        .pills { display: flex; gap: 12px; margin-bottom: 22px; flex-wrap: wrap; }
        .pill {
            display: flex; align-items: center; gap: 8px;
            background: #fff; border-radius: 20px;
            padding: 8px 16px;
            box-shadow: 0 1px 4px rgba(0,0,0,0.08);
            font-size: 0.88rem; font-weight: 600;
        }
        .dot {
            width: 10px; height: 10px; border-radius: 50%;
            background: __STATUS_COLOR__; flex-shrink: 0;
        }
        .pill-detail { color: #888; font-weight: 400; font-size: 0.8rem; }
        .card {
            background: #fff; border-radius: 10px;
            padding: 20px 24px; margin-bottom: 18px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.07);
        }
        .card h3 {
            margin-bottom: 12px; font-size: 1rem; color: #1a1a2e;
            display: flex; align-items: baseline; gap: 10px;
        }
        .meta { color: #aaa; font-size: 0.78rem; font-weight: 400; }
        .card.warning { border-left: 4px solid #f39c12; }
        .card.success { border-left: 4px solid #2ecc71; }
        .response-text { line-height: 1.65; white-space: pre-wrap; word-break: break-word; font-size: 0.95rem; }
        table { width: 100%; border-collapse: collapse; margin-bottom: 14px; }
        th, td { text-align: left; padding: 7px 12px; border-bottom: 1px solid #eee; font-size: 0.9rem; }
        th { width: 110px; color: #555; font-weight: 600; }
        pre {
            background: #f8f9fa; border-radius: 6px; padding: 12px;
            font-size: 0.82rem; overflow-x: auto; color: #2c3e50;
            border: 1px solid #e9ecef;
        }
        code { background: #f0f2f5; padding: 1px 5px; border-radius: 3px; font-size: 0.88rem; }
        .hint { color: #999; font-size: 0.82rem; margin-top: 6px; }
"""


# ---------------------------------------------------------------------------
# Parametrization
# ---------------------------------------------------------------------------
class Parametrization(vkt.Parametrization):
    """Single-page cockpit UI for Atomind HomeBase."""

    page = vkt.Page("HomeBase", views=["homebase_view"])

    page.chat_message = vkt.TextAreaField(
        "Chat Message",
        default="hi",
        description="Type a message — app.py sends it directly to your local Ollama.",
    )

    page.run_viktor_test = vkt.SetParamsButton(
        "🚀 Run VIKTOR Test",
        method="run_viktor_test",
        description="Run viktor/scripts/test.py and display the JSON result.",
    )


# ---------------------------------------------------------------------------
# Controller
# ---------------------------------------------------------------------------
class Controller(vkt.Controller):
    """
    Atomind HomeBase cockpit controller.

    Deployment: run locally with `viktor start` so that localhost:11434
    resolves to the operator's own Ollama instance.
    """

    parametrization = Parametrization

    def run_viktor_test(self, params, **kwargs):
        result = _viktor_test()
        logger.info(f"🚀 VIKTOR test complete: ok={result.get('ok')}")
        return vkt.SetParamsResult(
            {"chat_message": json.dumps(result, indent=2)}
        )

    @vkt.WebView("HomeBase Dashboard")
    def homebase_view(self, params, **kwargs):
        # 1. Ollama status
        status = _ollama_status()
        reachable     = status["ollama_reachable"]
        status_color  = "#2ecc71" if reachable else "#e74c3c"
        status_label  = "✅ Ollama reachable" if reachable else "❌ Ollama unreachable"
        status_detail = f"{HB_AI_MODEL} @ {_OLLAMA_BASE}"

        # 2. Chat
        raw_message = (params.page.chat_message or "").strip()
        chat_response_html = ""

        is_json_blob = False
        parsed_json = None
        try:
            parsed_json = json.loads(raw_message)
            is_json_blob = isinstance(parsed_json, dict)
        except (json.JSONDecodeError, TypeError):
            pass

        if raw_message and not is_json_blob:
            if reachable:
                chat_result = _chat(raw_message)
                if chat_result["ok"]:
                    reply_text = chat_result["reply"]
                    meta       = chat_result.get("meta", {})
                    elapsed    = meta.get("elapsed_sec", "?")
                    chat_response_html = (
                        '<div class="card">'
                        '<h3>💬 Chat Response '
                        f'<span class="meta">{HB_AI_MODEL} · {elapsed}s</span>'
                        '</h3>'
                        f'<p class="response-text">{reply_text}</p>'
                        '</div>'
                    )
                else:
                    err = chat_result.get("error", "unknown error")
                    chat_response_html = (
                        '<div class="card warning">'
                        '<h3>💬 Chat Error</h3>'
                        f'<p>{err}</p>'
                        '</div>'
                    )
            else:
                chat_response_html = (
                    '<div class="card warning">'
                    '<h3>💬 Chat</h3>'
                    f'<p>Ollama is not reachable at <code>{_OLLAMA_BASE}</code>. '
                    'Make sure Ollama is running (<code>ollama serve</code>) and the model '
                    f'is pulled (<code>ollama pull {HB_AI_MODEL}</code>).</p>'
                    '</div>'
                )

        # 3. VIKTOR test result card
        viktor_result_html = ""
        if is_json_blob and parsed_json is not None:
            ok_icon  = "✅" if parsed_json.get("ok") else "❌"
            reply_val = parsed_json.get("reply", {})
            tool_name = (
                reply_val.get("tool") if isinstance(reply_val, dict)
                else parsed_json.get("tool", "viktor.test")
            )
            msg_val = (
                reply_val.get("message") if isinstance(reply_val, dict)
                else parsed_json.get("message", "")
            )
            elapsed_val = parsed_json.get("elapsed_sec", "?")
            exit_code   = parsed_json.get("exit_code", "?")

            viktor_result_html = (
                '<div class="card success">'
                '<h3>🚀 VIKTOR Test Result</h3>'
                '<table>'
                f'<tr><th>ok</th><td>{ok_icon} {parsed_json.get("ok")}</td></tr>'
                f'<tr><th>tool</th><td>{tool_name}</td></tr>'
                f'<tr><th>message</th><td>{msg_val}</td></tr>'
                f'<tr><th>exit_code</th><td>{exit_code}</td></tr>'
                f'<tr><th>elapsed</th><td>{elapsed_val}s</td></tr>'
                '</table>'
                f'<pre>{json.dumps(parsed_json, indent=2)}</pre>'
                '</div>'
            )

        # 4. Idle hint
        if chat_response_html or viktor_result_html:
            idle_card = ""
        else:
            idle_card = (
                '<div class="card">'
                '<h3>👋 Ready</h3>'
                '<p class="response-text">Type a message in the left panel and click <strong>Update</strong> to chat with Ollama.<br>'
                'Click <strong>🚀 Run VIKTOR Test</strong> to execute the hello script.</p>'
                f'<p class="hint" style="margin-top:12px">Test script: <code>{TEST_SCRIPT}</code></p>'
                f'<p class="hint">Ollama must be running: <code>ollama serve</code> then <code>ollama pull {HB_AI_MODEL}</code>.</p>'
                '</div>'
            )

        # 5. Render HTML by concatenation (avoids f-string brace escaping)
        css = _CSS_TEMPLATE.replace("__STATUS_COLOR__", status_color)
        body_html = (
            '<h1>🏠 Atomind HomeBase</h1>'
            f'<p class="subtitle">Local AI Cockpit · <code>viktor start</code> · {_OLLAMA_BASE}</p>'
            '<div class="pills">'
            '<div class="pill">'
            '<div class="dot"></div>'
            f'<span>{status_label}</span>'
            f'<span class="pill-detail">{status_detail}</span>'
            '</div>'
            '</div>'
            + chat_response_html
            + viktor_result_html
            + idle_card
        )
        html = (
            '<!DOCTYPE html>\n'
            '<html lang="en">\n'
            '<head>\n'
            '<meta charset="UTF-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
            '<title>Atomind HomeBase</title>\n'
            '<style>' + css + '</style>\n'
            '</head>\n'
            '<body>\n'
            + body_html
            + '\n</body>\n</html>\n'
        )

        return vkt.WebResult(html=html)
