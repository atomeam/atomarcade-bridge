import express from 'express';
import cors from 'cors';
import { Client } from '@notionhq/client';
import { fileURLToPath } from 'url';
import { join } from 'path';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const app = express();
const PORT = 3000;

app.use(cors());
app.use(express.json());

// Notion config
const NOTION_KEY = process.env.NOTION_API_KEY || process.env.GEMINI_API_KEY;
const LOGS_DB_ID = '4ee3980e-62fa-4abe-a716-c7d6656011ba';

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

app.use(express.static(join(__dirname, 'public')));

app.listen(PORT, () => {
  console.log(`atomeam-stack running at http://localhost:${PORT}`);
});