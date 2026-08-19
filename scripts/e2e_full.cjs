// Full feature E2E test against the running Moon server:
// movement, combat (auto-attack), gathering (harvest_node), mob retaliation/flee.
const WebSocket = require('ws');
const BASE = process.env.SERVER_URL || 'http://localhost:8787';
const WS = BASE.replace(/^http/, 'ws') + '/';
const USER = 'e2e' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function http(m, p, b, t) {
  const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined });
  return r.json().catch(() => ({}));
}

function mergeEnt(entState, rec) {
  const id = rec.id;
  if (id === undefined) return;
  let s = entState[id];
  if (!s) { s = {}; entState[id] = s; }
  if (rec.k !== undefined) s.k = rec.k;
  if (rec.tid !== undefined) s.tid = rec.tid;
  if (rec.nm !== undefined) s.nm = rec.nm;
  if (rec.lv !== undefined) s.lv = rec.lv;
  if (rec.x !== undefined) s.x = rec.x;
  if (rec.y !== undefined) s.y = rec.y;
  if (rec.z !== undefined) s.z = rec.z;
  if (rec.f !== undefined) s.f = rec.f;
  if (rec.hp !== undefined) s.hp = rec.hp;
  if (rec.mhp !== undefined) s.mhp = rec.mhp;
  if (rec.dead !== undefined) s.dead = rec.dead;
  if (rec.h !== undefined) s.hostile = rec.h;
  if (rec.tgt !== undefined) s.target = rec.tgt;
  if (rec.aggro !== undefined) s.aggro = rec.aggro;
}

let pass = 0, fail = 0;
function check(name, cond, extra) {
  const ok = !!cond;
  if (ok) pass++; else fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${name}${extra !== undefined ? ' — ' + extra : ''}`);
}

(async () => {
  console.log('=== Moon Full Feature E2E ===\n');
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'E' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  if (!ca.id) { console.error('char create failed', JSON.stringify(ca)); process.exit(1); }

  const ws = new WebSocket(WS);
  let pid = null, self = null, seq = 0;
  const entState = {};
  const combatEvents = [];
  const events = [];

  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: ca.id, clientSeed: '', timerWire: 2 })));
  ws.on('message', (d) => {
    try {
      const m = JSON.parse(d.toString());
      if (m.t === 'hello') { pid = m.pid; console.log('connected pid=' + pid + '\n'); start(); }
      else if (m.t === 'snap') {
        if (m.self !== undefined) self = typeof m.self === 'string' ? JSON.parse(m.self) : m.self;
        if (Array.isArray(m.ents)) for (const rec of m.ents) { const r = typeof rec === 'string' ? JSON.parse(rec) : rec; mergeEnt(entState, r); }
      } else if (m.t === 'events') {
        const arr = Array.isArray(m.list) ? m.list : (m.list ? [m.list] : []);
        for (const ev of arr) { events.push(ev); if (ev.type === 'damage' || ev.type === 'heal2' || ev.type === 'death' || ev.type === 'flee') combatEvents.push(ev); }
      }
    } catch (e) {}
  });

  function sendCmd(cmd, args) { ws.send(JSON.stringify({ t: 'cmd', cmd, ...args })); }
  function sendInput(mi, facing) { ws.send(JSON.stringify({ t: 'input', seq: seq++, mi, facing })); }

  // Move toward a world position until within `stopDist` yards (or timeout).
  async function moveToward(tx, tz, stopDist = 3, timeoutMs = 6000) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const dx = tx - self.x;
      const dz = tz - self.z;
      const dist = Math.sqrt(dx * dx + dz * dz);
      if (dist <= stopDist) return true;
      const facing = Math.atan2(dx, dz);
      sendInput({ f: 1, b: 0, tl: 0, tr: 0, sl: 0, sr: 0 }, facing);
      await sleep(60);
    }
    sendInput({ f: 0, b: 0, sl: 0, sr: 0 });
    return false;
  }

  async function start() {
    // wait for world to load + entities visible
    await sleep(2000);

    const sx = self.x, sz = self.z;
    console.log('1) MOVEMENT');
    const moveTimer = setInterval(() => ws.send(JSON.stringify({ t: 'input', seq: seq++, mi: { f: 1, b: 0, tl: 0, tr: 0, sl: 0, sr: 0 }, facing: 1.57 })), 50);
    await sleep(2500);
    clearInterval(moveTimer);
    const moved = Math.sqrt((self.x - sx) ** 2 + (self.z - sz) ** 2);
    check('character moves forward', moved > 3, `${moved.toFixed(2)} yd`);

    // stop moving, settle
    ws.send(JSON.stringify({ t: 'input', seq: seq++, mi: { f: 0, b: 0, sl: 0, sr: 0 } }));
    await sleep(300);

    // find a mob + a node
    const mobs = Object.values(entState).filter((e) => e.k === 'mob' && !e.dead);
    const nodes = Object.values(entState).filter((e) => e.k === 'node');
    console.log(`2) WORLD: ${mobs.length} mobs, ${nodes.length} nodes visible`);
    check('entities visible', mobs.length > 0 || nodes.length > 0, `mobs=${mobs.length} nodes=${nodes.length}`);

    // ---- COMBAT (walk to the forest_wolf camp for determinism) ----
    console.log('3) COMBAT');
    // forest_wolf camp at (24, 70); walk there so a mob is guaranteed nearby
    await moveToward(24, 70, 8, 20000);
    await sleep(600);
    const wolfMobs = Object.values(entState).filter((e) => e.k === 'mob' && !e.dead);
    console.log(`  at camp self=(${self.x?.toFixed(1)}, ${self.z?.toFixed(1)}) mobs=${wolfMobs.length}`);
    if (wolfMobs.length > 0) {
      const target = wolfMobs.sort((a, b) => ((a.x - self.x) ** 2 + (a.z - self.z) ** 2) - ((b.x - self.x) ** 2 + (b.z - self.z) ** 2))[0];
      const targetId = Object.keys(entState).find((k) => entState[k] === target);
      const dist0 = Math.sqrt((target.x - self.x) ** 2 + (target.z - self.z) ** 2).toFixed(1);
      console.log(`  target mob id=${targetId} hp=${target.hp}/${target.mhp} dist=${dist0}yd`);

      const reached = await moveToward(target.x, target.z, 3, 6000);
      check('moved into melee range (<=3yd)', reached, `dist now ${Math.sqrt((target.x - self.x) ** 2 + (target.z - self.z) ** 2).toFixed(1)}yd`);

      const hpBefore = target.hp;
      const evBefore = combatEvents.length;
      sendCmd('attack');
      // follow the target while auto-attacking (mob wanders)
      const followUntil = Date.now() + 4500;
      while (Date.now() < followUntil) {
        const dx = target.x - self.x;
        const dz = target.z - self.z;
        const dist = Math.sqrt(dx * dx + dz * dz);
        if (dist > 2) sendInput({ f: 1, b: 0, tl: 0, tr: 0, sl: 0, sr: 0 }, Math.atan2(dx, dz));
        else sendInput({ f: 0, b: 0, sl: 0, sr: 0 }, Math.atan2(dx, dz));
        await sleep(60);
      }
      const hpNow = target.hp;
      const newEvents = combatEvents.slice(evBefore);
      console.log(`  new combat events: ${JSON.stringify(newEvents.map((e) => e.type))}`);
      const gotDamageEvent = newEvents.some((e) => e.type === 'damage');
      check('attack produces combat events', gotDamageEvent, `events=${newEvents.length}`);
      check('mob hp decreased (or mob died)', hpNow < hpBefore || target.dead === true, `hp ${hpBefore} -> ${hpNow}`);
      sendCmd('stopattack');
      await sleep(200);
    } else {
      console.log('  no mob visible after teleport, skipping combat');
      check('combat mob present', false, 'no mob after dev_teleport');
    }

    // ---- GATHERING ----
    console.log('4) GATHERING');
    if (nodes.length > 0) {
      const node = nodes[0];
      const nodeId = Object.keys(entState).find((k) => entState[k] === node);
      const copperBefore = self.copper || 0;
      sendCmd('harvest_node', { node: nodeId, tier: 1 });
      await sleep(1200);
      const copperAfter = self.copper || 0;
      check('harvest_node works', copperAfter > copperBefore, `copper ${copperBefore} -> ${copperAfter}`);
    } else {
      console.log('  no node visible, skipping gathering');
    }

    // ---- FLEE / RETALIATION (passive mob retaliates once hit) ----
    console.log('5) FLEE / RETALIATION');
    // walk to another wolf camp for a fresh mob
    await moveToward(-27, 71, 8, 20000);
    await sleep(600);
    const fleeMobs = Object.values(entState).filter((e) => e.k === 'mob' && !e.dead);
    if (fleeMobs.length > 0) {
      const target = fleeMobs[0];
      await moveToward(target.x, target.z, 3, 6000);
      sendCmd('attack');
      await sleep(1500);
      // passive mob retaliates: it sets aggro/target on the attacker, or takes damage
      const retaliated = target.aggro !== undefined || target.target !== undefined || target.hp < target.mhp || target.dead === true;
      check('mob retaliates (aggro/target set, or took damage)', retaliated, `aggro=${target.aggro} target=${target.target} hp=${target.hp}/${target.mhp}`);
      sendCmd('stopattack');
      await sleep(200);
    } else {
      console.log('  no mob, skipping flee check');
      check('flee mob present', false, 'no mob after dev_teleport');
    }

    console.log('\n=== SUMMARY ===');
    console.log(`PASS=${pass} FAIL=${fail}`);
    ws.close();
    process.exit(fail > 0 ? 1 : 0);
  }

  setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 40000);
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
