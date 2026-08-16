// Cross-shard spell + ranged combat verification against the running Moon server.
//
// Extends the melee check: two bots on opposite sides of a region boundary, in
// different shards. Then:
//   1. Ranged: give the attacker a ranged weapon (dev_ranged), auto-attack the
//      cross-shard ghost, verify the defender's HP drops and the attacker gets a
//      standard `damage` event (combatForward{ranged} -> rangedSwingResult round-trip).
//   2. Spell:  the attacker casts fireball (projectile, 2s cast) at the ghost, verify
//      the defender's HP drops and the attacker gets a standard `damage` event
//      (castForward -> castResult round-trip).
//
// Requires: server running with ALLOW_DEV_COMMANDS=1 (or Dev forced ON) and
// WOC_WORLD_SHARDS > 1.
// Usage:
//   DATABASE_URL=... SHARDS=32 node scripts/test_cross_shard_spell_ranged.mjs
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
const GAP = 15; // yd separation between the two bots (ranged/spell need >5 dead zone, <35)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function check(name, cond, extra) {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

function regionToShard(rx, rz, n) {
  const a = BigInt(rx) * 2654435761n + BigInt(rz) * 40503n;
  const nB = BigInt(n);
  let m = a % nB;
  if (m < 0n) m += nB;
  return Number(m);
}

// Adjacent region pair (east neighbor) with distinct shards, away from spawn.
function findBoundaryPair(n) {
  for (let rz = 2; rz <= 6; rz++) {
    for (let rx = 2; rx <= 6; rx++) {
      const sA = regionToShard(rx, rz, n);
      const sB = regionToShard(rx + 1, rz, n);
      if (sA !== sB) {
        const bx = (rx + 1) * REGION_SIZE;
        const centerZ = rz * REGION_SIZE + REGION_SIZE / 2;
        return { rA: [rx, rz], rB: [rx + 1, rz], sA, sB, bx, centerZ };
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
  const state = { ents: new Map(), selfHp: null, mhp: null, minHp: null, events: [] };
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
  if (SHARDS <= 1) { console.error('SHARDS must be > 1'); process.exit(1); }
  console.log(`[xshard2] target=${BASE} shards=${SHARDS} run=${RUN}`);

  const pair = findBoundaryPair(SHARDS);
  if (!pair) { console.error(`[xshard2] no adjacent region pair with distinct shards for SHARDS=${SHARDS}`); process.exit(1); }
  console.log(`[xshard2] boundary: rA=(${pair.rA.join(',')}) shard=${pair.sA}  rB=(${pair.rB.join(',')}) shard=${pair.sB}`);
  // A in region rA, B in region rB, GAP yards apart across the boundary.
  const posA = { x: pair.bx - 10, z: pair.centerZ };
  const posB = { x: pair.bx + (GAP - 10), z: pair.centerZ };
  console.log(`[xshard2] posA=(${posA.x},${posA.z})  posB=(${posB.x},${posB.z}) gap=${GAP}`);

  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  const extra = [];
  try {
    const { bots, accountIds } = await seed(pool, SHARDS + 1, 0);
    console.log(`[xshard2] seeded ${bots.length} accounts (${((Date.now() - t0) / 1000).toFixed(1)}s)`);

    let botA = null, botB = null;
    for (const b of bots) {
      let conn;
      try { conn = await connect(b.token, b.charId); }
      catch (e) { console.log(`[xshard2] join failed char=${b.charId}: ${e.message}`); continue; }
      const shard = conn.pid % SHARDS;
      if (!botA && shard === pair.sA) botA = { ...conn, shard };
      else if (!botB && shard === pair.sB) botB = { ...conn, shard };
      else { extra.push(conn.ws); logout(conn.ws); }
      if (botA && botB) break;
    }

    check(`found attacker bot in shard ${pair.sA}`, !!botA, botA && `pid=${botA.pid}`);
    check(`found defender bot in shard ${pair.sB}`, !!botB, botB && `pid=${botB.pid}`);
    if (!botA || !botB) {
      cleanup(pool, accountIds);
      process.exit(1);
    }

    cmd(botA.ws, 'dev_level', { level: 20 });
    cmd(botB.ws, 'dev_level', { level: 20 });
    await sleep(500);

    const aState = attachObserver(botA, 'A');
    const bState = attachObserver(botB, 'B');

    // ---- Ranged test ----
    cmd(botA.ws, 'dev_teleport', { x: posA.x, z: posA.z });
    cmd(botB.ws, 'dev_teleport', { x: posB.x, z: posB.z });
    await sleep(6000); // let the spawn->region migration settle (5s cooldown) before dev_ranged/pvp_attack

    const rangedGhostSeen = aState.ents.has(botB.pid);
    check(`attacker sees defender as ghost (ranged)`, rangedGhostSeen, '');

    // Issue the ranged weapon AFTER migration: dev_ranged injects e.weapon in-session,
    // which migration rebuilds away from equipment. Must run in the settled shard.
    cmd(botA.ws, 'dev_ranged');

    // Establish PvP consent (player-vs-player damage is gated unless both sides are
    // pvp_fight). Covers both the ranged and spell phases below.
    cmd(botA.ws, 'pvp_attack', { id: botB.pid });
    await sleep(800); // wait for cross-shard pvpConsent forwarding to flag the defender

    const bHpRanged = bState.selfHp;
    cmd(botA.ws, 'dev_target', { id: botB.pid });
    await sleep(6000); // ~2 shots at 2.5s weapon speed

    const rangedHits = aState.events.filter((ev) => ev.type === 'damage' && ev.targetId === botB.pid && ev.amount > 0);
    // Ranged has no DoT, so the small damage can regen before the final read; track the
    // minimum hp seen during the phase instead of the final value.
    const rangedHpDrop = bHpRanged != null && bState.minHp != null && bState.minHp < bHpRanged;
    check('ranged damage event received for ghost', rangedHits.length > 0,
      rangedHits.length > 0 ? `amount=[${rangedHits.map((e) => e.amount).join(',')}]` : '');
    check(`ranged damage applied to defender (${bHpRanged} -> min ${bState.minHp})`, rangedHpDrop, '');

    // ---- Spell test (fireball: 2s cast + projectile) ----
    const bHpSpell = bState.selfHp;
    cmd(botA.ws, 'cast', { ability: 'fireball', target: botB.pid });
    await sleep(4000); // cast 2s + flight

    const spellDmgEvents = aState.events.filter((ev) => ev.type === 'damage' && ev.sourceId === botA.pid && ev.amount > 0);
    const spellHpDrop = bHpSpell != null && bState.selfHp != null && bState.selfHp < bHpSpell;
    check('spell damage event received for ghost', spellDmgEvents.length > 0,
      spellDmgEvents.length > 0 ? `amount=[${spellDmgEvents.map((e) => e.amount).join(',')}]` : '');
    check(`spell damage applied to defender (${bHpSpell} -> ${bState.selfHp})`, spellHpDrop, '');

    console.log(`\n[xshard2] done in ${((Date.now() - t0) / 1000).toFixed(1)}s — ${failures === 0 ? 'RESULT: PASS' : 'RESULT: FAIL'}`);

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
