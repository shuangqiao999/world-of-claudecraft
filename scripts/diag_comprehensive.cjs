// Comprehensive Moon server test: movement, snapshot rate, entities, pedestrians
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace('http', 'ws') + '/';
const USER = 'ct' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
async function http(m, p, b, t) { const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined }); return r.json().catch(() => ({})); }

(async () => {
  console.log('=== Moon Server Comprehensive Test ===\n');
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'C' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  console.log(`char id=${ca.id}`);

  const ws = new WebSocket(WS);
  let pid = null, self = null, snaps = [], ents = [];
  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: ca.id, clientSeed: '', timerWire: 2 })));
  ws.on('message', d => { try { const m = JSON.parse(d.toString()); if (m.t === 'hello') { pid = m.pid; console.log(`connected pid=${pid}\n`); start(); } if (m.t === 'snap') { snaps.push(m); if (m.self !== undefined) self = typeof m.self === 'string' ? JSON.parse(m.self) : m.self; if (m.ents) ents = m.ents; } } catch (e) {} });

  async function start() {
    await sleep(1500);
    // ---- 1. Spawn position ----
    console.log(`1. spawn pos=(${self.x?.toFixed(2)}, ${self.y?.toFixed(2)}, ${self.z?.toFixed(2)})`);

    // ---- 2. Entity visibility ----
    const entsInfo = {};
    for (const e of ents) { entsInfo[e.k] = (entsInfo[e.k] || 0) + 1; }
    console.log(`2. entities: ${JSON.stringify(entsInfo)}`);

    // ---- 3. Movement test ----
    const sx = self.x, sz = self.z;
    let seq = 0;
    const timer = setInterval(() => ws.send(JSON.stringify({ t: 'input', seq: seq++, mi: { f: 1, b: 0, tl: 0, tr: 0, sl: 0, sr: 0 }, facing: 1.57 })), 50);
    await sleep(3000);
    clearInterval(timer);
    const moved = Math.sqrt((self.x - sx) ** 2 + (self.z - sz) ** 2);
    console.log(`3. movement: (${sx.toFixed(2)},${sz.toFixed(2)}) -> (${self.x?.toFixed(2)},${self.z?.toFixed(2)}) = ${moved.toFixed(2)} yd`);

    // ---- 4. Snapshot rate ----
    const rateStart = snaps.length;
    await sleep(4000);
    const rate = (snaps.length - rateStart) / 4;
    console.log(`4. snapshot rate: ${rate.toFixed(1)} Hz`);

    // ---- 5. Pedestrian Y check ----
    let pedCount = 0, pedUnderground = 0;
    for (const e of ents) {
      if (e.k === 'npc' && e.tid === 'pedestrian') {
        pedCount++;
        if (e.y < 0.5) pedUnderground++;
      }
    }
    console.log(`5. pedestrians: ${pedCount} visible, ${pedUnderground} underground (y<0.5)`);

    // ---- summary ----
    console.log('\n=== SUMMARY ===');
    console.log(`movement: ${moved > 5 ? 'OK (' + moved.toFixed(1) + 'yd)' : 'BROKEN (' + moved.toFixed(1) + 'yd)'}`);
    console.log(`snapshot: ${rate > 15 ? 'OK (' + rate.toFixed(1) + 'Hz)' : 'SLOW (' + rate.toFixed(1) + 'Hz)'}`);
    console.log(`pedestrians: ${pedUnderground === 0 ? 'OK' : pedUnderground + ' underground'}`);

    ws.close(); process.exit(0);
  }
  setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 25000);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
