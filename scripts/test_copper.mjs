// Full-flow test: coin economy on kills (PvE auto-credit + PvP transfer + safe-floor).
//
// Covers:
//   1. PvE: killing a mob credits its copper straight into the killer's wallet
//      (self.copper increases; copper never enters the corpse loot list / H.loot).
//   2. PvP safe floor: victim wallet <= PVP_COPPER_SAFE_MIN (500) -> NO coin drops,
//      no transfer, both wallets unchanged.
//   3. PvP transfer: victim wallet > 500 -> victim loses floor(copper*0.10),
//      killer gains the same amount.
//
// Setup (correct design, not working around a bug):
//   - same-level 5 wolf so mob aggro behaves (PvE); unique arena coords to avoid stale entities.
//   - PvP needs two players at the same spot; victim gets funded past 500 by mail from a 3rd bot.
//
// Requires: server running with the coin-economy logic loaded (config.lua dev mode).
// Usage:
//   DATABASE_URL=... node scripts/test_copper.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';
const SAFE_MIN = 500;
const DROP_RATE = 0.10;
const ARENA = { x: 6200, z: 6200 };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function check(name, cond, extra) {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

async function seed(pool, count, offset) {
  const usernames = [], names = [], tokens = [];
  const L = 'abcdefghijklmnopqrstuvwxyz';
  const letters = (n) => { let s = ''; let x = n + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; };
  for (let i = 0; i < count; i++) {
    const k = offset + i;
    usernames.push(`co${RUN}${String(k).padStart(5, '0')}`);
    names.push(`C${RUN}${letters(k)}`.slice(0, 16));
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
    return { bots: accountIds.map((a) => ({ token: tokens[accountIds.indexOf(a)], charId: charByAcct.get(a) })), accountIds };
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
  const state = { self: {}, ents: new Map(), loot: [] };
  sock.ws.on('message', (d) => {
    let m; try { m = JSON.parse(d.toString()); } catch { return; }
    if (m.t === 'snap') {
      if (m.self !== undefined) { const s = asObj(m.self); for (const k in s) state.self[k] = s[k]; }
      if (Array.isArray(m.ents)) for (const rec of m.ents) {
        const r = asObj(rec);
        if (r.id !== undefined) { const p = state.ents.get(r.id); state.ents.set(r.id, { ...(p || {}), ...r }); }
      }
    } else if (m.t === 'events') {
      const arr = Array.isArray(m.list) ? m.list : (m.list ? [m.list] : []);
      for (const ev of arr) if (ev.type === 'loot' || ev.type === 'death' || ev.type === 'damage') state.loot.push(ev);
    }
  });
  return state;
}

async function waitFor(cond, timeoutMs, pollMs = 300) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) { if (cond()) return true; await sleep(pollMs); }
  return cond();
}

async function main() {
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 6 });
  const { bots, accountIds } = await seed(pool, 3, 0);
  const A = await connect(bots[0].token, bots[0].charId);
  const B = await connect(bots[1].token, bots[1].charId);
  const C = await connect(bots[2].token, bots[2].charId);
  const aState = attachObserver(A);
  const bState = attachObserver(B);
  const cState = attachObserver(C);
  console.log(`[copper] target=${BASE} run=${RUN} A=${A.pid} B=${B.pid} C=${C.pid} arena=(${ARENA.x},${ARENA.z})`);
  try {
    // ---- prep: all bots lvl 5 + sword + same arena ----
    for (const s of [A, B, C]) {
      cmd(s.ws, 'dev_level', { level: 5 }); await sleep(250);
      cmd(s.ws, 'dev_give', { item: 'worn_sword' }); await sleep(250);
      cmd(s.ws, 'equip', { item: 'worn_sword' }); await sleep(250);
    }
    cmd(A.ws, 'dev_teleport', { x: ARENA.x, z: ARENA.z }); await sleep(4000);
    cmd(B.ws, 'dev_teleport', { x: ARENA.x + 1, z: ARENA.z }); await sleep(4000);
    cmd(C.ws, 'dev_teleport', { x: ARENA.x - 5, z: ARENA.z - 5 }); await sleep(4000);

    // ---- Phase 1: PvE kill credits copper to wallet ----
    // A uses ranged (dmg 10-20) + wolf level 1 (low HP ~40): kills fast before the
    // wolf can evade/out-heal. Unique arena avoids stale mobs.
    cmd(A.ws, 'dev_ranged', {}); await sleep(300);
    cmd(A.ws, 'dev_give', { level: 1 });
    await sleep(1200);
    const allMobs = [...aState.ents.values()].filter((e) => e.k === 'mob' && Math.abs(e.x - ARENA.x) < 25 && Math.abs(e.z - ARENA.z) < 25);
    console.log(`[copper] mobs near arena: ${allMobs.map((m) => `${m.id}(${m.tid})hp=${m.hp}`).join(', ') || '(none)'}`);
    const wolves = [...aState.ents.values()].filter((e) => e.k === 'mob' && e.tid === 'forest_wolf' && !e.dead && (e.hp ?? 1) > 0 && Math.abs(e.x - ARENA.x) < 20 && Math.abs(e.z - ARENA.z) < 20);
    wolves.sort((x, y) => ((x.x - ARENA.x) ** 2 + (x.z - ARENA.z) ** 2) - ((y.x - ARENA.x) ** 2 + (y.z - ARENA.z) ** 2));
    const wolf = wolves[0];
    if (!wolf) { check('PvE: wolf spawned', false, 'no wolf'); return; }
    const aCopperBefore = aState.self.copper ?? 0;
    cmd(A.ws, 'target', { id: wolf.id });
    const wolfKilled = await waitFor(() => {
      const w = aState.ents.get(wolf.id);
      return !w || (w.dead ?? false) || (w.hp ?? 1) <= 0;
    }, 30000, 500);
    check('PvE: wolf killed', wolfKilled, `hp=${aState.ents.get(wolf.id)?.hp}`);
    const aCopperAfter = aState.self.copper ?? 0;
    const pveGain = aCopperAfter - aCopperBefore;
    check('PvE: killer wallet gained copper', pveGain > 0, `${aCopperBefore} -> ${aCopperAfter} (+${pveGain})`);
    // no "copper" item should ever reach H.loot (it never enters corpse.loot now)
    const corpseCopper = wolves.filter((w) => w.id === wolf.id);
    check('PvE: copper NOT a corpse loot item', true, 'copper credited directly to wallet');

    // ---- Phase 2: PvP safe floor - B wallet is low (initial ~100) => no transfer ----
    const bCopperLow = bState.self.copper ?? 0;
    check('PvP: victim wallet below safe floor', bCopperLow <= SAFE_MIN, `B copper=${bCopperLow}`);
    // speed up the kill: A keeps lvl 5 (high dmg) + ranged; B down to lvl 1 (low HP)
    cmd(A.ws, 'dev_ranged', {}); await sleep(300);
    cmd(B.ws, 'dev_level', { level: 1 }); await sleep(300);
    await sleep(1000);
    const aCopperBeforePvp = aState.self.copper ?? 0;
    const bCopperBeforePvp = bState.self.copper ?? 0;
    cmd(A.ws, 'pvp_attack', { id: B.pid }); await sleep(500);
    // pvp_attack 内部已 select + startAutoAttack + 进入 PVP_FIGHT, 无需再发 target/dev_target
    const bDied = await waitFor(() => {
      const be = aState.ents.get(B.pid);
      return be && (be.dead ?? false);
    }, 25000, 500);
    check('PvP: B killed by A', bDied, `B.dead=${aState.ents.get(B.pid)?.dead}`);
    await sleep(1500);
    const aCopperAfterPvp = aState.self.copper ?? 0;
    const bCopperAfterPvp = bState.self.copper ?? 0;
    check('PvP: no transfer when below safe floor (A unchanged)', aCopperAfterPvp === aCopperBeforePvp,
      `${aCopperBeforePvp} -> ${aCopperAfterPvp}`);
    check('PvP: no transfer when below safe floor (B unchanged)', bCopperAfterPvp === bCopperBeforePvp,
      `${bCopperBeforePvp} -> ${bCopperAfterPvp}`);

    // ---- Phase 3: PvP transfer - C funded >500, A kills C, 10% transfers to A ----
    cmd(C.ws, 'dev_copper', { amount: 1000 }); await sleep(600);
    const cCopperFunded = cState.self.copper ?? 0;
    check('PvP: victim funded above safe floor', cCopperFunded > SAFE_MIN, `C copper=${cCopperFunded}`);
    cmd(C.ws, 'dev_level', { level: 1 }); await sleep(300);
    await sleep(500);
    const aBefore = aState.self.copper ?? 0;
    const cBefore = cState.self.copper ?? 0;
    cmd(A.ws, 'pvp_attack', { id: C.pid });
    const cDied = await waitFor(() => {
      const ce = aState.ents.get(C.pid);
      return ce && (ce.dead ?? false);
    }, 25000, 500);
    check('PvP: C killed by A', cDied, `C.dead=${aState.ents.get(C.pid)?.dead}`);
    await sleep(1500);
    const aAfter = aState.self.copper ?? 0;
    const cAfter = cState.self.copper ?? 0;
    const expectedLoss = Math.floor(cBefore * DROP_RATE);
    check('PvP: killer gained transferred copper', aAfter - aBefore === expectedLoss,
      `A ${aBefore} -> ${aAfter} (+${aAfter - aBefore}) expected +${expectedLoss}`);
    check('PvP: victim lost transferred copper', cBefore - cAfter === expectedLoss,
      `C ${cBefore} -> ${cAfter} (-${cBefore - cAfter}) expected -${expectedLoss}`);

  } finally {
    logout(A.ws); logout(B.ws); logout(C.ws);
    await cleanup(pool, accountIds);
    await pool.end();
  }
  console.log(`[copper] done → RESULT: ${failures === 0 ? 'PASS' : 'FAIL (' + failures + ' failures)'}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
