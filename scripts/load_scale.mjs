// Ramp-up load test against the running Moon server.
// Seeds accounts/characters directly into Postgres (Moon schema), then connects
// WS bots in escalating batches, holding each plateau so the server's tick cost
// and per-bot snapshot rate can be observed at every player count. Reports
// client-side snapshot rate/size/gaps plus connected count per plateau.
//
// Usage:
//   DATABASE_URL=... node scripts/load_scale.mjs
//
// Env knobs:
//   BOTS=5000       total target bots
//   STEP=250        bots added per plateau
//   HOLD_MS=20000   ms to hold each plateau (sample window)
//   CONCURRENCY=32  parallel joins within a plateau
//   CLEANUP=1       delete seeded accounts on exit
//   SPREAD=1        scatter bots across the zone (dev_teleport, needs ALLOW_DEV_COMMANDS=1)
//   SPREAD_RADIUS=400  golden-angle disc radius in yards
//   SERVER_URL=http://localhost:8787
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const BOTS = Number(process.env.BOTS ?? 5000);
const STEP = Number(process.env.STEP ?? 250);
const HOLD_MS = Number(process.env.HOLD_MS ?? 20000);
const CONCURRENCY = Number(process.env.CONCURRENCY ?? 32);
const CLEANUP = process.env.CLEANUP === '1';
const SPREAD = process.env.SPREAD === '1';
const SPREAD_RADIUS = Number(process.env.SPREAD_RADIUS ?? 400);
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';

if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const L = 'abcdefghijklmnopqrstuvwxyz';
function letters(n) { let s = ''; let x = n + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; }

async function seedBots(pool, count, offset) {
  const usernames = [], names = [], tokens = [];
  for (let i = 0; i < count; i++) {
    const n = offset + i;
    usernames.push(`ld${RUN}${String(n).padStart(5, '0')}`);
    names.push(`L${RUN}${letters(n)}`.slice(0, 16));
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
    return { accountIds, tokens, charIds: accountIds.map((a) => charByAcct.get(a)) };
  } catch (e) { await client.query('ROLLBACK').catch(() => {}); throw e; }
  finally { client.release(); }
}

async function cleanupBots(pool, accountIds) {
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
      if (m.t === 'hello') { done = true; clearTimeout(to); resolve(ws); }
      else if (m.t === 'error') { done = true; clearTimeout(to); try { ws.close(); } catch {} reject(new Error(m.error ?? 'auth error')); }
    });
    ws.on('error', (e) => { if (!done) { done = true; clearTimeout(to); reject(e); } });
    ws.on('close', () => { if (!done) { done = true; clearTimeout(to); reject(new Error('closed before hello')); } });
  });
}

const SNAP_PREFIX = '{"t":"snap"';
const pct = (arr, p) => { if (!arr.length) return 0; const s = [...arr].sort((a, b) => a - b); return s[Math.floor((s.length - 1) * p)]; };

function attachObservers(socks, n) {
  const stride = Math.max(1, Math.floor(socks.length / n));
  const obs = socks.filter((_, i) => i % stride === 0).slice(0, n).map(() => ({ times: [], sizes: [], count: 0 }));
  obs.forEach((_, idx) => {
    const ws = socks[idx * stride];
    ws.on('message', (d) => {
      const s = d.toString();
      if (s.startsWith(SNAP_PREFIX)) { obs[idx].times.push(performance.now()); obs[idx].sizes.push(s.length); obs[idx].count++; }
    });
  });
  return obs;
}

async function main() {
  const t0 = Date.now();
  console.log(`[loadscale] target=${BASE} bots=${BOTS} step=${STEP} hold=${HOLD_MS}ms realm=${REALM} run=${RUN}`);
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 10 });

  const allAccountIds = [];
  const bots = []; // { token, charId }
  try {
    // seed all bots up front (parallel batches)
    const seedStart = Date.now();
    let offset = 0;
    const BATCH = 1000;
    while (offset < BOTS) {
      const n = Math.min(BATCH, BOTS - offset);
      const seeded = await seedBots(pool, n, offset);
      allAccountIds.push(...seeded.accountIds);
      for (let i = 0; i < n; i++) bots.push({ token: seeded.tokens[i], charId: seeded.charIds[i] });
      offset += n;
    }
    console.log(`[loadscale] seeded ${bots.length} accounts (${((Date.now() - seedStart) / 1000).toFixed(1)}s)`);

    const socks = [];
    let nextIdx = 0;
    console.log(`\n${'plateau'.padEnd(9)} ${'total'.padEnd(8)} ${'snapRate'.padEnd(12)} ${'snapP50'.padEnd(9)} ${'gapP50'.padEnd(9)} ${'t+sec'.padEnd(8)}`);
    while (nextIdx < bots.length) {
      const target = Math.min(bots.length, nextIdx + STEP);
      const connStart = Date.now();
      let cursor = nextIdx;
      const added = [];
      const scatterPos = (i) => {
        const ang = (i * 137.508) % 360;
        const r = Math.sqrt((i + 0.5) / BOTS) * SPREAD_RADIUS;
        return {
          x: Math.round(Math.cos((ang * Math.PI) / 180) * r),
          z: Math.round(Math.sin((ang * Math.PI) / 180) * r),
        };
      };
      await Promise.all(Array.from({ length: CONCURRENCY }, async () => {
        while (cursor < target) {
          const i = cursor++;
          try {
            const ws = await connect(bots[i].token, bots[i].charId);
            if (SPREAD) {
              const p = scatterPos(i);
              ws.send(JSON.stringify({ cmd: 'dev_teleport', x: p.x, z: p.z }));
            }
            added.push(ws);
          } catch {}
        }
      }));
      socks.push(...added);
      nextIdx = target;
      console.log(`[loadscale] +${added.length} connected (total ${socks.length}/${BOTS}, ${((Date.now() - connStart) / 1000).toFixed(1)}s)`);

      const obs = attachObservers(socks, 24);
      await sleep(HOLD_MS);

      const snapCount = obs.reduce((a, o) => a + o.count, 0);
      const allSizes = obs.flatMap((o) => o.sizes);
      const gaps = [];
      for (const o of obs) for (let i = 1; i < o.times.length; i++) gaps.push(o.times[i] - o.times[i - 1]);
      const rateHz = obs.length ? snapCount / obs.length / (HOLD_MS / 1000) : 0;
      console.log(`[RESULT ] total=${socks.length} rate=${rateHz.toFixed(2)}Hz/bot sizeP50=${pct(allSizes, 0.5)}B gapP50=${pct(gaps, 0.5).toFixed(0)}ms  (t+${((Date.now() - t0) / 1000).toFixed(0)}s)`);
      // clear observers' listeners so the next plateau attaches fresh
      for (const ws of socks) ws.removeAllListeners('message');
    }

    console.log('\n===== FINAL =====');
    console.log(`connected=${socks.length}/${BOTS} total_elapsed=${((Date.now() - t0) / 1000).toFixed(1)}s`);

    for (const ws of socks) { try { ws.close(); } catch {} }
    await sleep(1500);
    if (CLEANUP) { console.log('[loadscale] cleanup: deleting seeded accounts'); await cleanupBots(pool, allAccountIds); }
  } finally {
    await pool.end();
  }
  console.log(`[loadscale] done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  process.exit(0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
