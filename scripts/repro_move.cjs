// Reproduce the "can't walk" bug: teleport onto a steep/uneven spot, walk, report.
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace(/^http/, 'ws') + '/';
const USER = 'rp' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function http(m, p, b, t) { const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined }); return r.json().catch(() => ({})); }

(async () => {
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'R' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  const ws = new WebSocket(WS);
  let pid = null, self = null, seq = 0;
  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: ca.id, clientSeed: '', timerWire: 2 })));
  ws.on('message', (d) => { try { const m = JSON.parse(d.toString()); if (m.t === 'hello') { pid = m.pid; console.log('connected pid=' + pid); start(); } if (m.t === 'snap' && m.self !== undefined) self = typeof m.self === 'string' ? JSON.parse(m.self) : m.self; } catch (e) {} });
  function cmd(name, args) { ws.send(JSON.stringify({ t: 'cmd', cmd: name, ...args })); }
  function input(mi, facing) { ws.send(JSON.stringify({ t: 'input', seq: seq++, mi, facing })); }

  async function start() {
    await sleep(1500);
    console.log('spawn self pos=', JSON.stringify({ x: self.x?.toFixed(2), y: self.y?.toFixed(2), z: self.z?.toFixed(2) }));
    // teleport to the known-underground spot (x/z only; y stays at spawn -> below terrain)
    cmd('dev_teleport', { x: -47.23, z: 32.50 });
    await sleep(800);
    console.log('after teleport self pos=', JSON.stringify({ x: self.x?.toFixed(2), y: self.y?.toFixed(2), z: self.z?.toFixed(2) }));
    const sx = self.x, sz = self.z;
    // walk forward 2.5s
    const t0 = Date.now();
    while (Date.now() - t0 < 2500) { input({ f: 1, b: 0, sl: 0, sr: 0 }, 1.57); await sleep(50); }
    const moved = Math.sqrt((self.x - sx) ** 2 + (self.z - sz) ** 2);
    console.log('walk result: moved=' + moved.toFixed(2) + ' yd, self pos=', JSON.stringify({ x: self.x?.toFixed(2), y: self.y?.toFixed(2), z: self.z?.toFixed(2) }));
    ws.close(); process.exit(0);
  }
  setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 30000);
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
