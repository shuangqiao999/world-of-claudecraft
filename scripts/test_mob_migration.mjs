// Cross-shard mob migration verification.
//
// Scenario: a player (bot) attacks a hostile wolf spawned near a region boundary,
// then crosses the boundary; the wolf chases and its region maps to the neighbour
// shard, so it migrates (Phase 3). Verified by grepping the server log for the
// [Mob] Migrate out/in lines carrying the wolf's id.
//
// Requires: server running with ALLOW_DEV_COMMANDS=1 and WOC_WORLD_SHARDS > 1.
// Usage:
//   DATABASE_URL=... SHARDS=32 WOC_LOG="D:\...\woc-server.log" node scripts/test_mob_migration.mjs
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const SHARDS = Number(process.env.SHARDS ?? 32);
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const LOG = process.env.WOC_LOG ?? 'D:\\Program Files\\World of ClaudeCraft Server (Moon)\\moon-server\\woc\\log\\woc-server.log';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';
const REGION_SIZE = 270;
const BOUNDARY_GAP = 8; // yd the player starts inside rA; wolf spawns +3, so ~5yd inside

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

// Find a region rA whose shard equals the player's shard P, with an east neighbour
// rB mapping to a different shard. Returns { rA, rB, sA, sB, bx, centerZ }.
function findRegionForShard(P, n) {
  for (let rz = 1; rz <= 6; rz++) {
    for (let rx = 1; rx <= 6; rx++) {
      if (regionToShard(rx, rz, n) !== P) continue;
      const sE = regionToShard(rx + 1, rz, n);
      if (sE !== P) {
        return { rA: [rx, rz], rB: [rx + 1, rz], sA: P, sB: sE,
          bx: (rx + 1) * REGION_SIZE, centerZ: rz * REGION_SIZE + REGION_SIZE / 2 };
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
    usernames.push(`xm${RUN}${String(k).padStart(5, '0')}`);
    names.push(`M${RUN}${letters(k)}`.slice(0, 16));
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
    if (accts.rows.length !== count) throw new Error(`seed ${accts.rows.length}/${count}`);
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
    if (chars.rows.length !== count) throw new Error(`chars ${chars.rows.length}/${count}`);
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

function readLog() { try { return readFileSync(LOG, 'utf8'); } catch { return ''; } }

async function main() {
  const t0 = Date.now();
  if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }
  if (SHARDS <= 1) { console.error('SHARDS must be > 1'); process.exit(1); }
  console.log(`[migrate] target=${BASE} shards=${SHARDS} run=${RUN}`);

  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 3 });
  let accountIds = [];
  let sock = null;
  try {
    const { bots, accountIds: ids } = await seed(pool, 3, 0);
    accountIds = ids;
    console.log(`[migrate] seeded ${bots.length} accounts (${((Date.now() - t0) / 1000).toFixed(1)}s)`);

    // Connect a bot, compute its shard P, find a boundary whose near side maps to P.
    let bot = null, pair = null;
    for (const b of bots) {
      let conn;
      try { conn = await connect(b.token, b.charId); } catch (e) { console.log(`[migrate] join failed: ${e.message}`); continue; }
      const P = conn.pid % SHARDS;
      pair = findRegionForShard(P, SHARDS);
      if (pair) { bot = conn; break; }
      logout(conn.ws);
    }
    check('found bot with a cross-shard boundary', !!bot && !!pair,
      bot && pair && `shard=${pair.sA} rA=(${pair.rA.join(',')}) -> rB=(${pair.rB.join(',')}) shard=${pair.sB}`);
    if (!bot || !pair) { cleanup(pool, accountIds); process.exit(1); }
    sock = bot;

    const posA = { x: pair.bx - BOUNDARY_GAP, z: pair.centerZ };
    const posB = { x: pair.bx + BOUNDARY_GAP, z: pair.centerZ };
    console.log(`[migrate] posA=(${posA.x},${posA.z})  posB=(${posB.x},${posB.z}) boundary=${pair.bx}`);

    // wolf id is captured from the dev_give log event
    let wolfId = null;
    bot.ws.on('message', (d) => {
      let m; try { m = JSON.parse(d.toString()); } catch { return; }
      if (m.t === 'events') {
        const arr = Array.isArray(m.list) ? m.list : (m.list ? [m.list] : []);
        for (const ev of arr) {
          if (ev.type === 'log') {
            const mm = /Spawned mob id=(\d+)/.exec(ev.text || '');
            if (mm) wolfId = Number(mm[1]);
          }
        }
      }
    });

    // keep player low level so the wolf is not "trivial" (grey) and will aggro back
    cmd(bot.ws, 'dev_level', { level: 5 });
    await sleep(400);
    cmd(bot.ws, 'dev_teleport', { x: posA.x, z: posA.z });
    await sleep(400);
    cmd(bot.ws, 'dev_give');           // spawn forest_wolf ~3yd from player
    await sleep(400);
    check('spawned wolf via dev_give', wolfId !== null, wolfId !== null ? `wolfId=${wolfId}` : '');
    if (wolfId === null) { cleanup(pool, accountIds); process.exit(1); }

    // attack the wolf to generate threat (dev_target now swings immediately), then lead it across
    cmd(bot.ws, 'dev_target', { id: wolfId });
    await sleep(800);                   // immediate swing lands + wolf aggros
    cmd(bot.ws, 'dev_teleport', { x: posB.x, z: posB.z });  // cross boundary
    await sleep(5000);                  // wolf chases ~13yd at 8yd/s and migrates

    const log = readLog();
    const outLine = log.includes(`Migrate out: id=${wolfId}`);
    const inLine = log.includes(`Migrate in: id=${wolfId}`);
    check(`[Mob] Migrate out logged (wolf ${wolfId})`, outLine, '');
    check(`[Mob] Migrate in logged (wolf ${wolfId})`, inLine, '');

    console.log(`\n[migrate] done in ${((Date.now() - t0) / 1000).toFixed(1)}s — ${failures === 0 ? 'RESULT: PASS' : 'RESULT: FAIL'}`);

    logout(bot.ws);
    await sleep(800);
    await cleanup(pool, accountIds);
  } finally {
    if (sock) logout(sock.ws);
    await pool.end().catch(() => {});
  }
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
