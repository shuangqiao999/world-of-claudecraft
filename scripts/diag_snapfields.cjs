// Dump self snapshot fields + entity record structure
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace('http', 'ws') + '/';
const USER = 'df' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
async function http(m, p, b, t) { const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined }); return r.json().catch(() => ({})); }
(async () => {
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'D' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  const ws = new WebSocket(WS);
  let gotSelf = false, gotEnts = false;
  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: ca.id, clientSeed: '', timerWire: 2 })));
  ws.on('message', d => { try { const m = JSON.parse(d.toString()); if (m.t === 'hello') console.log('hello pid=' + m.pid + ' seed=' + m.seed + ' name=' + m.name + ' cls=' + m.cls);
    if (m.t === 'snap' && !gotSelf && m.self !== undefined) {
      gotSelf = true;
      const s = typeof m.self === 'string' ? JSON.parse(m.self) : m.self;
      console.log('\n=== SELF FIELDS ===');
      console.log(Object.keys(s).join(', '));
      console.log('\n=== SELF VALUES ===');
      console.log(JSON.stringify(s, null, 2).substring(0, 2000));
    }
    if (m.t === 'snap' && !gotEnts && m.ents) {
      gotEnts = true;
      console.log('\n=== ENTITY RECORDS (first 3) ===');
      for (let i = 0; i < Math.min(3, m.ents.length); i++) {
        console.log(`ent[${i}]: ${JSON.stringify(m.ents[i])}`);
      }
      console.log(`total ents: ${m.ents.length}, keep: ${(m.keep || []).length}`);
      console.log('\n=== KEEP (first 10) ===');
      console.log((m.keep || []).slice(0, 10).join(', '));
    }
    if (gotSelf && gotEnts) { ws.close(); process.exit(0); }
  } catch (e) {} });
  setTimeout(() => { ws.close(); process.exit(1); }, 15000);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
