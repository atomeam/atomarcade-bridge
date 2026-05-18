import { readFileSync, appendFileSync, existsSync } from 'fs';
import { join } from 'path';
import { fileURLToPath } from 'url';
import { spawn } from 'child_process';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

// Config
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const LOG_FILE = join(__dirname, '../../homebase-logs.jsonl');

// Prompts for each Alpha step
const PROMPTS = {
  observer: `You are the Observer. Your job is to scan the system state and identify anomalies. 
Output a JSON array of findings with fields: {ts, step, status, message, findings[]}.
Be brief. Focus on what's different from expected.`,
  
  evaluator: `You are the Evaluator. Given these findings: {{findings}}
Classify each by severity: critical, warning, info.
Output JSON with: {ts, step, status, classifications[]}.`,
  
  proposer: `You are the Proposer. Given these classifications: {{classifications}}
Generate 1-3 concrete proposals to address them.
Each proposal needs: id, title, description, risk_level, steps[].
Output JSON with: {ts, step, status, proposals[]}.`,
  
  curator: `You are the Curator. Review these proposals: {{proposals}}
Apply the 5-condition gate:
1. Does it fix a real problem?
2. Is the risk acceptable?
3. Is it reversible?
4. Does it align with goals?
5. Is it testable?

Return JSON with: {ts, step, status, decisions[], approved[]}.`
};

// Log to file
function log(entry) {
  const line = JSON.stringify({ ...entry, ts: new Date().toISOString() }) + '\n';
  try {
    appendFileSync(LOG_FILE, line, 'utf-8');
  } catch (e) {
    console.error('Log error:', e.message);
  }
}

// Call Gemini
async function callGemini(prompt, context = {}) {
  if (!GEMINI_API_KEY) {
    return { provider: 'mock', output: 'No API key - mock response' };
  }
  
  const url = `https://generativelanguage.googleapis.com/v1/models/gemini-2.0-flash:generateContent?key=${GEMINI_API_KEY}`;
  
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] },
        generationConfig: { temperature: 0.7, maxOutputTokens: 2048 }
      })
    });
    const data = await res.json();
    return { 
      provider: 'gemini', 
      output: data.candidates?.[0]?.content?.parts?.[0]?.text || 'No response'
    };
  } catch (e) {
    return { provider: 'gemini', error: e.message };
  }
}

// Run a single step
async function runStep(step, input = null) {
  const prompt = PROMPTS[step].replace('{{findings}}', JSON.stringify(input?.findings || []))
    .replace('{{classifications}}', JSON.stringify(input?.classifications || []))
    .replace('{{proposals}}', JSON.stringify(input?.proposals || []));
  
  log({ step, status: 'running', message: `Running ${step}...`, input });
  
  const result = await callGemini(prompt);
  
  log({ step, status: 'success', message: `Completed ${step}`, output: result.output || result.error });
  
  return { step, status: 'success', output: result.output, provider: result.provider };
}

// Run full Alpha loop (Observer → Evaluator → Proposer → Curator)
export async function runAlphaLoop() {
  const results = [];
  
  // Step 1: Observer
  const obs = await runStep('observer');
  results.push(obs);
  if (obs.output.includes('mock')) return results;
  
  // Step 2: Evaluator
  const eval = await runStep('evaluator', { findings: obs.output });
  results.push(eval);
  
  // Step 3: Proposer
  const prop = await runStep('proposer', { classifications: eval.output });
  results.push(prop);
  
  // Step 4: Curator
  const cur = await runStep('curator', { proposals: prop.output });
  results.push(cur);
  
  return results;
}

// Export for server
export default { runAlphaLoop, runStep };