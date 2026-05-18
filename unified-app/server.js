// ╔══════════════════════════════════════════════════════════════╗
// ║  atomeam-stack — unified-app/server.js                      ║
// ║  Includes: Keys, Notion Sync, Alpha Loop, Real-Time Logs, Health   ║
// ╚══════════════════════════════════════════════════════════════╝

import "dotenv/config";
import express from "express";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { Client } from "@notionhq/client";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

// ── CONFIGURATION ─────────────────────────────────────────────────
const CONFIG = {
  geminiKey: process.env.GEMINI_API_KEY,
  notionKey: process.env.NOTION_API_KEY,
  logDbId: process.env.ATOMARCADE_NOTION_LOG_DB_ID,
  aiModel: process.env.HB_AI_MODEL || "gpt-oss:20b",
  ollamaUrl: process.env.OLLAMA_URL || "http://localhost:11434",
  logFile: process.env.HB_LOG_FILE || "C:\\AtomArcade\\homebase-logs.jsonl",
  port: process.env.PORT || 3000,
};

// ── STARTUP ENV VALIDATION ──────────────────────────────────────────
const REQUIRED_ENV_VARS = ["NOTION_API_KEY", "ATOMARCADE_NOTION_LOG_DB_ID"];
const OPTIONAL_ENV_VARS = ["GEMINI_API_KEY", "OLLAMA_URL", "HB_AI_MODEL", "HB_LOG_FILE"];

function validateEnvVars() {
  const results = { required: [], optional: [] };
  const now = Date.now();
  
  for (const key of REQUIRED_ENV_VARS) {
    const value = process.env[key];
    const ok = !!value;
    results.required.push({ key, ok, value: ok ? "(set)" : null });
    if (!ok) console.error(`[Env] MISSING required variable: ${key}`);
  }
  
  for (const key of OPTIONAL_ENV_VARS) {
    const value = process.env[key];
    const ok = !!value;
    results.optional.push({ key, ok, value: ok ? "(set)" : null });
    if (!ok) console.warn(`[Env] OPTIONAL variable not set: ${key}`);
  }
  
  const allRequired = results.required.every(r => r.ok);
  if (!allRequired) {
    console.warn(`[Env] Some required vars missing - some features may not work`);
  } else {
    console.log(`[Env] All required environment variables validated`);
  }
  
  return results;
}

const envValidation = validateEnvVars();

const GEMINI_KEY  = CONFIG.geminiKey;
const NOTION_KEY  = CONFIG.notionKey;
const LOG_DB_ID  = CONFIG.logDbId;
const AI_MODEL  = CONFIG.aiModel;
const OLLAMA_URL = CONFIG.ollamaUrl;
const LOG_FILE  = CONFIG.logFile;
const PORT      = CONFIG.port;

// ── NOTION CLIENT ─────────────────────────────────────────────────────────────
const notion = NOTION_KEY ? new Client({ auth: NOTION_KEY }) : null;

// ── NOTION SYNC ───────────────────────────────────────────────────────────────
async function appendLogEntry({
  event, level = "info", kind = "", source = "unified-app",
  executor = "unified-app@localhost", intent = "", outcome = "success",
  mode = "apply", payload = null, trace_id = null,
  reason_code = null, latency_ms = null,
}) {
  await notion.pages.create({
    parent: { database_id: LOG_DB_ID },
    properties: {
      Event:    { title:      [{ text: { content: event } }] },
      Timestamp:{ date:       { start: new Date().toISOString() } },
      Level:    { select:     { name: level } },
      Kind:     { rich_text:  [{ text: { content: kind } }] },
      Source:   { rich_text:  [{ text: { content: source } }] },
      Executor: { rich_text:  [{ text: { content: executor } }] },
      intent:   { rich_text:  [{ text: { content: intent } }] },
      outcome:  { select:     { name: outcome } },
      mode:     { select:     { name: mode } },
      ...(payload     && { Payload:     { rich_text: [{ text: { content: typeof payload === "object" ? JSON.stringify(payload) : payload } }] } }),
      ...(trace_id    && { trace_id:    { rich_text: [{ text: { content: trace_id } }] } }),
      ...(reason_code && { reason_code: { rich_text: [{ text: { content: reason_code } }] } }),
      ...(latency_ms !== null && { latency_ms: { number: latency_ms } }),
    },
  });
}

// ── AI ORCHESTRATOR: Ollama → Gemini → Mock ───────────────────────────────────
async function runAlphaOrchestrator({ prompt, systemInstruction, intent, trace_id }) {
  const start = Date.now();
  const sys = systemInstruction || "You are an adaptive context engine runner.";

  // 1. Ollama (local, free)
  try {
    const res = await fetch(`${OLLAMA_URL}/api/generate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: AI_MODEL, prompt, system: sys, stream: false }),
    });
    if (res.ok) {
      const d = await res.json();
      return { success: true, mock: false, provider: "ollama", model: d.model, text: d.response, trace_id, latency_ms: Date.now() - start };
    }
  } catch (e) { console.warn("[Alpha] Ollama unavailable:", e.message); }

  // 2. Gemini (fallback)
  if (GEMINI_KEY) {
    try {
      const res = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${GEMINI_KEY}`,
        { method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] }) }
      );
      if (res.ok) {
        const d = await res.json();
        const text = d.candidates?.[0]?.content?.parts?.[0]?.text || "";
        return { success: true, mock: false, provider: "gemini", model: "gemini-2.0-flash", text, trace_id, latency_ms: Date.now() - start };
      }
    } catch (e) { console.warn("[Alpha] Gemini unavailable:", e.message); }
  }

  // 3. Mock (last resort)
  return { success: true, mock: true, provider: "mock", model: "mock", text: `[MOCK] Echo: ${prompt}`, trace_id, latency_ms: Date.now() - start };
}

// ── ROUTES: KEYS ──────────────────────────────────────────────────────────────
app.get("/api/keys", (req, res) => res.json({
  GEMINI: GEMINI_KEY ? "loaded" : "missing",
  NOTION: NOTION_KEY ? "loaded" : "missing",
  FAIL_FAST: false,
  checkedAt: new Date().toISOString(),
}));

app.get("/api/keys/notion/test", async (req, res) => {
  if (!NOTION_KEY) return res.json({ ok: false, error: "No NOTION_API_KEY" });
  try {
    const u = await notion.users.me();
    res.json({ ok: true, user: u.name });
  } catch (e) { res.json({ ok: false, error: e.message }); }
});

app.get("/api/keys/gemini/test", async (req, res) => {
  if (!GEMINI_KEY) return res.json({ success: false, error: "No GEMINI_API_KEY" });
  try {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_KEY}`);
    const d = await r.json();
    res.json({ success: true, models: d.models?.length ?? 0 });
  } catch (e) { res.json({ success: false, error: e.message }); }
});

// ── ROUTES: NOTION LOG ────────────────────────────────────────────────────────
app.post("/api/notion/log", async (req, res) => {
  if (!NOTION_KEY)  return res.status(500).json({ ok: false, error: "No NOTION_API_KEY" });
  if (!LOG_DB_ID)   return res.status(500).json({ ok: false, error: "No ATOMARCADE_NOTION_LOG_DB_ID" });
  if (!req.body.event) return res.status(400).json({ ok: false, error: "event is required" });
  try { await appendLogEntry(req.body); res.json({ ok: true }); }
  catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── ROUTES: STATUS ────────────────────────────────────────────────────────────
app.get("/api/status", (req, res) => res.json({
  timestamp: new Date().toISOString(),
  uptime_s: Math.floor(process.uptime()),
  keys: { gemini: !!GEMINI_KEY, notion: !!NOTION_KEY },
  ai: { model: AI_MODEL, ollama: OLLAMA_URL },
  logFile: LOG_FILE,
}));

// ── ROUTES: HEALTH ─────────────────────────────────────────────────
const version = "1.0.0";

async function checkEnv() {
  const start = Date.now();
  const missing = REQUIRED_ENV_VARS.filter(key => !process.env[key]);
  return {
    ok: missing.length === 0,
    detail: missing.length > 0 ? `Missing: ${missing.join(", ")}` : "all required vars present",
    latencyMs: Date.now() - start,
    missing
  };
}

async function checkNotion() {
  const start = Date.now();
  if (!NOTION_KEY) {
    return { ok: false, detail: "not configured", latencyMs: Date.now() - start };
  }
  try {
    // Deep check: verify token AND database is accessible
    await notion.users.me(); // Basic auth check
    
    // Query the target DB to verify it's shared with the integration
    if (LOG_DB_ID) {
      await notion.databases.query({
        database_id: LOG_DB_ID,
        page_size: 1,
      });
    }
    return { ok: true, detail: "connected (DB verified)", latencyMs: Date.now() - start };
  } catch (e) {
    // Parse specific error types
    let detail = e.message;
    if (e.code === 'object_not_found' || e.message.includes('not found')) {
      detail = "Database not found or not shared with integration";
    } else if (e.message.includes('Unauthorized') || e.message.includes('invalid')) {
      detail = "Token invalid or expired";
    } else if (e.message.includes('permission')) {
      detail = "Permission denied to database";
    }
    return { ok: false, detail, latencyMs: Date.now() - start };
  }
}

async function checkOllama() {
  const start = Date.now();
  try {
    const res = await fetch(`${OLLAMA_URL}/api/tags`, { method: "GET" });
    if (!res.ok) {
      return { ok: false, detail: `HTTP ${res.status}`, latencyMs: Date.now() - start };
    }
    
    const data = await res.json();
    const modelNames = (data.models || []).map(m => m.name || m.model);
    
    // Check if configured model exists
    if (AI_MODEL) {
      const modelFound = modelNames.some(name => 
        name === AI_MODEL || name.startsWith(AI_MODEL.split(':')[0])
      );
      if (!modelFound) {
        return { 
          ok: false, 
          detail: `Model "${AI_MODEL}" not found locally. Available: ${modelNames.slice(0, 5).join(', ')}${modelNames.length > 5 ? '...' : ''}`,
          latencyMs: Date.now() - start 
        };
      }
      return { ok: true, detail: `Model "${AI_MODEL}" ready (${modelNames.length} available)`, latencyMs: Date.now() - start };
    }
    
    return { ok: true, detail: `${modelNames.length} models loaded`, latencyMs: Date.now() - start };
  } catch (e) {
    return { ok: false, detail: e.message, latencyMs: Date.now() - start };
  }
}

async function checkGemini() {
  const start = Date.now();
  if (!GEMINI_KEY) {
    return { ok: false, detail: "not configured", latencyMs: Date.now() - start };
  }
  try {
    const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_KEY}`);
    if (res.ok) {
      const data = await res.json();
      return { ok: true, detail: `${data.models?.length || 0} models available`, latencyMs: Date.now() - start };
    }
    return { ok: false, detail: `HTTP ${res.status}`, latencyMs: Date.now() - start };
  } catch (e) {
    return { ok: false, detail: e.message, latencyMs: Date.now() - start };
  }
}

app.get("/api/health", async (req, res) => {
  const [env, notion, ollama, gemini] = await Promise.all([
    checkEnv(),
    checkNotion(),
    checkOllama(),
    checkGemini()
  ]);
  
  const checks = { env, notion, ollama, gemini };
  const ok = env.ok && notion.ok && ollama.ok && gemini.ok;
  
  res.json({
    ok,
    version,
    timestamp: new Date().toISOString(),
    checks
  });
});

// ── ROUTES: ALPHA LOOP ────────────────────────────────────────────────────────
async function handleAlphaRun(req, res) {
  const result = await runAlphaOrchestrator(req.body);
  // Auto-log every run to Notion Bridge Logs
  if (LOG_DB_ID && NOTION_KEY) {
    appendLogEntry({
      event:     `Alpha run — ${req.body.intent || "observer"}`,
      level:     result.success ? "info" : "error",
      kind:      "alpha-loop",
      source:    "unified-app",
      intent:    req.body.intent || "observer",
      outcome:   result.success ? "success" : "failure",
      trace_id:  req.body.trace_id || null,
      latency_ms: result.latency_ms,
      payload:   { provider: result.provider, model: result.model },
    }).catch(e => console.warn("[Notion] log error:", e.message));
  }
  res.json(result);
}
app.post("/api/run/observer", handleAlphaRun);
app.post("/api/alpha/run",    handleAlphaRun);

// ── OPTION C: REAL-TIME LOG STREAM (SSE) ──────────────────────────────────────
const SSE_CLIENTS = new Set();

function getRecentLogs(n = 50) {
  try {
    if (!fs.existsSync(LOG_FILE)) return [];
    const lines = fs.readFileSync(LOG_FILE, "utf8").trim().split("\n").filter(Boolean);
    return lines.slice(-n).map(l => { try { return JSON.parse(l); } catch { return { raw: l }; } });
  } catch (e) { return [{ error: e.message }]; }
}

// GET /api/logs/recent — last N lines as JSON array
app.get("/api/logs/recent", (req, res) => {
  const n = Math.min(parseInt(req.query.n) || 50, 200);
  res.json({ logs: getRecentLogs(n), file: LOG_FILE });
});

// GET /api/logs/stream — live SSE feed
app.get("/api/logs/stream", (req, res) => {
  res.setHeader("Content-Type",  "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection",    "keep-alive");
  res.flushHeaders();

  // Replay last 20 lines on connect so the UI isn't blank
  for (const log of getRecentLogs(20)) {
    res.write(`data: ${JSON.stringify(log)}\n\n`);
  }

  SSE_CLIENTS.add(res);
  req.on("close", () => SSE_CLIENTS.delete(res));
});

// Tail the log file — broadcast new lines to all SSE clients
let lastSize = 0;
function watchLogFile() {
  if (!fs.existsSync(LOG_FILE)) {
    setTimeout(watchLogFile, 5000); // retry until the file appears
    return;
  }
  lastSize = fs.statSync(LOG_FILE).size;
  console.log(`[LogStream] Watching ${LOG_FILE}`);

  fs.watch(LOG_FILE, (event) => {
    if (event !== "change") return;
    try {
      const { size } = fs.statSync(LOG_FILE);
      if (size <= lastSize) return;
      const stream = fs.createReadStream(LOG_FILE, { start: lastSize, end: size });
      let buf = "";
      stream.on("data", c => buf += c);
      stream.on("end", () => {
        lastSize = size;
        for (const line of buf.trim().split("\n").filter(Boolean)) {
          let parsed;
          try { parsed = JSON.parse(line); } catch { parsed = { raw: line }; }
          const msg = `data: ${JSON.stringify(parsed)}\n\n`;
          for (const client of SSE_CLIENTS) {
            try { client.write(msg); } catch { SSE_CLIENTS.delete(client); }
          }
        }
      });
    } catch (e) { console.warn("[LogStream] error:", e.message); }
  });
}
watchLogFile();

// ── START ─────────────────────────────────────────────────────────────────────
app.listen(PORT, () => console.log(`atomeam-stack running at http://localhost:${PORT}`));