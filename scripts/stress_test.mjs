// Standalone server capacity stress test — no ALLOW_DEV_COMMANDS required.
// Registers N accounts, creates characters, connects via WebSocket, sends
// periodic move messages, and measures server-side tick detail via /api/perf.
//
//   node scripts/stress_test.mjs
//   BOTS=100 DURATION_MS=30000 node scripts/stress_test.mjs

import WebSocket from 'ws';

const BASE = process.env.SERVER_URL ?? 'http://localhost:8787';
const WS_BASE = BASE.replace(/^http/, 'ws');
const BOTS = Number(process.env.BOTS ?? 50);
const DURATION_MS = Number(process.env.DURATION_MS ?? 30000);
const RAMP_MS = Number(process.env.RAMP_MS ?? 60);

const L = 'abcdefghijklmnopqrstuvwxyz';
const lettersOf = (n) => { let s = ''; let x = n; while (x >= 0) { s = L[x % 26] + s; x = Math.floor(x / 26) - 1; } return s; };

const uniq = Date.now().toString(36).replace(/[0-9]/g, (d) => L[Number(d)]);
// 6+ chars for password, 2-16 letters for character name
const nameOf = (i) => `Bta${lettersOf(i)}${uniq}`.slice(0, 16);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const ipFor = (n) => `10.${(n >> 8) & 255}.${n & 255}.7`;

async function api(path, body, token, ip) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  if (ip) headers['X-Forwarded-For'] = ip;
  const res = await fetch(BASE + path, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!res.ok) {
    const text = await res.text();
    console.error(`  ! API ${path} (${res.status}): ${text.slice(0, 200)}`);
  }
  return res;
}

async function fetchPerf() {
  try {
    const r = await fetch(BASE + '/api/perf');
    return r.ok ? r.json() : null;
  } catch { return null; }
}

async function run() {
  console.log(`[stress] target ${BASE}  bots=${BOTS}  ramp=${RAMP_MS}ms  dur=${DURATION_MS}ms`);
  const start = Date.now();

  // 1. Register + login + create character for each bot
  const accounts = [];
  for (let i = 0; i < BOTS; i++) {
    const name = nameOf(i);
    const ip = ipFor(i);
    try {
      // Register
      let res = await api('/api/register', { username: name, password: name, email: `${name}@test.local` }, null, ip);
      if (!res.ok && res.status !== 409) { console.error(`  register fail ${i}`); continue; }

      // Login
      res = await api('/api/login', { username: name, password: name }, null, ip);
      if (!res.ok) { console.error(`  login fail ${i}`); continue; }
      const loginData = await res.json();
      const token = loginData.token;

      // Create character
      const classes = ['warrior','mage','hunter','rogue','priest','paladin','warlock','druid','shaman'];
      const cls = classes[i % classes.length];
      res = await api('/api/characters', { name: name, class: cls, race: 'human' }, token, ip);
      if (!res.ok) { console.error(`  char fail ${i}`); continue; }
      const charData = await res.json();
      const charId = charData.id ?? charData.character?.id;

      accounts.push({ name, token, charId, ip, cls, i });
    } catch (err) {
      console.error(`  bot ${i}: ${err.message}`);
    }
    if (i > 0 && i % 10 === 0) process.stdout.write(`  accounts: ${accounts.length}/${i+1}\r`);
    await sleep(RAMP_MS);
  }
  console.log(`\n[stress] ${accounts.length}/${BOTS} accounts ready (${Date.now() - start}ms)`);

  // 2. Fetch baseline perf
  const perf0 = await fetchPerf();
  if (perf0?.tick) console.log(`[stress] baseline: total=${perf0.tick.total ?? '?'}  tick=${perf0.tick.tick ?? '?'}  broadcast=${perf0.tick.broadcast ?? '?'}`);

  // 3. Connect WebSocket for each bot
  let connected = 0;
  const sockets = [];
  for (const acct of accounts) {
    const ws = new WebSocket(WS_BASE + '/ws', { headers: { 'x-forwarded-for': acct.ip } });
    const p = new Promise((resolve) => {
      ws.on('open', () => {
        ws.send(JSON.stringify({ t: 'auth-world-5', token: acct.token, character: acct.charId }));
      });
      ws.on('message', (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (msg.t === 'hello') { connected++; resolve(true); }
        } catch {}
      });
      ws.on('error', () => resolve(false));
    });
    sockets.push({ ws, p, acct });
    await sleep(Math.max(1, RAMP_MS / 4));
  }

  console.log(`[stress] connecting...`);
  await Promise.all(sockets.map(s => s.p));
  const joined = sockets.filter(s => s.ws.readyState === WebSocket.OPEN).length;
  console.log(`[stress] ${joined}/${accounts.length} connected (${Date.now() - start}ms)`);

  if (joined === 0) { console.error('[stress] no connections — abort'); process.exit(1); }

  // 4. Send periodic move commands
  const directions = [
    { x: 1, z: 0 }, { x: -1, z: 0 }, { x: 0, z: 1 }, { x: 0, z: -1 },
    { x: 0.7, z: 0.7 }, { x: -0.7, z: -0.7 },
  ];

  let tick = 0;
  const moveTimer = setInterval(() => {
    const dir = directions[tick % directions.length];
    for (const s of sockets) {
      if (s.ws.readyState !== WebSocket.OPEN) continue;
      try {
        s.ws.send(JSON.stringify({ cmd: 'move', dir }));
      } catch {}
    }
    tick++;
  }, 200);

  // 5. Monitor /api/perf every 5 seconds
  const samples = [];
  const monTimer = setInterval(async () => {
    const perf = await fetchPerf();
    if (perf?.tick) {
      const t = perf.tick;
      const elapsed = Date.now() - start;
      samples.push({ elapsed, total: t.total, tick: t.tick, broadcast: t.broadcast, bcastSelf: t.bcastSelf, bcastGrid: t.bcastGrid, events: t.events, social: t.social });
      console.log(`[stress ${(elapsed/1000).toFixed(0)}s] total=${t.total?.toFixed(1)}ms  tick=${t.tick?.toFixed(1)}ms  bcast=${t.broadcast?.toFixed(1)}ms  bots=${joined}`);
    }
  }, 5000);

  // 6. Wait for duration
  await sleep(DURATION_MS);
  clearInterval(moveTimer);
  clearInterval(monTimer);

  // 7. Final perf snapshot
  const perfEnd = await fetchPerf();
  console.log(`\n[stress] === summary after ${DURATION_MS/1000}s ===`);
  if (perfEnd?.tick) {
    const t = perfEnd.tick;
    console.log(`  total:   ${t.total?.toFixed(1) ?? '?'} ms`);
    console.log(`  tick:    ${t.tick?.toFixed(1) ?? '?'} ms`);
    console.log(`  bcast:   ${t.broadcast?.toFixed(1) ?? '?'} ms`);
    console.log(`  self:    ${t.bcastSelf?.toFixed(1) ?? '?'} ms`);
    console.log(`  grid:    ${t.bcastGrid?.toFixed(1) ?? '?'} ms`);
    console.log(`  events:  ${t.events?.toFixed(1) ?? '?'} ms`);
    console.log(`  social:  ${t.social?.toFixed(1) ?? '?'} ms`);

    const opMs = Math.max(1, t.tick || 0) + Math.max(1, t.broadcast || 0);
    console.log(`\n  tick+bcast = ${opMs.toFixed(1)}ms → headroom ${(50 - opMs).toFixed(1)}ms`);
    console.log(`  server can handle ~${Math.ceil(BOTS * 50 / opMs)} bots at 100% CPU budget`);
  }

  // 8. Cleanup
  for (const s of sockets) { try { s.ws.close(); } catch {} }
  console.log('[stress] done.');
}

run().catch(err => { console.error(err); process.exit(1); });
