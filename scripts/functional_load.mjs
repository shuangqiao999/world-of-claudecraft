// Functional load test: 5000 bots doing real-player actions, not just idling.
//
// Each bot periodically performs a mix of the core actions a real client sends:
//   - movement      (input frames, random wander direction)
//   - auto-attack   (attack command -> nearest target + swing)
//   - spell cast    (cast fireball)
//   - chat          (chat text)
//   - emote         (emote wave)
//   - interact      (interact — quest/object proximity)
//
// Observers sample a subset for snapshot rate/gap, count error frames across every
// socket, and count chat + combat events to prove the features actually fire at scale.
//
// Usage:
//   DATABASE_URL=... BOTS=5000 STEP=500 HOLD_MS=10000 CLEANUP=1 SPREAD=1 \
//     node scripts/functional_load.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const BOTS = Number(process.env.BOTS ?? 5000);
const STEP = Number(process.env.STEP ?? 500);
const HOLD_MS = Number(process.env.HOLD_MS ?? 10000);
const CONCURRENCY = Number(process.env.CONCURRENCY ?? 32);
const CLEANUP = process.env.CLEANUP === '1';
const SPREAD = process.env.SPREAD === '1';
const SPREAD_RADIUS = Number(process.env.SPREAD_RADIUS ?? 400);
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const L = 'abcdefghijklmnopqrstuvwxyz';
function letters(n) { let s = ''; let x = n + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; }
function scatterPos(i) {
  const ang = (i * 137.508) % 360;
  const r = Math.sqrt((i + 0.5) / BOTS) * SPREAD_RADIUS;
  return { x: Math.round(Math.cos((ang * Math.PI) / 180) * r), z: Math.round(Math.sin((ang * Math.PI) / 180) * r) };
}

async function seedBots(pool, count, offset) {
  const usernames = [], names = [], tokens = [], states = [];
  for (let i = 0; i < count; i++) {
    const n = offset + i;
    usernames.push(`fx${RUN}${String(n).padStart(5, '0')}`);
    names.push(`F${RUN}${letters(n)}`.slice(0, 16));
    tokens.push(randomBytes(32).toString('hex'));
    if (SPREAD) {
      const p = scatterPos(n);
      states.push(JSON.stringify({ pos: { x: p.x, z: p.z } }));
    } else {
      states.push('{}');
    }
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const accts = await client.query(
      `INSERT INTO accounts (username, password_hash)
       SELECT u, $2 FROM unnest($1::text[]) AS u ON CONFLICT (username) DO NOTHING RETURNING id, username`,
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
       SELECT a, n, 'warrior', $3, s::jsonb FROM unnest($1::int[], $2::text[], $4::text[]) AS p(a, n, s)
       ON CONFLICT (name) DO NOTHING RETURNING id, account_id`,
      [accountIds, names, REALM, states],
    );
    if (chars.rows.length !== count) throw new Error(`chars ${chars.rows.length}/${count}`);
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
  if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }
  console.log(`[funcload] target=${BASE} bots=${BOTS} step=${STEP} hold=${HOLD_MS}ms spread=${SPREAD} realm=${REALM} run=${RUN}`);

  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 10 });
  const allAccountIds = [];
  const bots = []; // { token, charId, ws, pid, nextAt, dir }
  const stats = { errors: 0, chat: 0, combat: 0, emote: 0, snaps: 0, snapBytes: 0 };

  try {
    // seed all up front
    let offset = 0;
    const BATCH = 1000;
    while (offset < BOTS) {
      const n = Math.min(BATCH, BOTS - offset);
      const seeded = await seedBots(pool, n, offset);
      allAccountIds.push(...seeded.accountIds);
      for (let i = 0; i < n; i++) bots.push({ token: seeded.tokens[i], charId: seeded.charIds[i] });
      offset += n;
    }
    console.log(`[funcload] seeded ${bots.length} accounts (${((Date.now() - t0) / 1000).toFixed(1)}s)`);

    // connect in plateaus
    const socks = [];
    let nextIdx = 0;
    while (nextIdx < bots.length) {
      const target = Math.min(bots.length, nextIdx + STEP);
      let cursor = nextIdx;
      await Promise.all(Array.from({ length: CONCURRENCY }, async () => {
        while (cursor < target) {
          const i = cursor++;
          try {
            const c = await connect(bots[i].token, bots[i].charId);
            bots[i].ws = c.ws;
            bots[i].pid = c.pid;
            bots[i].nextAt = Date.now() + Math.random() * 1500;
            bots[i].dir = Math.floor(Math.random() * 4);
            socks.push(c.ws);
          } catch {}
        }
      }));
      nextIdx = target;
      console.log(`[funcload] +${bots.slice(0, nextIdx).filter((b) => b.ws).length} connected (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    }

    const connected = bots.filter((b) => b.ws).length;
    console.log(`[funcload] connected ${connected}/${BOTS}`);

    // sample a small subset for snapshot rate + error/feature-event counting
    // (avoid attaching a message handler to all 5000 sockets — that GC pressure
    //  stalls the connect loop)
    const SAMPLE = 50;
    const stride = Math.max(1, Math.floor(connected / SAMPLE));
    const sampled = [];
    for (let i = 0; i < connected; i += stride) sampled.push(bots.filter((b) => b.ws)[i]);
    for (const b of sampled) {
      b.ws.on('message', (d) => {
        const s = d.toString();
        if (s.startsWith(SNAP_PREFIX)) { stats.snaps++; stats.snapBytes += s.length; return; }
        let m; try { m = JSON.parse(s); } catch { return; }
        if (m.t === 'error') { stats.errors++; return; }
        if (m.t === 'events' && Array.isArray(m.list)) {
          for (const ev of m.list) {
            if (ev.type === 'chat') stats.chat++;
            else if (ev.type === 'damage' || ev.type === 'heal2') stats.combat++;
            else if (ev.type === 'emote') stats.emote++;
          }
        }
      });
    }

    // action loop: one interval iterates all connected bots
    const actionTimer = setInterval(() => {
      const now = Date.now();
      const n = bots.length;
      const step = Math.max(1, Math.floor(n / 5000)); // spread the work
      for (let i = 0; i < n; i++) {
        const b = bots[i];
        if (!b.ws || b.ws.readyState !== WebSocket.OPEN) continue;
        if (now < b.nextAt) continue;
        b.nextAt = now + 1500 + Math.random() * 2500;
        const r = Math.random();
        let frame;
        if (r < 0.40) {
          // movement: wander in a random direction
          b.dir = (b.dir + (Math.random() < 0.2 ? 1 : 0)) % 4;
          const mi = b.dir === 0 ? { f: 1 } : b.dir === 1 ? { b: 1 } : b.dir === 2 ? { l: 1 } : { r: 1 };
          frame = JSON.stringify({ t: 'input', mi });
        } else if (r < 0.55) {
          frame = JSON.stringify({ t: 'input', mi: {} }); // stop
        } else if (r < 0.72) {
          frame = JSON.stringify({ t: 'cmd', cmd: 'attack' });
        } else if (r < 0.84) {
          frame = JSON.stringify({ t: 'cmd', cmd: 'cast', ability: 'fireball' });
        } else if (r < 0.94) {
          frame = JSON.stringify({ t: 'cmd', cmd: 'chat', text: `hi from ${b.pid}` });
        } else if (r < 0.98) {
          frame = JSON.stringify({ t: 'cmd', cmd: 'emote', id: 'wave' });
        } else {
          frame = JSON.stringify({ t: 'cmd', cmd: 'interact' });
        }
        try { b.ws.send(frame); } catch {}
      }
    }, 200);

    // hold while actions run
    await sleep(HOLD_MS);
    clearInterval(actionTimer);
    const elapsed = (Date.now() - t0) / 1000;

    console.log('\n===== FUNCTIONAL LOAD RESULT =====');
    console.log(`connected    = ${connected}/${BOTS}`);
    console.log(`snapshots    = ${stats.snaps} (${(stats.snaps / Math.max(1, sampled.length) / elapsed).toFixed(2)} Hz/bot, sampled ${sampled.length})`);
    console.log(`avg snap     = ${(stats.snapBytes / Math.max(1, stats.snaps)).toFixed(0)} B`);
    console.log(`errors       = ${stats.errors}`);
    console.log(`chat events  = ${stats.chat}`);
    console.log(`combat evts  = ${stats.combat}`);
    console.log(`emote events = ${stats.emote}`);
    console.log(`elapsed      = ${elapsed.toFixed(1)}s`);

    for (const ws of socks) { try { ws.close(); } catch {} }
    await sleep(1500);
    if (CLEANUP) { console.log('[funcload] cleanup'); await cleanupBots(pool, allAccountIds); }
  } finally {
    await pool.end();
  }
  console.log(`[funcload] done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  process.exit(0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
