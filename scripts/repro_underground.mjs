// Reproduce the exact "Xiaozhang" state: saved underground (y=2.393 < terrain), facing 5.45.
// Creates a char, writes its saved pos via pg, then connects and walks.
import WebSocket from 'ws';
import pg from 'pg';

const BASE = 'http://localhost:8787';
const WS = BASE.replace(/^http/, 'ws') + '/';
const DB = process.env.DATABASE_URL;
const USER = 'ug' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function http(m, p, b, t) { const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined }); return r.json().catch(() => ({})); }

(async () => {
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'U' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  const charId = ca.id;

  // write the saved state to the underground spot
  const db = new pg.Client({ connectionString: DB });
  await db.connect();
  await db.query(
    `UPDATE characters SET state = state || '{"pos":{"x":-47.23,"y":2.393,"z":32.50},"facing":5.45}'::jsonb WHERE id = $1`,
    [charId],
  );
  await db.end();
  console.log('char', charId, 'state set to (-47.23, 2.393, 32.50) facing 5.45');

  const ws = new WebSocket(WS);
  let pid = null, self = null, seq = 0;
  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: charId, clientSeed: '', timerWire: 2 })));
  ws.on('message', (d) => { try { const m = JSON.parse(d.toString()); if (m.t === 'hello') { pid = m.pid; console.log('connected pid=' + pid); start(); } if (m.t === 'snap' && m.self !== undefined) self = typeof m.self === 'string' ? JSON.parse(m.self) : m.self; } catch (e) {} });
  function input(mi, facing) { const msg = { t: 'input', seq: seq++, mi }; if (facing !== undefined) msg.facing = facing; ws.send(JSON.stringify(msg)); }

  async function start() {
    // wait for the first snapshot (self) to arrive
    for (let i = 0; i < 100 && !self; i++) await sleep(100);
    if (!self) { console.log('no self snapshot'); ws.close(); process.exit(1); }
    console.log('self pos=', JSON.stringify({ x: self.x?.toFixed(2), y: self.y?.toFixed(2), z: self.z?.toFixed(2), f: self.f?.toFixed(2) }));
    const sx = self.x, sz = self.z;
    // walk forward (facing 5.45 already set) 3s, omit facing (like a non-mouselook client)
    const t0 = Date.now();
    while (Date.now() - t0 < 3000) { input({ f: 1, b: 0, sl: 0, sr: 0 }); await sleep(50); }
    const moved = Math.sqrt((self.x - sx) ** 2 + (self.z - sz) ** 2);
    console.log('walk result: moved=' + moved.toFixed(2) + ' yd, self pos=', JSON.stringify({ x: self.x?.toFixed(2), y: self.y?.toFixed(2), z: self.z?.toFixed(2) }));
    ws.close(); process.exit(0);
  }
  setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 30000);
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
