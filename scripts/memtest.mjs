// Memory-leak test for the Moon server.
//
// Seeds accounts/characters directly into Postgres (Moon schema), connects WS bots,
// and watches the moon.exe RSS over three phases (idle → loaded → disconnected) so a
// leak shows up as either (a) RSS growing during the hold, or (b) RSS not dropping
// after disconnect. If PHASEDIAG_LOG points at the server's stdout redirect, it also
// reports the server's own PhaseDiag line (Lua heap `mem=` + table sizes ent/ply/
// snap/threat/ai/grid), which separates Lua-table leaks from C-side (buffer/socket)
// growth: a flat `mem=` with rising RSS means the growth is C-side, not Lua tables.
//
// Usage:
//   DATABASE_URL=... node scripts/memtest.mjs
//   PHASEDIAG_LOG=D:\...\server.stdout.log DATABASE_URL=... node scripts/memtest.mjs
//
// Env knobs:
//   BOTS=500            bots to connect (keep below the ~1500 healthy ceiling)
//   HOLD_MS=30000       ms to hold each phase (idle / loaded / disconnected)
//   SAMPLE_MS=5000      RSS sample interval
//   CLEANUP=1           delete seeded accounts on exit
//   PROC_NAME=moon      process name to watch RSS (Windows)
//   SERVER_URL=http://localhost:8787
import { randomBytes } from 'node:crypto';
import { execSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const BOTS = Number(process.env.BOTS ?? 500);
const HOLD_MS = Number(process.env.HOLD_MS ?? 30000);
const SAMPLE_MS = Number(process.env.SAMPLE_MS ?? 5000);
const CLEANUP = process.env.CLEANUP === '1';
const PROC_NAME = process.env.PROC_NAME ?? 'moon';
const PHASEDIAG_LOG = process.env.PHASEDIAG_LOG ?? '';
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';

if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const L = 'abcdefghijklmnopqrstuvwxyz';
function letters(n) { let s = ''; let x = n + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; }

// ---- RSS of the moon process (Windows) ---------------------------------------
function rssMb(procName) {
  try {
    const out = execSync(`wmic process where "name='${procName}.exe'" get WorkingSetSize`, { encoding: 'utf8', timeout: 5000 });
    let total = 0;
    for (const line of out.split('\n')) {
      const m = line.trim().match(/^(\d+)$/);
      if (m) total += Number(m[1]);
    }
    return total ? Math.round(total / 1024 / 1024) : -1;
  } catch { return -1; }
}

// ---- last PhaseDiag line from the server stdout redirect ----------------------
function lastPhaseDiag(path) {
  if (!path || !existsSync(path)) return null;
  try {
    const data = readFileSync(path, 'utf8');
    const lines = data.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      if (lines[i].includes('[PhaseDiag]')) return lines[i].trim();
    }
  } catch {}
  return null;
}

// ---- DB seeding + WS connect (same schema as load_scale.mjs) ------------------
async function seedBots(pool, count, offset) {
  const usernames = [], names = [], tokens = [];
  for (let i = 0; i < count; i++) {
    const n = offset + i;
    usernames.push(`mt${RUN}${String(n).padStart(5, '0')}`);
    names.push(`M${RUN}${letters(n)}`.slice(0, 16));
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

// ---- sample loop --------------------------------------------------------------
async function samplePhase(label, ms) {
  const end = Date.now() + ms;
  const rows = [];
  while (Date.now() < end) {
    const rss = rssMb(PROC_NAME);
    const pd = lastPhaseDiag(PHASEDIAG_LOG);
    rows.push({ rss, pd });
    console.log(`[${label}] t+${((Date.now() - t0) / 1000).toFixed(0)}s rss=${rss >= 0 ? rss + 'MB' : 'n/a'} ${pd ?? ''}`);
    await sleep(SAMPLE_MS);
  }
  return rows;
}

let t0;

async function main() {
  t0 = Date.now();
  console.log(`[memtest] target=${BASE} bots=${BOTS} hold=${HOLD_MS}ms proc=${PROC_NAME} log=${PHASEDIAG_LOG || '(none)'}`);
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 10 });

  const allAccountIds = [];
  const bots = [];
  const socks = [];
  try {
    // seed
    const seedStart = Date.now();
    let offset = 0;
    while (offset < BOTS) {
      const n = Math.min(1000, BOTS - offset);
      const seeded = await seedBots(pool, n, offset);
      allAccountIds.push(...seeded.accountIds);
      for (let i = 0; i < n; i++) bots.push({ token: seeded.tokens[i], charId: seeded.charIds[i] });
      offset += n;
    }
    console.log(`[memtest] seeded ${bots.length} accounts (${((Date.now() - seedStart) / 1000).toFixed(1)}s)`);

    // phase 1: idle baseline
    await samplePhase('idle', HOLD_MS);

    // phase 2: connect + hold
    const connStart = Date.now();
    let cursor = 0;
    const worker = async () => {
      for (;;) {
        if (cursor >= bots.length) return;
        const i = cursor;
        cursor += 1;
        try { socks.push(await connect(bots[i].token, bots[i].charId)); } catch {}
      }
    };
    await Promise.all(Array.from({ length: 32 }, worker));
    console.log(`[memtest] connected ${socks.length}/${BOTS} (${((Date.now() - connStart) / 1000).toFixed(1)}s)`);
    await samplePhase('loaded', HOLD_MS);

    // phase 3: disconnect + observe
    for (const ws of socks) { try { ws.close(); } catch {} }
    console.log(`[memtest] disconnected ${socks.length} bots`);
    await samplePhase('post', HOLD_MS);

    console.log('\n===== DONE =====');
    console.log('If RSS rose during "loaded" and did NOT drop during "post", the server leaks.');
    console.log('If PhaseDiag `mem=` stayed flat while RSS rose, the growth is C-side (buffers/sockets), not Lua tables.');
  } finally {
    if (CLEANUP) { console.log('[memtest] cleanup: deleting seeded accounts'); await cleanupBots(pool, allAccountIds); }
    await pool.end();
  }
  process.exit(0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
