// Count snapshot entities by kind (mob/npc/node/player) near spawn.
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace(/^http/, 'ws') + '/';
const USER = 'ec' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function http(m, p, b, t) { const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined }); return r.json().catch(() => ({})); }

(async () => {
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'E' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  const ws = new WebSocket(WS);
  const entState = {};
  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: ca.id, clientSeed: '', timerWire: 2 })));
  ws.on('message', (d) => { try { const m = JSON.parse(d.toString()); if (m.t === 'hello') start(); if (m.t === 'snap') { if (Array.isArray(m.ents)) for (const rec of m.ents) { const r = typeof rec === 'string' ? JSON.parse(rec) : rec; if (r.id !== undefined) { let s = entState[r.id]; if (!s) { s = {}; entState[r.id] = s; } for (const k in r) s[k] = r[k]; } } } } catch (e) {} });

  async function start() {
    for (let i = 0; i < 80; i++) { if (Object.keys(entState).length > 0) break; await sleep(100); }
    await sleep(1000);
    const byKind = {};
    for (const id in entState) { const k = entState[id].k || '?'; byKind[k] = (byKind[k] || 0) + 1; }
    const npcs = Object.values(entState).filter((e) => e.k === 'npc');
    console.log('entity count by kind:', JSON.stringify(byKind));
    console.log('npc (pedestrian) count:', npcs.length, '| names:', npcs.map((e) => e.nm).join(','));
    ws.close(); process.exit(0);
  }
  setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 20000);
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
