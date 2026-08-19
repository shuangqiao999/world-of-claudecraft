// Minimal movement test: connect, send forward input, check position change
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace('http', 'ws') + '/';
const USER = 'mv' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
async function http(m, p, b, t) { const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined }); return r.json().catch(() => ({})); }
(async () => {
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'M' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  const ws = new WebSocket(WS);
  let pid = null, self = null;
  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: ca.id, clientSeed: '', timerWire: 2 })));
  ws.on('message', d => { try { const m = JSON.parse(d.toString()); if (m.t === 'hello') { pid = m.pid; console.log('connected pid=' + pid); start(); } if (m.t === 'snap' && m.self !== undefined) self = typeof m.self === 'string' ? JSON.parse(m.self) : m.self; } catch (e) {} });
  async function start() {
    await sleep(1500);
    const sx = self.x, sz = self.z;
    console.log(`start pos=(${sx.toFixed(2)},${sz.toFixed(2)})`);
    let seq = 0;
    const timer = setInterval(() => ws.send(JSON.stringify({ t: 'input', seq: seq++, mi: { f: 1, b: 0, l: 0, r: 0 }, facing: 1.57 })), 50);
    await sleep(3000);
    clearInterval(timer);
    console.log(`end pos=(${self.x.toFixed(2)},${self.z.toFixed(2)})  moved=${Math.sqrt((self.x-sx)**2+(self.z-sz)**2).toFixed(2)} yd`);
    ws.close(); process.exit(0);
  }
  setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 20000);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
