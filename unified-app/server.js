import express from 'express';
import cors from 'cors';
import { Client } from '@notionhq/client';
import { fileURLToPath } from 'url';
import { join } from 'path';
import { readFileSync, appendFileSync, existsSync, statSync } from 'fs';
import { spawn } from 'child_process';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const app = express();
const PORT = 3000;

app.use(cors());
app.use(express.json());

// Notion config
const NOTION_KEY = process.env.NOTION_API_KEY || process.env.GEMINI_API_KEY;
const LOGS_DB_ID = '4ee3980e-62fa-4abe-a716-c7d6656011ba';
const GEMINI_KEY = process.env.GEMINI_API_KEY;

// Local logs config - adjust path for your Victus setup
const LOG_FILE = join(__dirname, '../../homebase-logs.jsonl');

let notion;
if (NOTION_KEY) {
  notion = new Client({ auth: NOTION_KEY });
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

app.get('/api/logs', (req, res) => {
  res.json(CONFIG.logs.map(l => ({ name: l.name, exists: true })));
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
  if (!GEMINI_KEY) {
    return { provider: 'mock', output: 'No GEMINI_API_KEY' };
  }
  const url = `https://generativelanguage.googleapis.com/v1/models/gemini-2.0-flash:generateContent?key=${GEMINI_KEY}`;
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