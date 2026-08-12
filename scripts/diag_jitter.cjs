// World of ClaudeCraft — Jitter / Terrain Clip / FPS Drop Diagnostic
// Usage: node scripts/diag_jitter.cjs
//
// Connects to server, creates/loads a character, and:
// 1. Idles for 5s, measures snap frequency (baseline fps)
// 2. Moves forward for 5s, measures snap frequency (moving fps)
// 3. Analyzes Y position stability (jitter detection)
// 4. Flags Y < 0 events (possible terrain sinking)
const WebSocket = require('ws');

const BASE = process.env.SERVER_URL || 'http://localhost:8787';
const WS = BASE.replace('http', 'ws') + '/';
const USER = 'diag' + Date.now().toString(36).slice(-4);
const PASS = 'testpass456';
const EMAIL = USER + '@test.com';

const results = [];
function pass(msg) { results.push(true); console.log('PASS ' + msg); }
function fail(msg) { results.push(false); console.log('FAIL ' + msg); }
function info(msg) { console.log('INFO ' + msg); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function http(method, path, body, token) {
  const r = await fetch(BASE + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${path} ${r.status}: ${JSON.stringify(data)}`);
  return data;
}

function wsClient(token, charId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS);
    const c = { ws, snaps: [], pid: null, done: false };
    const timer = setTimeout(() => reject(new Error('hello timeout')), 15000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', d => {
      try {
        const m = JSON.parse(d.toString());
        if (m.t === 'hello') { clearTimeout(timer); c.pid = m.pid; resolve(c); return; }
        if (m.t === 'snap') c.snaps.push(m);
      } catch (e) {}
    });
    ws.on('error', e => { clearTimeout(timer); reject(e); });
  });
}

async function run() {
  console.log('=== Jitter / Terrain / FPS Diagnostic ===\n');

  // ---- auth ----
  info(`registering ${USER}...`);
  let reg;
  try { reg = await http('POST', '/api/register', { username: USER, password: PASS, email: EMAIL }); }
  catch (e) { info('register failed, trying login'); reg = await http('POST', '/api/login', { username: USER, password: PASS }); }
  const token = reg.token;
  if (!token) { fail('no token'); process.exit(1); }
  pass('auth-ok');

  // ---- character ----
  let chars = await http('GET', '/api/characters', null, token);
  let charId;
  if (!chars || !chars.length) {
    info('creating character...');
    const name = 'D' + Date.now().toString(36).slice(-8).replace(/[^a-zA-Z]/g, '');
    const cr = await http('POST', '/api/characters', { name, class: 'warrior' }, token);
    charId = cr.id;
    info(`character created: ${name} id=${charId}`);
  } else {
    charId = chars[0].id;
    info(`using character id=${charId}`);
  }
  if (!charId) { fail('no character id'); process.exit(1); }
  pass('char-ok');

  // ---- connect ----
  info('connecting...');
  const c = await wsClient(token, charId);
  pass('ws-connected pid=' + c.pid);
  await sleep(8000); // wait for first snaps to arrive
  info(`snaps received after connect: ${c.snaps.length}`);

  // ---- Phase 1: Idle baseline ----
  info('\n--- Phase 1: IDLE (5s) ---');
  const idleStartIdx = c.snaps.length;
  await sleep(5000);
  const idleEndIdx = c.snaps.length;
  const idleSnaps = c.snaps.slice(idleStartIdx, idleEndIdx);
  const idleFps = idleSnaps.length / 5;
  info(`idle snaps: ${idleSnaps.length}  fps: ${idleFps.toFixed(1)}`);
  if (idleFps >= 15) pass('idle-fps');
  else fail(`idle-fps low: ${idleFps.toFixed(1)}`);

  // ---- Phase 2: Movement ----
  info('\n--- Phase 2: MOVING (5s) ---');
  const moveStartIdx = c.snaps.length;
  // Send movement input every 50ms for 5s
  for (let i = 0; i < 100; i++) {
    c.ws.send(JSON.stringify({ t: 'input', seq: i, mi: { f: 1, b: 0, l: 0, r: 0 }, facing: 1.57 }));
    await sleep(50);
  }
  // Send stop
  c.ws.send(JSON.stringify({ t: 'input', seq: 200, mi: { f: 0, b: 0, l: 0, r: 0 }, facing: 1.57 }));
  await sleep(1000);
  const moveEndIdx = c.snaps.length;
  const moveSnaps = c.snaps.slice(moveStartIdx, moveEndIdx);
  const moveFps = moveSnaps.length / 6;
  info(`move snaps: ${moveSnaps.length}  fps: ${moveFps.toFixed(1)}`);
  if (moveFps >= 10) pass('move-fps');
  else fail(`move-fps low: ${moveFps.toFixed(1)}`);

  // ---- Phase 3: Y position analysis ----
  info('\n--- Phase 3: Y Position Analysis ---');
  let ySamples = [];
  let yDeltas = [];
  let prevY = null;
  let zeroYcount = 0;
  let belowZeroY = 0;
  let ySignChanges = 0;
  let lastDySign = 0;

  for (const snap of c.snaps) {
    if (snap.self && snap.self.y !== undefined) {
      const y = snap.self.y;
      ySamples.push(y);
      if (y === 0) zeroYcount++;
      if (y < -0.1) belowZeroY++;
      if (prevY !== null) {
        const dy = y - prevY;
        yDeltas.push(Math.abs(dy));
        if (dy !== 0) {
          const sign = dy > 0 ? 1 : -1;
          if (lastDySign !== 0 && sign !== lastDySign) ySignChanges++;
          lastDySign = sign;
        }
      }
      prevY = y;
    }
  }

  info(`Y samples: ${ySamples.length}, zero count: ${zeroYcount}, below-zero: ${belowZeroY}`);
  if (ySamples.length > 0) {
    const yMin = Math.min(...ySamples);
    const yMax = Math.max(...ySamples);
    const yRange = yMax - yMin;
    const yMean = ySamples.reduce((a, b) => a + b, 0) / ySamples.length;
    info(`Y range: ${yMin.toFixed(3)} - ${yMax.toFixed(3)} (span=${yRange.toFixed(3)})  mean=${yMean.toFixed(3)}`);

    if (yDeltas.length > 0) {
      const maxDelta = Math.max(...yDeltas);
      const avgDelta = yDeltas.reduce((a,b)=>a+b,0) / yDeltas.length;
      info(`Y deltas: max=${maxDelta.toFixed(4)}  avg=${avgDelta.toFixed(4)}  sign-changes=${ySignChanges}`);
    }

    // Jitter: Y oscillates rapidly (many sign changes, small range)
    if (ySignChanges > ySamples.length * 0.3 && yRange < 0.5) {
      fail(`Y JITTER DETECTED: ${ySignChanges} sign changes in ${ySamples.length} snaps (${(ySignChanges/ySamples.length*100).toFixed(0)}%), range=${yRange.toFixed(3)}`);
    } else {
      pass('y-stable (no jitter)');
    }

    // Terrain sinking: Y consistently 0 or negative
    if (zeroYcount > ySamples.length * 0.5) {
      fail(`TERRAIN SINKING: Y=0 in ${zeroYcount}/${ySamples.length} snaps`);
    } else if (belowZeroY > 0) {
      fail(`BELOW TERRAIN: Y<0 in ${belowZeroY}/${ySamples.length} snaps`);
    } else {
      pass('y-above-ground');
    }

    // FPS drop: movement fps significantly lower than idle
    const fpsDrop = idleFps - moveFps;
    info(`fps drop (idle->move): ${fpsDrop.toFixed(1)}`);
    if (fpsDrop > idleFps * 0.4) {
      fail(`SEVERE FPS DROP: ${fpsDrop.toFixed(1)} fps (${(fpsDrop/idleFps*100).toFixed(0)}%)`);
    } else if (fpsDrop > 0) {
      info(`moderate fps drop: ${fpsDrop.toFixed(1)} fps`);
    }
  } else {
    fail('no Y samples (snapshot self.y missing)');
  }

  // ---- Phase 4: Entity visibility ----
  info('\n--- Phase 4: Entity Visibility ---');
  let hasNpcs = false;
  let hasMobs = false;
  let totalEnts = 0;
  for (const snap of c.snaps) {
    if (snap.ents) {
      totalEnts = Math.max(totalEnts, snap.ents.length);
      for (const ent of snap.ents) {
        if (ent.k === 'npc') hasNpcs = true;
        if (ent.k === 'mob') hasMobs = true;
      }
    }
  }
  info(`max entities in snap: ${totalEnts}, npcs seen: ${hasNpcs}, mobs seen: ${hasMobs}`);
  if (hasNpcs) pass('npcs-visible'); else fail('no npcs in any snap frame');

  // ---- Final ----
  c.ws.close();
  const passed = results.filter(Boolean).length;
  const failed = results.filter(r => !r).length;
  console.log(`\n=== ${passed} pass, ${failed} fail ===`);
  process.exit(failed === 0 ? 0 : 1);
}

run().catch(e => { console.error('FATAL', e.message); process.exit(2); });
