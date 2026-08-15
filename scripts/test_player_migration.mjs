// Cross-shard player session migration verification (Phase 5).
//
// Scenario: a bot joins at spawn (region 0,0 -> shard 0), then dev_teleports into a
// region owned by a different shard. The world should migrate the player's session to
// that shard (serialize + rebuild + notify the gate), verified by grepping the server
// log for [World] Player migrate out/in lines carrying the player's pid.
//
// Requires: server running with ALLOW_DEV_COMMANDS=1 and WOC_WORLD_SHARDS > 1.
// Usage:
//   DATABASE_URL=... SHARDS=32 WOC_LOG="D:\...\woc-server.log" node scripts/test_player_migration.mjs
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

// Find a region whose shard != 0 (spawn shard), so teleporting there triggers a migration.
function findNonZeroRegion(n) {
  for (let rz = 0; rz <= 6; rz++) {
    for (let rx = 0; rx <= 6; rx++) {
      if (regionToShard(rx, rz, n) !== 0 && (rx !== 0 || rz !== 0)) return { rx, rz };
    }
  }
  return null;
}

async function seed(pool, count) {
  const usernames = [], names = [], tokens = [];
  const L = 'abcdefghijklmnopqrstuvwxyz';
  const letters = (k) => { let s = ''; let x = k + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; };
  for (let i = 0; i < count; i++) {
    usernames.push(`xp${RUN}${String(i).padStart(5, '0')}`);
    names.push(`P${RUN}${letters(i)}`.slice(0, 16));
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
  console.log(`[pmigrate] target=${BASE} shards=${SHARDS} run=${RUN}`);

  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 3 });
  let accountIds = [];
  let sock = null;
  try {
    const { bots, accountIds: ids } = await seed(pool, 1);
    accountIds = ids;
    const conn = await connect(bots[0].token, bots[0].charId);
    sock = conn.ws;
    const pid = conn.pid;
    console.log(`[pmigrate] connected pid=${pid}`);

    // let any initial spawn->shard0 migration settle (spawn region (0,0) maps to shard 0)
    await sleep(2000);

    const region = findNonZeroRegion(SHARDS);
    check('found a non-spawn region', !!region, region && `region=(${region.rx},${region.rz}) shard=${regionToShard(region.rx, region.rz, SHARDS)}`);
    if (!region) { cleanup(pool, accountIds); process.exit(1); }
    const targetShard = regionToShard(region.rx, region.rz, SHARDS);
    const px = region.rx * REGION_SIZE + REGION_SIZE / 2;
    const pz = region.rz * REGION_SIZE + REGION_SIZE / 2;
    console.log(`[pmigrate] teleport to (${px},${pz}) -> shard ${targetShard}`);

    cmd(sock, 'dev_teleport', { x: px, z: pz });
    await sleep(4000);

    const log = readLog();
    const outLine = log.includes(`Player migrate out: pid=${pid}`);
    const inLine = log.includes(`Player migrate in: pid=${pid}`);
    check(`[World] Player migrate out logged (pid ${pid})`, outLine, '');
    check(`[World] Player migrate in logged (pid ${pid})`, inLine, '');

    console.log(`\n[pmigrate] done in ${((Date.now() - t0) / 1000).toFixed(1)}s — ${failures === 0 ? 'RESULT: PASS' : 'RESULT: FAIL'}`);

    logout(sock);
    await sleep(800);
    await cleanup(pool, accountIds);
  } finally {
    if (sock) logout(sock);
    await pool.end().catch(() => {});
  }
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
