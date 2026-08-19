// Enhanced diagnostic — terrain height sampling, mob positions, collision test
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace('http', 'ws') + '/';
const USER = 'diag' + Date.now().toString(36).slice(-4);
const PASS = '123456';

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function http(method, path, body, token) {
  const r = await fetch(BASE + path, {
    method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return r.json().catch(() => ({}));
}

function wsClient(token, charId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS);
    const c = { ws, snaps: [], events: [], pid: null, deaths: 0 };
    const timer = setTimeout(() => reject(new Error('hello timeout')), 15000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', d => {
      try {
        const m = JSON.parse(d.toString());
        if (m.t === 'hello') { clearTimeout(timer); c.pid = m.pid; return resolve(c); }
        if (m.t === 'snap') c.snaps.push(m);
        if (m.t === 'events' && Array.isArray(m.list))
          for (const ev of m.list) if (ev.type === 'death' && ev.pid === c.pid) c.deaths++;
      } catch (e) {}
    });
    ws.on('error', e => { clearTimeout(timer); reject(e); });
  });
}

(async () => {
  console.log('=== Terrain / Mob / Collision Diagnostic ===\n');

  // auth
  let reg;
  try { reg = await http('POST', '/api/register', { username: USER, password: PASS }); }
  catch (e) { reg = await http('POST', '/api/login', { username: USER, password: PASS }); }
  const token = reg.token;
  console.log(`auth ok`);

  let chars = await http('GET', '/api/characters', null, token);
  let charId;
  if (!chars?.length) {
    const name = 'Diag' + Date.now().toString(36).slice(-6).toUpperCase();
    const cr = await http('POST', '/api/characters', { name, class: 'warrior' }, token);
    charId = cr.id;
  } else charId = chars[0].id;
  console.log(`char id=${charId}`);

  const c = await wsClient(token, charId);
  console.log(`connected pid=${c.pid}\n`);
  await sleep(5000);

  // ---- 1. Snapshot field analysis ----
  console.log('--- 1. Snapshot Structure ---');
  const latestSnaps = c.snaps.slice(-20);
  for (const snap of latestSnaps) {
    if (snap.self) {
      const s = snap.self;
      console.log(`  tick=${snap.tick} y=${s.y?.toFixed(2)} hp=${s.hp} x=${s.x?.toFixed(2)} z=${s.z?.toFixed(2)}` +
        ` onGround=${s.onGround ?? '?'} swimming=${s.swimming ?? '?'}`);
      break;
    }
  }

  // ---- 2. Entity analysis (all nearby) ----
  console.log('\n--- 2. Nearby Entities ---');
  let entSeen = 0, entNear = 0;
  const nearbyY = [];
  for (const snap of latestSnaps) {
    if (snap.ents) {
      entSeen = Math.max(entSeen, snap.ents.length);
      for (const ent of snap.ents) {
        if (ent.x != null && ent.y != null) {
          const px = snap.self?.x || 0, pz = snap.self?.z || 0;
          const d = Math.sqrt((ent.x - px) ** 2 + (ent.z - pz) ** 2);
          if (d < 40) { entNear++; nearbyY.push(ent.y); }
          if (d < 30 && entNear < 20) console.log(`  ENT id=${ent.id} y=${ent.y?.toFixed(2)} x=${ent.x?.toFixed(2)} z=${ent.z?.toFixed(2)} dist=${d.toFixed(0)} hp=${ent.hp}`);
        }
      }
    }
  }
  console.log(`  max entities/snap: ${entSeen}, within 40yd: ${entNear}`);
  if (nearbyY.length > 0) {
    const yMin = Math.min(...nearbyY), yMax = Math.max(...nearbyY);
    console.log(`  entity Y range: ${yMin.toFixed(2)} - ${yMax.toFixed(2)}`);
  }

  // ---- 3. Death check ----
  console.log(`\n--- 3. Death Check ---`);
  console.log(`  deaths: ${c.deaths}`);
  if (c.deaths > 0) console.log('  ⚠️ PLAYER DIED!');

  // ---- 4. HP monitoring during movement ----
  console.log('\n--- 4. Move + HP Monitor (10s) ---');
  const hpBaseline = latestSnaps.find(s => s.self?.hp)?.self?.hp ?? '?';
  console.log(`  baseline HP: ${hpBaseline}`);
  const hpSamples = [];
  const hpStartIdx = c.snaps.length;

  for (let i = 0; i < 200; i++) {
    c.ws.send(JSON.stringify({ t: 'input', seq: i, mi: { f: 1, b: 0, l: 0, r: 0 }, facing: 1.57 }));
    await sleep(50);
  }
  c.ws.send(JSON.stringify({ t: 'input', seq: 500, mi: { f: 0, b: 0, l: 0, r: 0 }, facing: 1.57 }));
  await sleep(3000);

  const hpEndIdx = c.snaps.length;
  for (const snap of c.snaps.slice(hpStartIdx)) {
    if (snap.self?.hp) hpSamples.push(snap.self.hp);
  }
  if (hpSamples.length > 0) {
    const hpMin = Math.min(...hpSamples);
    const hpMax = Math.max(...hpSamples);
    const hpLast = hpSamples[hpSamples.length - 1];
    console.log(`  HP: min=${hpMin} max=${hpMax} last=${hpLast} samples=${hpSamples.length}`);
    if (hpLast < hpMax) console.log('  ⚠️ PLAYER TOOK DAMAGE DURING MOVEMENT!');
    else console.log('  ✅ no damage taken');
  }

  // ---- 5. Y vs groundHeight at multiple X offsets ----
  console.log('\n--- 5. Self Y Across Movement ---');
  const yByX = [];
  for (const snap of c.snaps.slice(hpStartIdx)) {
    if (snap.self?.x !== undefined && snap.self?.y !== undefined) {
      yByX.push({ x: snap.self.x, z: snap.self.z, y: snap.self.y, t: snap.tick });
    }
  }
  if (yByX.length > 0) {
    let maxDy = 0, maxDx = 0;
    console.log(`  ${yByX.length} position samples collected`);
    for (let i = 1; i < yByX.length; i++) {
      const dy = Math.abs(yByX[i].y - yByX[i-1].y);
      const dx = Math.sqrt((yByX[i].x - yByX[i-1].x)**2 + (yByX[i].z - yByX[i-1].z)**2);
      if (dy > maxDy) maxDy = dy;
      if (dx > maxDx) maxDx = dx;
    }
    console.log(`  max Y change: ${maxDy.toFixed(3)}  max XZ step: ${maxDx.toFixed(3)}`);

    // sample first 5, middle 5, last 5
    const samples = [yByX[0], yByX[Math.floor(yByX.length/4)], yByX[Math.floor(yByX.length/2)],
      yByX[Math.floor(3*yByX.length/4)], yByX[yByX.length-1]];
    for (const s of samples.filter(Boolean)) {
      console.log(`  pos: (${s.x?.toFixed(1)},${s.z?.toFixed(1)}) y=${s.y?.toFixed(2)}`);
    }
  }

  const deaths = c.deaths > 0;
  const damaged = hpSamples.length > 0 && hpSamples[hpSamples.length-1] < hpSamples[0];

  console.log(`\n=== SUMMARY ===`);
  console.log(`deaths: ${c.deaths > 0 ? 'FAIL' : 'none'}`);
  console.log(`damage: ${damaged ? 'FAIL' : 'none'}`);
  const jitterVer = yByX.length > 1 ? Math.abs(yByX[yByX.length-1].y - yByX[0].y) : 0;
  console.log(`y range: ${yByX.length > 0 ? Math.min(...yByX.map(p=>p.y)).toFixed(2)+' - '+Math.max(...yByX.map(p=>p.y)).toFixed(2) : 'no samples'}`);

  c.ws.close();
  process.exit((deaths || damaged) ? 1 : 0);
})().catch(e => { console.error('FATAL', e.message); process.exit(2); });
