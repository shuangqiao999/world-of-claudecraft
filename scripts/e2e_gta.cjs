// GTA-style E2E test: passive mobs, PvP, gathering, trade
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace('http', 'ws') + '/';
const PASS = 'testpass';

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
async function http(method, path, body, token) {
  const r = await fetch(BASE + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return r.json().catch(() => ({}));
}

const results = [];
function pass(n) { results.push(true); console.log('PASS ' + n); }
function fail(n) { results.push(false); console.log('FAIL ' + n); }

function client(token, charId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS);
    const c = { ws, snaps: [], logs: [], pid: null, lastSelf: null };
    const timer = setTimeout(() => reject(new Error('hello timeout')), 15000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', d => {
      try {
        const m = JSON.parse(d.toString());
        if (m.t === 'hello') { clearTimeout(timer); c.pid = m.pid; resolve(c); }
        if (m.t === 'snap' && m.self !== undefined) {
          c.lastSelf = typeof m.self === 'string' ? JSON.parse(m.self) : m.self;
          c.snaps.push(m);
        }
        if (m.t === 'events' && Array.isArray(m.list)) for (const ev of m.list) if (ev.type === 'log') c.logs.push(ev.text);
      } catch (e) {}
    });
    ws.on('error', e => { clearTimeout(timer); reject(e); });
  });
}

async function registerAndChar(suffix, cls) {
  const uname = 'e2e' + suffix + Date.now().toString(36).slice(-3);
  let reg = await http('POST', '/api/register', { username: uname, password: PASS, email: uname + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: uname, password: PASS });
  const token = reg.token;
  const name = 'E' + Date.now().toString(36).slice(-8).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: cls || 'warrior' }, token);
  return { token, charId: ca.id };
}

(async () => {
  console.log('=== GTA-style E2E Test ===\n');

  // ---- setup 2 players ----
  const a = await registerAndChar('a', 'warrior');
  const b = await registerAndChar('b', 'warrior');
  const ca = await client(a.token, a.charId);
  const cb = await client(b.token, b.charId);
  pass('two players connected');
  await sleep(2000);

  // ---- Test 1: Gathering gives copper + item ----
  const copperBefore = ca.lastSelf?.copper ?? 0;
  ca.ws.send(JSON.stringify({ t: 'cmd', cmd: 'harvest_node', node: 'herb' }));
  await sleep(2000);
  const copperAfter = ca.lastSelf?.copper ?? 0;
  console.log(`  gather: copper ${copperBefore} -> ${copperAfter}`);
  if (copperAfter > copperBefore) pass('gathering grants copper');
  else fail('gathering did not grant copper (before=' + copperBefore + ' after=' + copperAfter + ')');

  // ---- Test 2: PvP — player A attacks player B ----
  const hpBBefore = cb.lastSelf?.hp ?? 0;
  // A targets B and attacks
  ca.ws.send(JSON.stringify({ t: 'cmd', cmd: 'target', id: cb.pid }));
  await sleep(500);
  ca.ws.send(JSON.stringify({ t: 'cmd', cmd: 'attack' }));
  await sleep(3000);
  const hpBAfter = cb.lastSelf?.hp ?? 0;
  console.log(`  pvp: B hp ${hpBBefore} -> ${hpBAfter}`);
  if (hpBAfter < hpBBefore) pass('PvP: player A damaged player B');
  else fail('PvP: B took no damage (hp=' + hpBBefore + ' -> ' + hpBAfter + ')');

  // ---- Test 3: Trade — A trades copper to B ----
  const aCopperBefore = ca.lastSelf?.copper ?? 0;
  const bCopperBefore = cb.lastSelf?.copper ?? 0;
  ca.ws.send(JSON.stringify({ t: 'cmd', cmd: 'trade_req', id: cb.pid }));
  await sleep(1000);
  cb.ws.send(JSON.stringify({ t: 'cmd', cmd: 'trade_accept' }));
  await sleep(500);
  ca.ws.send(JSON.stringify({ t: 'cmd', cmd: 'trade_offer', copper: 50, items: [] }));
  await sleep(500);
  cb.ws.send(JSON.stringify({ t: 'cmd', cmd: 'trade_offer', copper: 0, items: [] }));
  await sleep(500);
  ca.ws.send(JSON.stringify({ t: 'cmd', cmd: 'trade_confirm' }));
  await sleep(500);
  cb.ws.send(JSON.stringify({ t: 'cmd', cmd: 'trade_confirm' }));
  await sleep(2000);
  const aCopperAfter = ca.lastSelf?.copper ?? 0;
  const bCopperAfter = cb.lastSelf?.copper ?? 0;
  console.log(`  trade: A ${aCopperBefore} -> ${aCopperAfter}, B ${bCopperBefore} -> ${bCopperAfter}`);
  if (aCopperAfter < aCopperBefore && bCopperAfter > bCopperBefore) pass('trade moved copper A->B');
  else fail('trade did not move copper (A ' + aCopperBefore + '->' + aCopperAfter + ', B ' + bCopperBefore + '->' + bCopperAfter + ')');

  // ---- report ----
  const passed = results.filter(Boolean).length;
  const failed = results.filter(r => !r).length;
  console.log(`\n=== ${passed} pass, ${failed} fail ===`);
  ca.ws.close(); cb.ws.close();
  process.exit(failed === 0 ? 0 : 1);
})().catch(e => { console.error('FATAL', e.message); process.exit(2); });
