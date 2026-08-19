// 500-idle-bot load test against the running Moon server.
// Seeds accounts/characters directly into Postgres (Moon schema), connects WS,
// holds idle, reports client-side snapshot rate/size/gaps. Server-side tick
// cost is read from the server's own [TickDiag] log during the window.
//
// Usage:
//   DATABASE_URL=... BOTS=500 HOLD_MS=30000 CLEANUP=1 node scripts/load_500.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const BOTS = Number(process.env.BOTS ?? 500);
const HOLD_MS = Number(process.env.HOLD_MS ?? 30000);
const CLEANUP = process.env.CLEANUP === '1';
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';

if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const L = 'abcdefghijklmnopqrstuvwxyz';
function letters(n) { let s = ''; let x = n + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; }

async function seedBots(pool) {
  const usernames = [], names = [], tokens = [];
  for (let i = 0; i < BOTS; i++) {
    usernames.push(`ld${RUN}${String(i).padStart(4, '0')}`);
    names.push(`L${RUN}${letters(i)}`.slice(0, 16));
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
    if (accts.rows.length !== BOTS) throw new Error(`account seed: ${accts.rows.length}/${BOTS} (name collision?)`);
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
    if (chars.rows.length !== BOTS) throw new Error(`char seed: ${chars.rows.length}/${BOTS} (name collision?)`);
    const charByAcct = new Map(chars.rows.map((r) => [r.account_id, r.id]));
    await client.query('COMMIT');
    return { accountIds, tokens, charIds: accountIds.map((a) => charByAcct.get(a)) };
  } catch (e) { await client.query('ROLLBACK').catch(() => {}); throw e; }
  finally { client.release(); }
}

async function cleanupBots(pool, accountIds) {
  for (let i = 0; i < accountIds.length; i += 100) {
    await pool.query('DELETE FROM accounts WHERE id = ANY($1::int[])', [accountIds.slice(i, i + 100)]);
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
      if (m.t === 'hello') { done = true; clearTimeout(to); resolve(ws); }
      else if (m.t === 'error') { done = true; clearTimeout(to); try { ws.close(); } catch {} reject(new Error(m.error ?? 'auth error')); }
    });
    ws.on('error', (e) => { if (!done) { done = true; clearTimeout(to); reject(e); } });
    ws.on('close', () => { if (!done) { done = true; clearTimeout(to); reject(new Error('closed before hello')); } });
  });
}

const SNAP_PREFIX = '{"t":"snap"';
const pct = (arr, p) => { if (!arr.length) return 0; const s = [...arr].sort((a, b) => a - b); return s[Math.floor((s.length - 1) * p)]; };

async function main() {
  const t0 = Date.now();
  console.log(`[load500] target=${BASE} bots=${BOTS} hold=${HOLD_MS}ms realm=${REALM} run=${RUN}`);
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 10 });

  let accountIds = [];
  try {
    const seedStart = Date.now();
    const seeded = await seedBots(pool);
    accountIds = seeded.accountIds;
    console.log(`[load500] seeded ${BOTS} accounts (${((Date.now() - seedStart) / 1000).toFixed(1)}s)`);

    const connStart = Date.now();
    let cursor = 0;
    const socks = [];
    await Promise.all(Array.from({ length: 10 }, async () => {
      while (cursor < BOTS) {
        const i = cursor++;
        try { socks.push(await connect(seeded.tokens[i], seeded.charIds[i])); } catch (e) { /* join failure */ }
      }
    }));
    console.log(`[load500] connected ${socks.length}/${BOTS} (${((Date.now() - connStart) / 1000).toFixed(1)}s)`);

    // sample observers
    const stride = Math.max(1, Math.floor(socks.length / 24));
    const observers = socks.filter((_, i) => i % stride === 0).slice(0, 24);
    const obs = observers.map(() => ({ times: [], sizes: [], count: 0 }));
    observers.forEach((ws, idx) => ws.on('message', (d) => {
      const s = d.toString();
      if (s.startsWith(SNAP_PREFIX)) { obs[idx].times.push(performance.now()); obs[idx].sizes.push(s.length); obs[idx].count++; }
    }));

    console.log(`[load500] holding ${HOLD_MS / 1000}s with ${socks.length} bots (read [TickDiag] in server log NOW)...`);
    await sleep(HOLD_MS);

    const snapCount = obs.reduce((a, o) => a + o.count, 0);
    const allSizes = obs.flatMap((o) => o.sizes);
    const gaps = [];
    for (const o of obs) for (let i = 1; i < o.times.length; i++) gaps.push(o.times[i] - o.times[i - 1]);
    const rateHz = obs.length ? snapCount / obs.length / (HOLD_MS / 1000) : 0;

    console.log('\n===== RESULT =====');
    console.log(`bots: connected=${socks.length}/${BOTS}`);
    console.log(`snapshot rate: ${rateHz.toFixed(2)} Hz/bot (${obs.length} observers)`);
    console.log(`snapshot size: p50=${pct(allSizes, 0.5)} p95=${pct(allSizes, 0.95)} max=${pct(allSizes, 1)} bytes`);
    console.log(`snapshot gap: p50=${pct(gaps, 0.5).toFixed(1)} p95=${pct(gaps, 0.95).toFixed(1)} max=${pct(gaps, 1).toFixed(1)} ms`);

    for (const ws of socks) { try { ws.close(); } catch {} }
    await sleep(1500);
    if (CLEANUP) { console.log('[load500] cleanup: deleting seeded accounts'); await cleanupBots(pool, accountIds); }
  } finally {
    await pool.end();
  }
  console.log(`[load500] done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  process.exit(0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
