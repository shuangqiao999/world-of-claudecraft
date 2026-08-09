// Multi-zone server capacity stress test.
// Registers N bots, connects via WebSocket, teleports them across ALL 14 zones,
// then measures server perf under distributed load (zone sharding tests).
//
//   BOTS=280 DURATION_MS=60000 node scripts/stress_multi_zone.mjs

import WebSocket from 'ws';

const BASE = process.env.SERVER_URL ?? 'http://localhost:8787';
const WS_BASE = BASE.replace(/^http/, 'ws');
const BOTS = Number(process.env.BOTS ?? 140);
const DURATION_MS = Number(process.env.DURATION_MS ?? 60000);
const RAMP_MS = Number(process.env.RAMP_MS ?? 40);

const L = 'abcdefghijklmnopqrstuvwxyz';
const lettersOf = (n) => { let s=''; let x=n; while(x>=0){ s=L[x%26]+s; x=Math.floor(x/26)-1; } return s; };
const uniq = Date.now().toString(36).replace(/[0-9]/g, (d) => L[Number(d)]);
const nameOf = (i) => `Bta${lettersOf(i)}${uniq}`.slice(0, 16);

const ipFor = (n) => `10.${(n>>8)&255}.${n&255}.7`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 14 zone teleport targets. Set STRESS_SAME_ZONE=1 to put all bots in eastbrook_vale.
const STRESS_SAME_ZONE = process.env.STRESS_SAME_ZONE === '1';

const ZONE_SPOTS = STRESS_SAME_ZONE
  ? Array(14).fill({ map: 'eastbrook_vale', x: 0, z: 0 })
  : [
      { map: 'eastbrook_vale',  x: 0,   z: 0 },
      { map: 'mirefen_marsh',   x: 0,   z: 360 },
      { map: 'thornpeak_heights', x: 0, z: 720 },
      { map: 'veiled_hollow',   x: 0,   z: 1170 },
      { map: 'frostveil',       x: 0,   z: 1700 },
      { map: 'willowfen',       x: -360, z: 440 },
      { map: 'palmreach',       x: -360, z: 980 },
      { map: 'nightbloom',      x: -360, z: 1540 },
      { map: 'amberfall',       x: -360, z: 2100 },
      { map: 'farshore_isle',   x: 360,  z: 0 },
      { map: 'galecrest',       x: 360,  z: 440 },
      { map: 'evergarden',      x: 360,  z: 980 },
      { map: 'wraithwood',      x: 360,  z: 1540 },
      { map: 'drakelands',      x: 360,  z: 2100 },
    ];

async function api(path, body, token, ip) {
  const h = { 'Content-Type': 'application/json' };
  if (token) h['Authorization'] = `Bearer ${token}`;
  if (ip) h['X-Forwarded-For'] = ip;
  const res = await fetch(BASE + path, { method: 'POST', headers: h, body: JSON.stringify(body) });
  if (!res.ok) { const t = await res.text().catch(()=>''); console.error(`  ! ${path} (${res.status}): ${t.slice(0,160)}`); }
  return res;
}

async function fetchPerf() {
  try { const r = await fetch(BASE + '/api/perf'); return r.ok ? r.json() : null; } catch { return null; }
}

async function run() {
  const mode = STRESS_SAME_ZONE ? 'SAME-ZONE' : 'MULTI-ZONE';
  console.log(`[${mode}] ${BASE}  bots=${BOTS}  dur=${DURATION_MS}ms  zones=${STRESS_SAME_ZONE?1:14}`);
  const start = Date.now();
  const accounts = [];

  // Phase 1: Register + login + create character
  for (let i = 0; i < BOTS; i++) {
    const name = nameOf(i);
    const ip = ipFor(i);
    try {
      let res = await api('/api/register', { username: name, password: name, email: `${name}@t.local` }, null, ip);
      if (!res.ok && res.status !== 409) continue;
      res = await api('/api/login', { username: name, password: name }, null, ip);
      if (!res.ok) continue;
      const loginData = await res.json();
      const token = loginData.token;
      const CLS = ['warrior','mage','hunter','rogue','priest','paladin','warlock','druid','shaman'];
      res = await api('/api/characters', { name, class: CLS[i%CLS.length], race: 'human' }, token, ip);
      if (!res.ok) continue;
      const cd = await res.json();
      const cid = cd.id ?? cd.character?.id;
      accounts.push({ name, token, charId: cid, ip, i });
    } catch (err) { console.error(`  bot ${i}: ${err.message}`); }
    await sleep(RAMP_MS);
    if (i && i%14===0) process.stdout.write(`  reg ${i+1}/${BOTS}\r`);
  }
  console.log(`\n[${mode}] ${accounts.length}/${BOTS} accounts (${(Date.now()-start)/1000|0}s)`);

  if (accounts.length === 0) { console.error('no accounts'); process.exit(1); }

  // Phase 2: Connect WebSocket
  const bots = [];
  const wsConns = [];
  for (const a of accounts) {
    const ws = new WebSocket(WS_BASE + '/ws', { headers: { 'x-forwarded-for': a.ip } });
    const p = new Promise((resolve) => {
      ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: a.token, character: a.charId })));
      ws.on('message', (raw) => {
        try { if (JSON.parse(raw.toString()).t === 'hello') { resolve(true); } } catch {}
      });
      ws.on('error', () => resolve(false));
    });
    bots.push({ ws, p, a });
  }

  console.log(`[multi] connecting ${bots.length}...`);
  await Promise.all(bots.map(b => b.p));
  const live = bots.filter(b => b.ws.readyState === WebSocket.OPEN);
  console.log(`[multi] ${live.length} connected (${(Date.now()-start)/1000|0}s)`);
  if (live.length === 0) { console.error('no connections'); process.exit(1); }

  // Phase 3: Teleport bots to different zones
  console.log(`[multi] teleporting to zones...`);
  for (const b of live) {
    const spot = ZONE_SPOTS[b.a.i % 14];
    b.ws.send(JSON.stringify({ cmd: 'dev_teleport', x: spot.x, z: spot.z, map: spot.map }));
    if (b.a.i < 14) console.log(`  bot ${b.a.i} → ${spot.map} (${spot.x},${spot.z})`);
    await sleep(50);
  }
  await sleep(3000);

  // Phase 4: Send periodic move to keep bots active
  const dirs = [{x:1,z:0},{x:-1,z:0},{x:0,z:1},{x:0,z:-1}];
  let tick = 0;
  const timer = setInterval(() => {
    const d = dirs[tick%4];
    for (const b of live) { try { b.ws.send(JSON.stringify({cmd:'move',dir:d})); } catch{} }
    tick++;
  }, 250);

  // Phase 5: Monitor perf every 10s
  console.log(`\n[multi] === perf monitoring (${DURATION_MS/1000|0}s) ===`);
  const samples = [];
  const monTimer = setInterval(async () => {
    const p = await fetchPerf();
    if (p?.phases) {
      const t = p.phases;
      const total = t.total.mean;
      const tick = t.tick.mean;
      const bcast = t.broadcast?.mean ?? 0;
      const hz = p.tickHz ?? 0;
      const elapsed = ((Date.now() - start)/1000|0);
      samples.push({ elapsed, hz, total, tick, bcast, online: p.online });
      const status = hz >= 19 ? 'OK' : hz >= 15 ? 'WARN' : 'CRIT';
      console.log(`[${elapsed}s] ${status} hz=${hz.toFixed(1)} total=${total.toFixed(1)}ms tick=${tick.toFixed(1)}ms bcast=${bcast.toFixed(1)}ms online=${p.online??'?'}`);
    }
  }, 10000);

  await sleep(DURATION_MS);
  clearInterval(timer);
  clearInterval(monTimer);

  // Phase 6: Final perf snapshot
  const final = await fetchPerf();
  console.log(`\n[multi] === final ===`);
  if (final?.phases) {
    const t = final.phases;
    console.log(`  hz:      ${final.tickHz?.toFixed(1)}`);
    console.log(`  total:   ${t.total.mean.toFixed(1)}ms (p95=${t.total.p95.toFixed(1)})`);
    console.log(`  tick:    ${t.tick.mean.toFixed(1)}ms`);
    console.log(`  bcast:   ${t.broadcast?.mean?.toFixed(1) ?? '?'}ms`);
    console.log(`  grid:    ${t.bcastGrid?.mean?.toFixed(1) ?? '?'}ms`);
    console.log(`  self:    ${t.bcastSelf?.mean?.toFixed(1) ?? '?'}ms`);

    // Per-zone mob update breakdown
    console.log(`\n  mob/zone:`);
    for (const [k,v] of Object.entries(t)) {
      if (k.startsWith('sim.mob.z:') && v.mean > 0.1) console.log(`    ${k.replace('sim.mob.z:','')}: ${v.mean.toFixed(1)}ms`);
    }
  }

  for (const b of live) { try { b.ws.close(); } catch {} }
  console.log('\n[multi] done.');
}

run().catch(err => { console.error(err); process.exit(1); });
