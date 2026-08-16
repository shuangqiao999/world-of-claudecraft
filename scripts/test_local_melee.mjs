// Verify NORMAL local melee auto-attack end-to-end against the running Moon server.
//
// This deliberately uses the `target` command (not `dev_target`) so the server takes
// the real enterAutoFight path: combatState -> AUTO_FIGHT, then startAutoAttack with the
// standard swingTimer accumulation. It pins the fact that the swingTimer stall observed
// under `dev_target` (which bypasses enterAutoFight and leaves combatState idle) does NOT
// affect real gameplay.
//
// Asserts three things:
//   1. `target <wolf>` flips self.cst to 'auto_fight' (enterAutoFight ran).
//   2. auto_attack swings fire and land damage (dmg > 0).
//   3. the wolf's HP actually drops.
//
// Requires: server running with ALLOW_DEV_COMMANDS=1 (to level/equip/spawn the wolf).
// Usage:
//   DATABASE_URL=... SHARDS=32 node scripts/test_local_melee.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const SHARDS = Number(process.env.SHARDS ?? 32);
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function check(name, cond, extra) {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

async function seed(pool, count, offset) {
  const usernames = [], names = [], tokens = [];
  const L = 'abcdefghijklmnopqrstuvwxyz';
  const letters = (n) => {
    let s = '';
    let x = n + 1;
    while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); }
    return s;
  };
  for (let i = 0; i < count; i++) {
    const k = offset + i;
    usernames.push(`xl${RUN}${String(k).padStart(5, '0')}`);
    names.push(`L${RUN}${letters(k)}`.slice(0, 16));
    tokens.push(randomBytes(32).toString('hex'));
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const accts = await client.query(
      `INSERT INTO accounts (username, password_hash)
       SELECT u, $2 FROM unnest($1::text[]) AS u
       ON CONFLICT (username) DO NOTHING
       RETURNING id, username`,
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
       ON CONFLICT (name) DO NOTHING
       RETURNING id, account_id`,
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

function cmd(ws, name, args = {}) {
  ws.send(JSON.stringify({ t: 'cmd', cmd: name, ...args }));
}
function logout(ws) {
  try { ws.send(JSON.stringify({ t: 'logout' })); } catch {}
  try { ws.close(); } catch {}
}
function asObj(r) { return typeof r === 'string' ? JSON.parse(r) : r; }

function attachObserver(sock) {
  const state = { cst: null, selfTarget: null, auto: null, swing: null, ents: new Map(), swings: [] };
  sock.ws.on('message', (d) => {
    let m; try { m = JSON.parse(d.toString()); } catch { return; }
    if (m.t === 'snap') {
      if (m.self !== undefined) {
        const s = asObj(m.self);
        if (s.cst !== undefined) state.cst = s.cst;
        if (s.target !== undefined) state.selfTarget = s.target;
        if (s.auto !== undefined) state.auto = s.auto;
        if (s.swing !== undefined) state.swing = s.swing;
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
      for (const ev of arr) if (ev.type === 'auto_attack') state.swings.push(ev);
    }
  });
  return state;
}

async function main() {
  const t0 = Date.now();
  if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }
  console.log(`[melee] target=${BASE} shards=${SHARDS} run=${RUN}`);

  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  const bots = [];
  try {
    const { bots: seeded, accountIds } = await seed(pool, 1, 0);
    const b = seeded[0];
    const conn = await connect(b.token, b.charId);
    bots.push(conn.ws);
    console.log(`[melee] joined pid=${conn.pid} shard=${conn.pid % SHARDS}`);

    const state = attachObserver(conn);

    cmd(conn.ws, 'dev_level', { level: 20 });
    await sleep(500);
    cmd(conn.ws, 'dev_give', { item: 'worn_sword' });
    await sleep(300);
    cmd(conn.ws, 'equip', { item: 'worn_sword' });
    await sleep(500);

    // Move to an empty area (away from town service NPCs / pedestrians) so the spawned
    // wolf is the only nearby entity and its snapshot record is unambiguous. Wait long
    // enough for the shard migration to land, or the spawned wolf ends up in a different
    // shard and the combatTick target-invalid check idles the player.
    cmd(conn.ws, 'dev_teleport', { x: 3000, z: 3000 });
    await sleep(8000);

    // dev_give with no item spawns a hostile forest_wolf beside the player.
    cmd(conn.ws, 'dev_give', {});
    await sleep(1000);
    const wolf = [...state.ents.values()].find((e) => e.k === 'mob' && e.tid === 'forest_wolf');
    if (!wolf) {
      check('target wolf enters auto_fight', false, 'no spawned wolf observed');
      check('melee swings land damage', false, 'no wolf');
      check('wolf hp drops', false, 'no wolf');
    } else {
      const wolfId = wolf.id;
      const hpBefore = wolf.hp ?? wolf.mhp;
      // REAL combat path: `target` -> enterAutoFight (sets combatState AUTO_FIGHT + startAutoAttack).
      cmd(conn.ws, 'target', { id: wolfId });
      await sleep(800);
      check('target wolf enters auto_fight (self.cst)', state.cst === 'auto_fight', `cst=${state.cst}`);
      // Log auto/swing each second to observe swingTimer accumulation (debug).
      for (let i = 0; i < 6; i++) {
        await sleep(1000);
        console.log(`[melee] t+${i + 1}s cst=${state.cst} auto=${state.auto} swing=${state.swing} target=${state.selfTarget}`);
      }

      // Give the swing a few seconds to accumulate past weaponSpeed and land a hit.
      const land = state.swings.filter((ev) => ev.targetId === wolfId && (ev.dmg ?? 0) > 0);
      check('melee swings land damage (dmg > 0)', land.length > 0,
        `swings=${state.swings.length} landed=${land.length} dmg=[${state.swings.map((ev) => ev.dmg).join(',')}]`);

      const wolfNow = state.ents.get(wolfId);
      const hpNow = wolfNow ? (wolfNow.hp ?? hpBefore) : hpBefore;
      check('wolf hp drops', hpNow < hpBefore, `hp ${hpBefore} -> ${hpNow}`);
    }

    console.log(`\n[melee] done in ${((Date.now() - t0) / 1000).toFixed(1)}s — ${failures === 0 ? 'RESULT: PASS' : 'RESULT: FAIL'}`);

    for (const w of bots) logout(w);
    await sleep(500);
    await cleanup(pool, accountIds);
  } finally {
    await pool.end().catch(() => {});
  }
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
