// Full-flow test: auto_fight auto-chase combat (server-side auto-chase movement control layer).
//
// Test setup (correct design, not working around a Lua bug):
//   - Player and wolf are SAME level (5) so the mob "trivial" mechanic
//     (isTrivialTo: player >= mob level+10 -> mob won't aggro) cannot suppress
//     the wolf counterattack. "Select-to-fight" is the player's prerogative;
//     level-difference combat balance is a separate system.
//   - Unique arena (5000,5000) avoids stale corpses/live wolves from prior runs.
//
// Covers:
//   1. target wolf -> auto_fight + auto-face + auto-chase (server moves player)
//   2. player catches wolf, closes to melee, swings deal damage, wolf aggros & counters
//   3. manual movement (direction key) -> auto-chase permanently off; player obeys keys;
//      releasing keys leaves the player standing still (no auto-chase resume)
//   4. re-targeting the same target re-activates auto-chase + auto-attack
//   5. clearing the target ends auto_fight / auto-chase
//
// The test sends NO movement input except the deliberate intervene in phase 3.
//
// Requires: server running with the auto-chase logic loaded (config.lua dev mode).
// Usage:
//   DATABASE_URL=... node scripts/test_auto_face.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';
const MELEE_RANGE = 5;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function check(name, cond, extra) {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}
function angleDiff(a, b) {
  let d = a - b;
  while (d > Math.PI) d -= 2 * Math.PI;
  while (d < -Math.PI) d += 2 * Math.PI;
  return d;
}

async function seed(pool, count, offset) {
  const usernames = [], names = [], tokens = [];
  const L = 'abcdefghijklmnopqrstuvwxyz';
  const letters = (n) => {
    let s = ''; let x = n + 1;
    while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); }
    return s;
  };
  for (let i = 0; i < count; i++) {
    const k = offset + i;
    usernames.push(`af${RUN}${String(k).padStart(5, '0')}`);
    names.push(`A${RUN}${letters(k)}`.slice(0, 16));
    tokens.push(randomBytes(32).toString('hex'));
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const accts = await client.query(
      `INSERT INTO accounts (username, password_hash)
       SELECT u, $2 FROM unnest($1::text[]) AS u
       ON CONFLICT (username) DO NOTHING RETURNING id, username`,
      [usernames, SEED_HASH],
    );
    if (accts.rows.length !== count) throw new Error(`account seed: ${accts.rows.length}/${count}`);
    const idByUser = new Map(accts.rows.map((r) => [r.username, r.id]));
    const accountIds = usernames.map((u) => idByUser.get(u));
    await client.query(
      `INSERT INTO auth_tokens (token, account_id, expires_at)
       SELECT t, a, now() + interval '12 hours' FROM unnest($1::text[], $2::int[]) AS p(t, a)`,
      [tokens, accountIds],
    );
    const chars = await client.query(
      `INSERT INTO characters (account_id, name, class, realm, state)
       SELECT a, n, 'warrior', $3, '{}'::jsonb FROM unnest($1::int[], $2::text[]) AS p(a, n)
       ON CONFLICT (name) DO NOTHING RETURNING id, account_id`,
      [accountIds, names, REALM],
    );
    if (chars.rows.length !== count) throw new Error(`char seed: ${chars.rows.length}/${count}`);
    const charByAcct = new Map(chars.rows.map((r) => [r.account_id, r.id]));
    await client.query('COMMIT');
    const bots = accountIds.map((a) => ({ token: tokens[accountIds.indexOf(a)], charId: charByAcct.get(a) }));
    return { bots, accountIds };
  } catch (e) { await client.query('ROLLBACK').catch(() => {}); throw e; }
  finally { client.release(); }
}

async function cleanup(pool, accountIds) {
  for (let i = 0; i < accountIds.length; i += 500) {
    await pool.query('DELETE FROM accounts WHERE id = ANY($1::int[])', [accountIds.slice(i, i + 500)]);
  }
}

function connect(token, charId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS);
    let done = false;
    const to = setTimeout(() => { if (!done) { done = true; try { ws.terminate(); } catch {} reject(new Error('join timeout')); } }, 30000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', (d) => {
      if (done) return;
      let m; try { m = JSON.parse(d.toString()); } catch { return; }
      if (m.t === 'hello') { done = true; clearTimeout(to); resolve({ ws, pid: m.pid }); }
      else if (m.t === 'error') { done = true; clearTimeout(to); try { ws.close(); } catch {} reject(new Error(m.error ?? 'auth error')); }
    });
    ws.on('error', (e) => { if (!done) { done = true; clearTimeout(to); reject(e); } });
    ws.on('close', () => { if (!done) { done = true; clearTimeout(to); reject(new Error('closed before hello')); } });
  });
}

function cmd(ws, name, args = {}) { ws.send(JSON.stringify({ t: 'cmd', cmd: name, ...args })); }
function logout(ws) { try { ws.send(JSON.stringify({ t: 'logout' })); } catch {} try { ws.close(); } catch {} }
function asObj(r) { return typeof r === 'string' ? JSON.parse(r) : r; }

function attachObserver(sock) {
  const state = { cst: null, selfTarget: null, auto: null, swing: null, selfX: null, selfZ: null, selfF: null, ents: new Map(), swings: [] };
  sock.ws.on('message', (d) => {
    let m; try { m = JSON.parse(d.toString()); } catch { return; }
    if (m.t === 'snap') {
      if (m.self !== undefined) {
        const s = asObj(m.self);
        if (s.cst !== undefined) state.cst = s.cst;
        if (s.target !== undefined) state.selfTarget = s.target;
        if (s.auto !== undefined) state.auto = s.auto;
        if (s.swing !== undefined) state.swing = s.swing;
        if (s.x !== undefined) state.selfX = s.x;
        if (s.z !== undefined) state.selfZ = s.z;
        if (s.f !== undefined) state.selfF = s.f;
      }
      if (Array.isArray(m.ents)) {
        for (const rec of m.ents) {
          const r = asObj(rec);
          if (r.id !== undefined) {
            const prev = state.ents.get(r.id);
            state.ents.set(r.id, { ...(prev || {}), ...r });
          }
        }
      }
    } else if (m.t === 'events') {
      const arr = Array.isArray(m.list) ? m.list : (m.list ? [m.list] : []);
      for (const ev of arr) if (ev.type === 'damage') state.swings.push(ev);
    }
  });
  return state;
}

async function waitFor(cond, timeoutMs, pollMs = 500) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (cond()) return true;
    await sleep(pollMs);
  }
  return cond();
}

async function main() {
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 4 });
  const { bots, accountIds } = await seed(pool, 1, 0);
  const conn = await connect(bots[0].token, bots[0].charId);
  const state = attachObserver(conn);
  const self = conn.pid;
  const PX = 5000, PZ = 5000;
  console.log(`[autoFace] target=${BASE} run=${RUN} joined pid=${self} arena=(${PX},${PZ})`);
  try {
    cmd(conn.ws, 'dev_level', { level: 5 });
    await sleep(400);
    cmd(conn.ws, 'dev_give', { item: 'worn_sword' });
    await sleep(300);
    cmd(conn.ws, 'equip', { item: 'worn_sword' });
    await sleep(400);
    cmd(conn.ws, 'dev_teleport', { x: PX, z: PZ });
    await sleep(6000);

    cmd(conn.ws, 'dev_give', { level: 5 });
    await sleep(1500);

    const aliveWolves = [...state.ents.values()].filter(
      (e) => e.k === 'mob' && e.tid === 'forest_wolf' && (e.dead ?? false) === false && (e.hp ?? 1) > 0
        && Math.abs(e.x - PX) < 20 && Math.abs(e.z - PZ) < 20);
    aliveWolves.sort((a, b) => ((a.x - PX) ** 2 + (a.z - PZ) ** 2) - ((b.x - PX) ** 2 + (b.z - PZ) ** 2));
    const wolf = aliveWolves[0];
    if (!wolf) { check('spawned wolf observed', false, 'no forest_wolf near arena'); return; }
    const wolfId = wolf.id;
    const hpBefore = wolf.hp ?? wolf.mhp;
    const startX = state.selfX, startZ = state.selfZ;
    console.log(`[autoFace] wolf=${wolfId} hp=${hpBefore} player=(${startX},${startZ}) wolf=(${wolf.x},${wolf.z})`);

    // ---- Phase 1: select-to-fight + auto-face + auto-chase (no movement input) ----
    cmd(conn.ws, 'target', { id: wolfId });
    const okAutoFight = await waitFor(() => state.cst === 'auto_fight', 3000, 300);
    check('target wolf enters auto_fight', okAutoFight, `cst=${state.cst}`);
    const okAuto = await waitFor(() => state.auto === true, 3000, 300);
    check('autoAttack enabled', okAuto, `auto=${state.auto}`);

    const okMoved = await waitFor(() => {
      const moved = Math.hypot(state.selfX - startX, state.selfZ - startZ) > 1.5;
      const w = state.ents.get(wolfId);
      const close = w ? Math.hypot(w.x - state.selfX, w.z - state.selfZ) <= MELEE_RANGE : false;
      return moved || close;
    }, 12000, 300);
    check('server auto-chases target (moved or already in melee)', okMoved,
      `start=(${startX},${startZ}) now=(${state.selfX},${state.selfZ})`);

    const okFace = await waitFor(() => {
      const w = state.ents.get(wolfId);
      if (!w || state.selfF === null || state.selfX === null) return false;
      const d = Math.abs(angleDiff(state.selfF, Math.atan2(w.x - state.selfX, w.z - state.selfZ)));
      return d < 0.5;
    }, 10000, 300);
    check('character auto-faces target', okFace, `f=${state.selfF?.toFixed?.(3)}`);

    // ---- Phase 2: auto attack -> wolf hp drops + wolf aggros & counters ----
    const okHit = await waitFor(() =>
      state.swings.filter((ev) => ev.targetId === wolfId && (ev.amount ?? 0) > 0).length > 0, 20000, 500);
    const swings = state.swings.filter((ev) => ev.targetId === wolfId && (ev.amount ?? 0) > 0);
    check('damage events delivered to wolf', okHit, `hits=${swings.length} amounts=[${swings.map((e) => e.amount).join(',')}]`);
    const okHpDrop = await waitFor(() => {
      const w = state.ents.get(wolfId);
      return w && (w.hp ?? hpBefore) < hpBefore;
    }, 5000, 500);
    const wolfNow = state.ents.get(wolfId);
    const hpNow = wolfNow ? (wolfNow.hp ?? hpBefore) : hpBefore;
    check('wolf hp drops during auto fight', okHpDrop, `hp ${hpBefore} -> ${hpNow}`);

    const okAggro = await waitFor(() =>
      state.swings.filter((ev) => ev.targetId === self && (ev.amount ?? 0) > 0).length > 0, 20000, 500);
    const incoming = state.swings.filter((ev) => ev.targetId === self && (ev.amount ?? 0) > 0);
    check('wolf aggros and attacks player', okAggro,
      `incoming=${incoming.length} amounts=[${incoming.map((e) => e.amount).join(',')}]`);

    // ---- Phase 3: manual movement -> auto-chase off; stands still after keys released ----
    const posBeforeIntervene = { x: state.selfX, z: state.selfZ };
    const interveneStart = Date.now();
    while (Date.now() - interveneStart < 2000) {
      conn.ws.send(JSON.stringify({ t: 'input', mi: { sl: 1 } }));
      await sleep(200);
    }
    await sleep(500);
    const posAfterKeys = { x: state.selfX, z: state.selfZ };
    const keyMoved = Math.hypot(posAfterKeys.x - posBeforeIntervene.x, posAfterKeys.z - posBeforeIntervene.z);
    check('manual move takes control (player moved by keys)', keyMoved > 0.5, `moved=${keyMoved.toFixed(2)}`);

    await sleep(5000);
    const drifted = Math.hypot(state.selfX - posAfterKeys.x, state.selfZ - posAfterKeys.z);
    check('auto-chase stays OFF after keys released (stands still)', drifted < 2,
      `drifted=${drifted.toFixed(2)}`);

    // ---- Phase 4: re-target -> auto-chase + auto-attack re-engage ----
    let reTargetId = wolfId;
    const curWolf = state.ents.get(wolfId);
    if (!curWolf || (curWolf.dead ?? false) || (curWolf.hp ?? 1) <= 0) {
      cmd(conn.ws, 'dev_give', { level: 5 });
      await sleep(1500);
      const newWolves = [...state.ents.values()].filter(
        (e) => e.k === 'mob' && e.tid === 'forest_wolf' && (e.dead ?? false) === false && (e.hp ?? 1) > 0
          && Math.abs(e.x - (state.selfX ?? PX)) < 25 && Math.abs(e.z - (state.selfZ ?? PZ)) < 25);
      newWolves.sort((a, b) => ((a.x - (state.selfX ?? PX)) ** 2 + (a.z - (state.selfZ ?? PZ)) ** 2) - ((b.x - (state.selfX ?? PX)) ** 2 + (b.z - (state.selfZ ?? PZ)) ** 2));
      if (newWolves[0]) reTargetId = newWolves[0].id;
    }
    cmd(conn.ws, 'target', { id: reTargetId });
    const okRetarget = await waitFor(() => state.cst === 'auto_fight', 3000, 300);
    check('re-target resumes auto_fight', okRetarget, `cst=${state.cst}`);
    const posBeforeRetarget = { x: state.selfX, z: state.selfZ };
    const okReChase = await waitFor(() => {
      const moved = Math.hypot(state.selfX - posBeforeRetarget.x, state.selfZ - posBeforeRetarget.z) > 1.0;
      const w = state.ents.get(reTargetId);
      const close = w ? Math.hypot(w.x - state.selfX, w.z - state.selfZ) <= MELEE_RANGE : false;
      return moved || close;
    }, 10000, 300);
    check('auto-chase RE-ENGAGES after re-target', okReChase,
      `moved=${Math.hypot(state.selfX - posBeforeRetarget.x, state.selfZ - posBeforeRetarget.z).toFixed(2)}`);
    const okSwing2 = await waitFor(() =>
      state.swings.filter((ev) => ev.targetId === reTargetId && (ev.amount ?? 0) > 0).length > 0, 20000, 500);
    const swings2 = state.swings.filter((ev) => ev.targetId === reTargetId && (ev.amount ?? 0) > 0);
    check('auto-attack resumes after re-target', okSwing2, `hits=${swings2.length}`);

    // ---- Phase 5: clear target -> auto_fight + auto-chase off ----
    cmd(conn.ws, 'target', { id: null });
    const okCleared = await waitFor(() => state.cst !== 'auto_fight' && state.auto !== true, 3000, 300);
    check('clear target ends auto_fight + auto-chase', okCleared, `cst=${state.cst} auto=${state.auto}`);
  } finally {
    logout(conn.ws);
    await cleanup(pool, accountIds);
    await pool.end();
  }
  console.log(`[autoFace] done → RESULT: ${failures === 0 ? 'PASS' : 'FAIL (' + failures + ' failures)'}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
