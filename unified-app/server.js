import express from 'express';
import cors from 'cors';
import { Client } from '@notionhq/client';
import { fileURLToPath } from 'url';
import { join } from 'path';
import { readFileSync, appendFileSync, existsSync, statSync } from 'fs';
import { spawn } from 'child_process';
import dotenv from 'dotenv';

// Load local .env
dotenv.config({ path: join(fileURLToPath(new URL('.', import.meta.url)), '.env') });

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const app = express();
const PORT = 3000;

app.use(cors());
app.use(express.json());

// Key validation at startup
const FAIL_FAST = process.env.FAIL_FAST === '1';
const KEYS = {
  GEMINI: process.env.GEMINI_API_KEY,
  NOTION: process.env.NOTION_API_KEY
};

const KEY_STATUS = {
  GEMINI: KEYS.GEMINI ? 'loaded' : 'missing',
  NOTION: KEYS.NOTION ? 'loaded' : 'missing',
  FAIL_FAST,
  checkedAt: new Date().toISOString()
};

// Fail fast check
if (FAIL_FAST && (!KEYS.GEMINI || !KEYS.NOTION)) {
  const missing = [];
  if (!KEYS.GEMINI) missing.push('GEMINI_API_KEY');
  if (!KEYS.NOTION) missing.push('NOTION_API_KEY');
  throw new Error(`❌ FATAL: Missing required keys: ${missing.join(', ')}`);
}

console.log(FAIL_FAST ? "[Keys] FAIL_FAST mode - keys required" : `[Keys] GEMINI: ${KEY_STATUS.GEMINI}, NOTION: ${KEY_STATUS.NOTION}`);

// Endpoint: Check key status
app.get('/api/keys', (req, res) => {
  res.json(KEY_STATUS);
});

// Endpoint: Test Gemini (simple call)
app.get('/api/keys/gemini/test', async (req, res) => {
  if (!KEYS.GEMINI) {
    return res.json({ error: 'GEMINI_API_KEY not set', success: false });
  }
  try {
    const url = `https://generativelanguage.googleapis.com/v1/models?key=${KEYS.GEMINI}`;
    const resp = await fetch(url);
    const data = await resp.json();
    const ok = resp.ok && !data.error;
    res.json({ success: ok, error: data.error, models: data.models?.length || 0 });
  } catch (e) {
    res.json({ success: false, error: e.message });
  }
});

// Endpoint: Test Notion (ping)
app.get('/api/keys/notion/test', async (req, res) => {
  if (!KEYS.NOTION) {
    return res.json({ error: 'NOTION_API_KEY not set', success: false });
  }
  try {
    const notion = new Client({ auth: KEYS.NOTION });
    await notion.users.me();
    res.json({ success: true });
  } catch (e) {
    res.json({ success: false, error: e.message });
  }
});

// Notion config (for actual API calls)
const LOGS_DB_ID = '4ee3980e-62fa-4abe-a716-c7d6656011ba';

// Local logs config - adjust path for your Victus setup
const LOG_FILE = join(__dirname, '../../homebase-logs.jsonl');
const APPS_DIR = join(__dirname, '../..');
const SCRIPTS = {
  'homebase': join(APPS_DIR, 'homebase-launcher.ps1'),
  'bridge': join(APPS_DIR, 'launch-homebase.ps1'),
  'install': join(APPS_DIR, 'install-edge-app.ps1')
};

// Check local repo status (no API key needed)
app.get('/api/repos/check', (req, res) => {
  const results = [];
  for (const repo of CONFIG.repos) {
    const repoPath = join(APPS_DIR, repo.name);
    const hasDir = existsSync(repoPath);
    let lastCommit = null;
    if (hasDir && existsSync(join(repoPath, '.git'))) {
      try {
        const head = readFileSync(join(repoPath, '.git', 'HEAD'), 'utf-8').trim();
        lastCommit = head.substring(0, 7);
      } catch { lastCommit = null; }
    }
    results.push({ name: repo.name, exists: hasDir, hasGit: hasDir && existsSync(join(repoPath, '.git')), branch: lastCommit });
  }
  res.json({ repos: results, checkedAt: new Date().toISOString() });
});

// Run a local script (no API key needed)
app.post('/api/run-script/:name', (req, res) => {
  const { name } = req.params;
  const scriptPath = SCRIPTS[name];
  if (!scriptPath || !existsSync(scriptPath)) {
    return res.json({ error: 'Script not found', valid: Object.keys(SCRIPTS) });
  }
  
  logToFile({ step: `script:${name}`, status: 'running', message: `Running ${name}...` });
  
  const isWin = process.platform === 'win32';
  const proc = spawn(isWin ? 'powershell' : 'pwsh', ['-ExecutionPolicy', 'Bypass', '-File', scriptPath], { cwd: APPS_DIR });
  
  let output = '';
  proc.stdout.on('data', d => output += d);
  proc.stderr.on('data', d => output += d);
  
  proc.on('close', code => {
    logToFile({ step: `script:${name}`, status: code === 0 ? 'success' : 'error', output: output.substring(0, 500) });
    res.json({ name, exitCode: code, output: output.substring(0, 500) });
  });
  
  proc.on('error', err => {
    logToFile({ step: `script:${name}`, status: 'error', error: err.message });
    res.json({ name, error: err.message });
  });
});

let notion;
if (KEYS.NOTION) {
  notion = new Client({ auth: KEYS.NOTION });
}

// Config
const CONFIG = {
  repos: [
    { name: 'atomarcade-bridge', path: '../atomarcade-bridge' },
    { name: 'Aether', path: '../Aether' },
    { name: 'ALPHA', path: '../ALPHA' }
  ],
  logs: [
    { name: 'HomeBase Logs', path: '../atomarcade-bridge/homebase-logs.jsonl' },
    { name: 'Bridge Logs', path: '../atomarcade-bridge/homebase-chat.jsonl' }
  ],
  tools: [
    { name: 'HomeBase', file: '../atomarcade-bridge/homebase.ps1', cmd: 'pwsh' },
    { name: 'Recovery', file: '../atomarcade-bridge/tools/fresh-start-homebase-recovery.ps1', cmd: 'pwsh' }
  ]
};

app.get('/api/status', (req, res) => {
  res.json({
    timestamp: new Date().toISOString(),
    summary: {
      totalRepos: CONFIG.repos.length,
      totalLogs: CONFIG.logs.length,
      totalTools: CONFIG.tools.length
    },
    notion: {
      connected: !!notion,
      db: LOGS_DB_ID
    }
  });
});

app.get('/api/repos', (req, res) => {
  res.json(CONFIG.repos.map(r => ({ name: r.name, exists: true })));
});

app.get('/api/tools', (req, res) => {
  res.json(CONFIG.tools);
});

// Log files config
app.get('/api/log-files', (req, res) => {
  res.json(CONFIG.logs.map(l => ({ name: l.name, exists: true })));
});

// Read local logs with filtering
app.get('/api/logs', (req, res) => {
  try {
    if (!existsSync(LOG_FILE)) {
      return res.json({ entries: [], file: LOG_FILE, note: 'File not found yet' });
    }
    const content = readFileSync(LOG_FILE, 'utf-8');
    const allEntries = content.trim().split('\n').map(line => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean).reverse();
    
    // Filter by step/status if provided
    const { step, status, limit } = req.query;
    let entries = allEntries;
    if (step) entries = entries.filter(e => e.step === step);
    if (status) entries = entries.filter(e => e.status === status);
    if (limit) entries = entries.slice(0, parseInt(limit));
    
    res.json({ 
      entries, 
      count: entries.length, 
      total: allEntries.length,
      file: LOG_FILE,
      filters: { step, status }
    });
  } catch (e) {
    res.json({ error: e.message, entries: [], file: LOG_FILE });
  }
});

// Stream logs (Server-Sent Events)
app.get('/api/logs/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/eventstream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  
  try {
    if (existsSync(LOG_FILE)) {
      const content = readFileSync(LOG_FILE, 'utf-8');
      const entries = content.trim().split('\n').slice(-10).map(line => {
        try { return JSON.parse(line); } catch { return null; }
      }).filter(Boolean).reverse();
      res.write(`data: ${JSON.stringify({ type: 'init', entries })}\n\n`);
    }
  } catch (e) {
    res.write(`data: ${JSON.stringify({ type: 'error', error: e.message })}\n\n`);
  }
  
  const interval = setInterval(() => {
    res.write(`data: ${JSON.stringify({ type: 'ping', ts: new Date().toISOString() })}\n\n`);
  }, 15000);
  
  req.on('close', () => clearInterval(interval));
});

// Notion logs endpoint
app.get('/api/notion/logs', async (req, res) => {
  if (!notion) {
    return res.json({ error: 'No Notion API key', logs: [] });
  }
  try {
    const response = await notion.databases.query({
      database_id: LOGS_DB_ID,
      sorts: [{ timestamp: 'created_time', direction: 'descending' }],
      page_size: 10
    });
    const logs = response.results.map(page => ({
      id: page.id,
      created: page.created_time,
      properties: page.properties
    }));
    res.json({ logs });
  } catch (e) {
    res.json({ error: e.message, logs: [] });
  }
});

// Read local logs
app.get('/api/logs', (req, res) => {
  try {
    if (!existsSync(LOG_FILE)) {
      return res.json({ entries: [], file: LOG_FILE });
    }
    const content = readFileSync(LOG_FILE, 'utf-8');
    const entries = content.trim().split('\n').slice(-50).map(line => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean).reverse();
    res.json({ entries, count: entries.length, file: LOG_FILE });
  } catch (e) {
    res.json({ error: e.message, entries: [], file: LOG_FILE });
  }
});

// Alpha loop prompts
const ALPHA_PROMPTS = {
  observer: `You are the Observer. Scan recent activity. Identify any anomalies or issues. Output brief JSON.`,
  evaluator: `You are the Evaluator. Given these findings, classify by severity. Output brief JSON.`,
  proposer: `You are the Proposer. Given classifications, generate 1-2 proposals. Output JSON.`,
  curator: `You are the Curator. Review proposals. Apply 5-condition gate. Approve or deny. Output JSON.`
};

// Call Gemini
async function callGemini(prompt) {
  if (!KEYS.GEMINI) {
    return { provider: 'mock', output: 'No GEMINI_API_KEY' };
  }
  const url = `https://generativelanguage.googleapis.com/v1/models/gemini-2.0-flash:generateContent?key=${KEYS.GEMINI}`;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0.7, maxOutputTokens: 2048 }
      })
    });
    const data = await res.json();
    return { provider: 'gemini', output: data.candidates?.[0]?.content?.parts?.[0]?.text || 'No response' };
  } catch (e) {
    return { provider: 'gemini', error: e.message };
  }
}

// Log to file
function logToFile(entry) {
  try {
    appendFileSync(LOG_FILE, JSON.stringify({ ...entry, ts: new Date().toISOString() }) + '\n', 'utf-8');
  } catch (e) { console.error('Log error:', e.message); }
}

// Run Alpha step
app.post('/api/run/:step', async (req, res) => {
  const { step } = req.params;
  if (!ALPHA_PROMPTS[step]) {
    return res.json({ error: 'Unknown step', valid: Object.keys(ALPHA_PROMPTS) });
  }
  
  logToFile({ step, status: 'running', message: `Running ${step}...` });
  const result = await callGemini(ALPHA_PROMPTS[step]);
  logToFile({ step, status: 'success', message: `Completed ${step}`, output: result.output });
  
  res.json({ step, ...result });
});

// Run full Alpha loop
app.post('/api/run/alpha-loop', async (req, res) => {
  logToFile({ step: 'alpha-loop', status: 'running', message: 'Starting Alpha loop...' });
  
  const results = [];
  
  // Observer
  const obs = await callGemini(ALPHA_PROMPTS.observer);
  logToFile({ step: 'observer', status: 'success', output: obs.output });
  results.push({ step: 'observer', ...obs });
  
  // If mock, stop here
  if (obs.provider === 'mock') {
    logToFile({ step: 'alpha-loop', status: 'mock', message: 'No API key - used mock' });
    return res.json({ results, note: 'Mock mode - no API key' });
  }
  
  // Evaluator
  const evaluateResult = await callGemini(ALPHA_PROMPTS.evaluator);
  logToFile({ step: 'evaluator', status: 'success', output: evaluateResult.output });
  results.push({ step: 'evaluator', ...evaluateResult });
  
  // Proposer
  const prop = await callGemini(ALPHA_PROMPTS.proposer);
  logToFile({ step: 'proposer', status: 'success', output: prop.output });
  results.push({ step: 'proposer', ...prop });
  
  // Curator
  const cur = await callGemini(ALPHA_PROMPTS.curator);
  logToFile({ step: 'curator', status: 'success', output: cur.output });
  results.push({ step: 'curator', ...cur });
  
  logToFile({ step: 'alpha-loop', status: 'success', message: 'Alpha loop complete' });
  
  res.json({ results });
});

app.use(express.static(join(__dirname, 'public')));

app.listen(PORT, () => {
  console.log(`atomeam-stack running at http://localhost:${PORT}`);
});