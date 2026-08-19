// 5000-user load test against the running Moon server.
// Seeds accounts/characters directly into Postgres, connects WS in a bounded
// concurrency pool, then simulates player movement (input frames + random facing)
// to drive real snapshot broadcast + world tick + gate throughput.
//
// Usage:
//   DATABASE_URL=... BOTS=5000 CONCURRENCY=100 HOLD_MS=60000 CLEANUP=1 node scripts/load_5000.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const BOTS = Number(process.env.BOTS ?? 5000);
const CONCURRENCY = Number(process.env.CONCURRENCY ?? 80);
const HOLD_MS = Number(process.env.HOLD_MS ?? 60000);
const MOVE_RATIO = Number(process.env.MOVE_RATIO ?? 1.0);
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
    usernames.push(`l5${RUN}${String(i).padStart(4, '0')}`);
    names.push(`Q${RUN}${letters(i)}`.slice(0, 16));
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
  for (let i = 0; i < accountIds.length; i += 200) {
    await pool.query('DELETE FROM accounts WHERE id = ANY($1::int[])', [accountIds.slice(i, i + 200)]);
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

const SNAP_PREFIX = '{"t":"snap"';
const pct = (arr, p) => { if (!arr.length) return 0; const s = [...arr].sort((a, b) => a - b); return s[Math.floor((s.length - 1) * p)]; };

async function main() {
  const t0 = Date.now();
  console.log(`[load5000] target=${BASE} bots=${BOTS} conc=${CONCURRENCY} hold=${HOLD_MS}ms move=${MOVE_RATIO} realm=${REALM} run=${RUN}`);
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 12 });

  let accountIds = [];
  const socks = [];
  let joined = 0, failed = 0;
  try {
    const seedStart = Date.now();
    const seeded = await seedBots(pool);
    accountIds = seeded.accountIds;
    console.log(`[load5000] seeded ${BOTS} accounts (${((Date.now() - seedStart) / 1000).toFixed(1)}s)`);

    // bounded-concurrency connect (gate single-thread; measure join throughput)
    const connStart = Date.now();
    let cursor = 0;
    const joins = [];
    async function worker() {
      while (true) {
        const i = cursor++;
        if (i >= BOTS) return;
        const s0 = Date.now();
        try {
          const c = await connect(seeded.tokens[i], seeded.charIds[i]);
          joined++;
          joins.push(Date.now() - s0);
          socks.push(c.ws);
        } catch (e) { failed++; }
      }
    }
    await Promise.all(Array.from({ length: CONCURRENCY }, worker));
    const connSec = ((Date.now() - connStart) / 1000);
    console.log(`[load5000] joined=${joined} failed=${failed} (${connSec.toFixed(1)}s, ${(joined / Math.max(connSec, 0.001)).toFixed(1)} join/s, join p50=${pct(joins, 0.5).toFixed(0)}ms p95=${pct(joins, 0.95).toFixed(0)}ms)`);

    // sample observers (bounded, spread across the pool)
    const stride = Math.max(1, Math.floor(socks.length / 24));
    const observers = socks.filter((_, i) => i % stride === 0).slice(0, 24);
    const obs = observers.map(() => ({ times: [], sizes: [], count: 0 }));
    observers.forEach((ws, idx) => {
      ws.on('message', (d) => {
        const s = d.toString();
        if (s.startsWith(SNAP_PREFIX)) { obs[idx].times.push(performance.now()); obs[idx].sizes.push(s.length); obs[idx].count++; }
      });
    });

    // movement sim: a fraction of bots send input frames + random facing
    const movers = socks.filter((_, i) => i < Math.floor(socks.length * MOVE_RATIO));
    const moverTimer = setInterval(() => {
      if (movers.length === 0) return;
      // sample ~1/4 of movers each tick to avoid a burst every frame
      for (let k = 0; k < movers.length / 4; k++) {
        const ws = movers[(Math.random() * movers.length) | 0];
        if (ws.readyState === WebSocket.OPEN) {
          const facing = Math.random() * Math.PI * 2;
          const mi = Math.random() < 0.7 ? { f: 1 } : { sl: Math.random() < 0.5 ? 1 : 0.5 };
          try { ws.send(JSON.stringify({ t: 'input', mi, facing })); } catch {}
        }
      }
    }, 100);
    // also some bots send stop inputs so positions actually jitter
    const stopTimer = setInterval(() => {
      if (movers.length === 0) return;
      const ws = movers[(Math.random() * movers.length) | 0];
      if (ws.readyState === WebSocket.OPEN) { try { ws.send(JSON.stringify({ t: 'input', mi: {} })); } catch {} }
    }, 300);

    console.log(`[load5000] holding ${HOLD_MS / 1000}s with ${joined} bots, ${movers.length} moving (read server console / task manager NOW)...`);
    const snapSampleStart = Date.now();
    const holdStart = Date.now();
    // progress: print cumulative snapshot count every 5s (observers share obs array)
    const progressTimer = setInterval(() => {
      const c = obs.reduce((a, o) => a + o.count, 0);
      const aliveNow = socks.filter((ws) => ws.readyState === WebSocket.OPEN).length;
      console.log(`  [probe] t+${((Date.now() - holdStart) / 1000).toFixed(0)}s snapMsgs=${c} open=${aliveNow}`);
    }, 5000);
    await sleep(HOLD_MS);
    clearInterval(progressTimer);

    clearInterval(moverTimer); clearInterval(stopTimer);
    const snapWindow = (Date.now() - snapSampleStart) / 1000;
    const snapCount = obs.reduce((a, o) => a + o.count, 0);
    const allSizes = obs.flatMap((o) => o.sizes);
    const gaps = [];
    for (const o of obs) for (let i = 1; i < o.times.length; i++) gaps.push(o.times[i] - o.times[i - 1]);
    const rateHz = obs.length ? snapCount / obs.length / snapWindow : 0;

    // live connection count at the end (linkdead/evict measure server capacity)
    let alive = 0;
    for (const ws of socks) { if (ws.readyState === WebSocket.OPEN) alive++; }

    console.log('\n===== RESULT =====');
    console.log(`bots: joined=${joined} failed=${failed} still-open=${alive}/${socks.length}`);
    console.log(`snapshot rate: ${rateHz.toFixed(2)} Hz/bot (${obs.length} observers, ${snapWindow.toFixed(0)}s window)`);
    console.log(`snapshot size: p50=${pct(allSizes, 0.5)} p95=${pct(allSizes, 0.95)} max=${pct(allSizes, 1)} bytes`);
    console.log(`snapshot gap: p50=${pct(gaps, 0.5).toFixed(1)} p95=${pct(gaps, 0.95).toFixed(1)} max=${pct(gaps, 1).toFixed(1)} ms`);
    const estDown = joined * rateHz;
    console.log(`est. total snapshots/s: ${estDown.toFixed(0)} (joined x Hz)`);

    for (const ws of socks) { try { ws.close(); } catch {} }
    await sleep(2000);
    if (CLEANUP) { console.log('[load5000] cleanup: deleting seeded accounts'); await cleanupBots(pool, accountIds); }
  } finally {
    await pool.end();
    for (const ws of socks) { try { ws.terminate(); } catch {} }
  }
  console.log(`[load5000] done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  process.exit(0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
