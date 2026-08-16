// Cross-shard combat verification against the running Moon server.
//
// Builds the exact scenario the feature needs: a player in one shard attacks an
// entity (another player) owned by an adjacent shard, where the target is only
// visible to the attacker as a cross-shard ghost (world/ghost.lua + init.lua
// ghostSync + combatForward/combatResult round-trip).
//
// How it works:
//   1. Replicates the server's regionToShard(rx, rz) hash (config.lua) to find an
//      adjacent region pair (rA, rB) that maps to two DIFFERENT shards SA, SB.
//   2. Seeds bots and connects them one at a time. The gate assigns each a pid
//      (a sequential counter) and routes it to shard pid % SHARDS. We keep the
//      first bot landing in SA and the first in SB.
//   3. dev_teleport's each bot to its region's side of the shared boundary, a few
//      yards apart. The SB bot becomes a ghost in SA (and vice-versa) via ghostSync.
//   4. Verifies SA's snapshot contains the SB bot as a ghost entity (id == pid_B).
//   5. SA sends dev_target {id: pid_B} (dev-only command that lets auto-attack target
//      a cross-shard ghost), then we watch for `damage` events on SA and the HP
//      drop on SB.
//
// Requires: server running with ALLOW_DEV_COMMANDS=1 and WOC_WORLD_SHARDS > 1.
// Usage:
//   DATABASE_URL=... SHARDS=32 node scripts/test_cross_shard_combat.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const SHARDS = Number(process.env.SHARDS ?? 32);
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';
const REGION_SIZE = 270;
const BOUNDARY_GAP = 2; // yd from the boundary on each side (4 yd apart, within melee range)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function check(name, cond, extra) {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

// Mirror of config.lua regionToShard (Lua floored modulo).
function regionToShard(rx, rz, n) {
  const a = BigInt(rx) * 2654435761n + BigInt(rz) * 40503n;
  const nB = BigInt(n);
  let m = a % nB;
  if (m < 0n) m += nB;
  return Number(m);
}

// Find an adjacent region pair (east neighbor) with distinct shards, away from the
// spawn area (rx, rz >= 2) so spawn NPC/pedestrian/mob noise is minimal.
function findBoundaryPair(n) {
  for (let rz = 2; rz <= 6; rz++) {
    for (let rx = 2; rx <= 6; rx++) {
      const sA = regionToShard(rx, rz, n);
      const sB = regionToShard(rx + 1, rz, n);
      if (sA !== sB) {
        const boundaryX = (rx + 1) * REGION_SIZE;
        const centerZ = rz * REGION_SIZE + REGION_SIZE / 2;
        return {
          rA: [rx, rz], rB: [rx + 1, rz], sA, sB,
          posA: { x: boundaryX - BOUNDARY_GAP, z: centerZ },
          posB: { x: boundaryX + BOUNDARY_GAP, z: centerZ },
        };
      }
    }
  }
  return null;
}

async function seed(pool, count, offset) {
  const usernames = [], names = [], tokens = [];
  const L = 'abcdefghijklmnopqrstuvwxyz';
  const letters = (n) => { let s = ''; let x = n + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; };
  for (let i = 0; i < count; i++) {
    const k = offset + i;
    usernames.push(`xc${RUN}${String(k).padStart(5, '0')}`);
    names.push(`X${RUN}${letters(k)}`.slice(0, 16));
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

function attachObserver(sock, label) {
  const state = { ents: new Map(), selfHp: null, mhp: null, minHp: null, selfTarget: null, events: [] };
  sock.ws.on('message', (d) => {
    let m; try { m = JSON.parse(d.toString()); } catch { return; }
    if (m.t === 'snap') {
      if (m.self !== undefined) {
        const s = asObj(m.self);
        if (s.hp !== undefined) {
          state.selfHp = s.hp;
          if (state.minHp === null || s.hp < state.minHp) state.minHp = s.hp;
        }
        if (s.mhp !== undefined) state.mhp = s.mhp;
        if (s.target !== undefined) state.selfTarget = s.target;
      }
      if (Array.isArray(m.ents)) {
        for (const rec of m.ents) {
          const r = asObj(rec);
          if (r.id !== undefined) state.ents.set(r.id, { ...(state.ents.get(r.id) || {}), ...r });
        }
      }
    } else if (m.t === 'events') {
      const arr = Array.isArray(m.list) ? m.list : (m.list ? [m.list] : []);
      for (const ev of arr) state.events.push(ev);
    }
  });
  return state;
}

async function main() {
  const t0 = Date.now();
  if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }
  if (SHARDS <= 1) { console.error('SHARDS must be > 1 (server must run with WOC_WORLD_SHARDS > 1)'); process.exit(1); }
  console.log(`[xshard] target=${BASE} shards=${SHARDS} run=${RUN}`);

  const pair = findBoundaryPair(SHARDS);
  if (!pair) { console.error(`[xshard] no adjacent region pair with distinct shards found for SHARDS=${SHARDS}`); process.exit(1); }
  console.log(`[xshard] boundary: rA=(${pair.rA.join(',')}) shard=${pair.sA}  rB=(${pair.rB.join(',')}) shard=${pair.sB}`);
  console.log(`[xshard] posA=(${pair.posA.x},${pair.posA.z})  posB=(${pair.posB.x},${pair.posB.z})`);

  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  const extra = []; // unused sockets to close

  try {
    // Seed enough bots to cover every pid%SHARDS residue (sequential pids cycle all residues).
    const { bots, accountIds } = await seed(pool, SHARDS + 1, 0);
    console.log(`[xshard] seeded ${bots.length} accounts (${((Date.now() - t0) / 1000).toFixed(1)}s)`);

    let botA = null, botB = null;
    for (const b of bots) {
      let conn;
      try { conn = await connect(b.token, b.charId); }
      catch (e) { console.log(`[xshard] join failed char=${b.charId}: ${e.message}`); continue; }
      const shard = conn.pid % SHARDS;
      if (!botA && shard === pair.sA) botA = { ...conn, shard };
      else if (!botB && shard === pair.sB) botB = { ...conn, shard };
      else { extra.push(conn.ws); logout(conn.ws); }
      if (botA && botB) break;
    }

    check(`found attacker bot in shard ${pair.sA}`, !!botA, botA && `pid=${botA.pid}`);
    check(`found defender bot in shard ${pair.sB}`, !!botB, botB && `pid=${botB.pid}`);
    if (!botA || !botB) {
      console.log('[xshard] could not find both shards (verify SHARDS matches server WOC_WORLD_SHARDS)');
      cleanup(pool, accountIds);
      process.exit(1);
    }

    // Survive any nearby camp mobs.
    cmd(botA.ws, 'dev_level', { level: 20 });
    cmd(botB.ws, 'dev_level', { level: 20 });
    await sleep(500);

    const aState = attachObserver(botA, 'A');
    const bState = attachObserver(botB, 'B');

    // Place each bot on its side of the shared boundary.
    cmd(botA.ws, 'dev_teleport', { x: pair.posA.x, z: pair.posA.z });
    cmd(botB.ws, 'dev_teleport', { x: pair.posB.x, z: pair.posB.z });
    await sleep(2000); // wait for ghost sync (GHOST_SYNC_INTERVAL_TICKS=5, ~0.25s)

    const ghostSeen = aState.ents.has(botB.pid);
    check(`attacker sees defender as ghost (id=${botB.pid})`, ghostSeen,
      ghostSeen ? `hp=${aState.ents.get(botB.pid).hp}/${aState.ents.get(botB.pid).mhp}` : '');

    // Real-gameplay targeting: explicit `target {id}` must now accept a cross-shard ghost.
    cmd(botA.ws, 'target', { id: botB.pid });
    await sleep(400);
    check('target command accepts cross-shard ghost id', aState.selfTarget === botB.pid,
      aState.selfTarget !== null ? `self.target=${aState.selfTarget}` : '');

    // Establish PvP consent (combat redesign: player-vs-player damage is gated unless both
    // sides are pvp_fight). pvp_attack flags the attacker locally and forwards pvpConsent
    // across the shard boundary to flag the defender.
    cmd(botA.ws, 'pvp_attack', { id: botB.pid });
    await sleep(800); // wait for cross-shard pvpConsent forwarding to flag the defender

    const bHpBefore = bState.selfHp;
    console.log(`[xshard] defender hp before=${bHpBefore}/${bState.mhp}`);

    // Force-target the ghost and start auto-attack (now consented → full damage).
    cmd(botA.ws, 'dev_target', { id: botB.pid });
    await sleep(10000); // several swings (~2.6s weapon speed), watch the round-trip

    const hits = aState.events.filter((ev) => ev.type === 'damage' && ev.targetId === botB.pid && ev.amount > 0);
    const anyAttackEvt = aState.events.filter((ev) => ev.type === 'damage' && ev.targetId === botB.pid);
    check('attacker received damage event for ghost target', anyAttackEvt.length > 0,
      anyAttackEvt.length > 0 ? `amount=[${anyAttackEvt.map((e) => e.amount).join(',')}]` : '');
    check('cross-shard hit landed (amount > 0)', hits.length > 0,
      hits.length > 0 ? `total=${hits.reduce((a, e) => a + e.amount, 0)}` : '');

    // Track the minimum hp seen (PvP has no DoT, so the defender out-of-combat regen
    // can restore the damage before the final read; the transient drop is what proves it).
    const bDamaged = bHpBefore != null && bState.minHp != null && bState.minHp < bHpBefore;
    check(`defender hp dropped (${bHpBefore} -> min ${bState.minHp})`, bDamaged, '');

    console.log(`\n[xshard] done in ${((Date.now() - t0) / 1000).toFixed(1)}s — ${failures === 0 ? 'RESULT: PASS' : 'RESULT: FAIL'}`);

    for (const s of [botA, botB]) logout(s.ws);
    for (const w of extra) logout(w);
    await sleep(800);
    await cleanup(pool, accountIds);
  } finally {
    await pool.end().catch(() => {});
  }
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
