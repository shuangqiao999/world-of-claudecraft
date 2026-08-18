// Big-battle sustained load test against the running Moon server.
// Progressive ramp-up to BOTS players (spread round-robin across world shards
// by pid % shards), then continuous movement + combat activity and metrics
// sampling for DURATION_MS.
//
// Usage:
//   DATABASE_URL=... BOTS=2000 RAMP_STEP=250 RAMP_INTERVAL_MS=20000 \
//   DURATION_MS=7200000 OBSERVERS=24 node scripts/big_battle_load.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
// WS 端点: WS_PORTS 直连 gate (绕过 Node 代理, P1), 否则走代理 BASE/ws
const WS_BASE = BASE.replace(/^http/, 'ws') + '/';
const WS_PORTS = (process.env.WS_PORTS ?? '')
  .split(',')
  .map((s) => Number(s.trim()))
  .filter((n) => Number.isFinite(n) && n > 0);
let wsIdx = 0;
function wsUrlFor() {
  if (WS_PORTS.length) {
    const host = new URL(BASE).hostname;
    return `ws://${host}:${WS_PORTS[wsIdx++ % WS_PORTS.length]}/ws`;
  }
  // 单端口服务端 (TS server / 代理): WS 挂在 /ws
  return BASE.replace(/^http/, 'ws') + '/ws';
}
const BOTS = Number(process.env.BOTS ?? 2000);
const CONCURRENCY = Number(process.env.CONCURRENCY ?? 100);
const RAMP_STEP = Number(process.env.RAMP_STEP ?? 250);
const RAMP_INTERVAL_MS = Number(process.env.RAMP_INTERVAL_MS ?? 20000);
const DURATION_MS = Number(process.env.DURATION_MS ?? 7200000);
const MOVE_RATIO = Number(process.env.MOVE_RATIO ?? 1.0);
const COMBAT_RATIO = Number(process.env.COMBAT_RATIO ?? 0.6);
const DELAY_COMBAT_MS = Number(process.env.DELAY_COMBAT_MS ?? 0);
const OBSERVERS = Number(process.env.OBSERVERS ?? 24);
const SAMPLE_MS = Number(process.env.SAMPLE_MS ?? 15000);
const CLEANUP = process.env.CLEANUP === '1';
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const WORLD_SHARDS = Number(process.env.WORLD_SHARDS ?? 32);
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';
// TS 服务端要求角色 state 为有效初始状态 (空对象会导致 join 反序列化抛错)。
// 用 API 建一个模板角色读取其 state, 批量 DB seed 复用。模板失败时回退 '{}'。
const SEED_STATE_FROM_API = process.env.SEED_STATE_FROM_API === '1';

if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is required'); process.exit(1); }

async function apiTemplateState(pool) {
  // 优先复用库中已有的有效角色 state (API 建过即存在), 完全绕开 register 限流
  const existing = await pool.query(
    `SELECT state FROM characters WHERE state IS NOT NULL AND state != '{}'::jsonb AND length(state::text) > 10 ORDER BY id DESC LIMIT 1`,
  );
  if (existing.rows[0] && existing.rows[0].state && Object.keys(existing.rows[0].state).length > 0) {
    return existing.rows[0].state;
  }
  // 回退: API 建模板角色 (register 有 IP 限流, 限流时退避重试)
  for (let attempt = 0; attempt < 6; attempt++) {
    const U = 'tpl' + Date.now().toString(36).slice(-6);
    const r = await fetch(BASE + '/api/register', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: U, password: 'secret123', email: U + '@t.local' }),
    });
    if (r.status === 429) { await new Promise((res) => setTimeout(res, 3000)); continue; }
    if (r.status !== 200) return null;
    const tok = (await r.json()).token;
    const c = await fetch(BASE + '/api/characters', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + tok },
      body: JSON.stringify({ name: 'Tpl' + Date.now().toString(36).slice(-4), class: 'warrior' }),
    });
    if (c.status !== 200) return null;
    const charId = (await c.json()).id;
    const row = await pool.query('SELECT state FROM characters WHERE id=$1', [charId]);
    if (row.rows[0] && row.rows[0].state && Object.keys(row.rows[0].state).length > 0) {
      return row.rows[0].state;
    }
  }
  return null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => performance.now();
const L = 'abcdefghijklmnopqrstuvwxyz';
function letters(n) { let s = ''; let x = n + 1; while (x > 0) { s = L[x % 26] + s; x = Math.floor(x / 26); } return s; }
const pct = (arr, p) => { if (!arr.length) return 0; const s = [...arr].sort((a, b) => a - b); return s[Math.floor((s.length - 1) * p)]; };

async function seedBots(pool) {
  const usernames = [], names = [], tokens = [];
  for (let i = 0; i < BOTS; i++) {
    usernames.push(`bb${RUN}${String(i).padStart(4, '0')}`);
    names.push(`Z${RUN}${letters(i)}`.slice(0, 16));
    tokens.push(randomBytes(32).toString('hex'));
  }
  const client = await pool.connect();
  // TS 服务端要求有效初始 state: 先取模板 (限流重试), 失败中止而非回退空对象
  const templateState = SEED_STATE_FROM_API ? (await apiTemplateState(pool)) : null;
  if (SEED_STATE_FROM_API && !templateState) {
    client.release();
    throw new Error('template state fetch failed (register rate-limited?)');
  }
  try {
    await client.query('BEGIN');
    const accts = await client.query(
      `INSERT INTO accounts (username, password_hash)
       SELECT u, $2 FROM unnest($1::text[]) AS u
       ON CONFLICT DO NOTHING
       RETURNING id, username`,
      [usernames, SEED_HASH],
    );
    if (accts.rows.length !== BOTS) throw new Error(`account seed: ${accts.rows.length}/${BOTS}`);
    const idByUser = new Map(accts.rows.map((r) => [r.username, r.id]));
    const accountIds = usernames.map((u) => idByUser.get(u));
    await client.query(
      `INSERT INTO auth_tokens (token, account_id, expires_at)
       SELECT t, a, now() + interval '12 hours' FROM unnest($1::text[], $2::int[]) AS p(t, a)`,
      [tokens, accountIds],
    );
    const chars = await client.query(
      `INSERT INTO characters (account_id, name, class, realm, state)
       SELECT a, n, 'warrior', $3, $4::jsonb FROM unnest($1::int[], $2::text[]) AS p(a, n)
       ON CONFLICT DO NOTHING
       RETURNING id, account_id`,
      [accountIds, names, REALM, JSON.stringify(templateState ?? {})],
    );
    if (chars.rows.length !== BOTS) throw new Error(`char seed: ${chars.rows.length}/${BOTS}`);
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

const SNAP_PREFIX = '{"t":"snap"';

// One bot: owns a ws, tracks a lightweight visible-entity view (id -> kind)
// enough to pick combat targets, and drives movement + attack on timers.
function Bot(seeded) {
  this.ws = null;
  this.pid = -1;
  this.hello = null;
  this.view = new Map(); // id -> kind (first sight only)
  this.lastCombatAt = 0;
  this.dead = false;
  this.target = null; // last server-reported target id (self.tgt)
  this.snaps = 0;
  this.connect = () => new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrlFor());
    let done = false;
    const to = setTimeout(() => { if (!done) { done = true; try { ws.terminate(); } catch {} reject(new Error('join timeout')); } }, 30000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: seeded.token, character: seeded.charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', (d) => {
      if (done) return;
      let m; try { m = JSON.parse(d.toString()); } catch { return; }
      if (m.t === 'hello') {
        done = true; clearTimeout(to);
        this.ws = ws; this.pid = m.pid; this.hello = m;
        resolve(this);
      } else if (m.t === 'error') {
        done = true; clearTimeout(to); try { ws.close(); } catch {}
        reject(new Error(m.error ?? 'auth error'));
      }
    });
    ws.on('error', (e) => { if (!done) { done = true; clearTimeout(to); reject(e); } });
    ws.on('close', () => { if (!done) { done = true; clearTimeout(to); reject(new Error('closed before hello')); } });
  });
}

function trackView(bot, snap) {
  for (const w of snap.ents ?? []) {
    if (w.id !== undefined && !bot.view.has(w.id)) bot.view.set(w.id, w.k ?? 'unknown');
  }
}

function startActivity(bot, { combat, moving }) {
  if (!combat && !moving) return () => {};
  let lastFacing = Math.random() * Math.PI * 2;
  // 战斗延迟 (DELAY_COMBAT_MS): TS 服务端需先缓缓加人、全部进场后再开打, 避免瞬间并发
  const combatStart = setTimeout(() => {
    if (!bot.ws || bot.ws.readyState !== WebSocket.OPEN) return;
    const combatTimer = setInterval(() => {
      if (!bot.ws || bot.ws.readyState !== WebSocket.OPEN || bot.dead) return;
      if (bot.view.size === 0) return;
      const nowMs = Date.now();
      if (nowMs - bot.lastCombatAt < 1500) return;
      if (bot.target) return; // already engaged; server clears target on death/switch
      bot.lastCombatAt = nowMs;
      // target preference: mob/npc -> normal attack (auto-engage), player -> PvP,
      // unknown kind -> auto-resolve nearest enemy
      let mobId = null, playerId = null;
      for (const [id, k] of bot.view) {
        if (mobId === null && (k === 'mob' || k === 'npc')) mobId = id;
        if (playerId === null && k === 'player') playerId = id;
        if (mobId !== null && playerId !== null) break;
      }
      try {
        if (mobId !== null) bot.ws.send(JSON.stringify({ t: 'cmd', cmd: 'attack', id: mobId }));
        else if (playerId !== null) bot.ws.send(JSON.stringify({ t: 'cmd', cmd: 'pvp_attack', id: playerId }));
        else bot.ws.send(JSON.stringify({ t: 'cmd', cmd: 'attack' }));
      } catch {}
    }, combat ? 800 : 2000);
    bot._combatTimer = combatTimer;
  }, DELAY_COMBAT_MS);
  const moveTimer = setInterval(() => {
    if (!bot.ws || bot.ws.readyState !== WebSocket.OPEN || bot.dead) return;
    lastFacing = lastFacing + (Math.random() - 0.5) * 1.5;
    const mi = Math.random() < 0.6 ? { f: 1 } : Math.random() < 0.5 ? { sl: 1 } : { sl: 0.5 };
    try { bot.ws.send(JSON.stringify({ t: 'input', mi, facing: lastFacing })); } catch {}
  }, 250);
  return () => { clearTimeout(combatStart); clearInterval(bot._combatTimer); clearInterval(moveTimer); };
}

async function main() {
  const t0 = Date.now();
  console.log(`[bb] target=${BASE} bots=${BOTS} shards=${WORLD_SHARDS} ramp=${RAMP_STEP}/${RAMP_INTERVAL_MS}ms duration=${(DURATION_MS / 60000).toFixed(0)}min move=${MOVE_RATIO} combat=${COMBAT_RATIO} run=${RUN}`);
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 12 });

  let accountIds = [];
  const bots = [];
  const socks = [];
  const observers = [];
  let joined = 0, failed = 0;
  const joinTimes = [];
  let rampDone = false;

  try {
    const seedStart = Date.now();
    const seeded = await seedBots(pool);
    accountIds = seeded.accountIds;
    console.log(`[bb] seeded ${BOTS} accounts (${((Date.now() - seedStart) / 1000).toFixed(1)}s)`);

    // ---- progressive ramp: release RAMP_STEP bots every RAMP_INTERVAL_MS ----
    let released = 0;
    let nextRelease = 0;
    const connectWorker = async () => {
      while (true) {
        if (released >= BOTS) return;
        if (released >= nextRelease) { await sleep(50); continue; } // current wave not open yet
        const i = released++;
        if (i >= BOTS) return;
        const s0 = now();
        const bot = new Bot({ token: seeded.tokens[i], charId: seeded.charIds[i] });
        try {
          await bot.connect();
          joined++;
          joinTimes.push(now() - s0);
          bots.push(bot);
          socks.push(bot.ws);
          bot.ws.on('message', (d) => {
            const s = d.toString();
            if (!s.startsWith(SNAP_PREFIX)) return;
            bot.snaps++;
            // parse a fraction of snaps for the combat view to keep client CPU low
            if (bot.snaps % 3 === 0) {
              let m; try { m = JSON.parse(s); } catch { return; }
              if (m.self) {
                if (m.self.hp <= 0) bot.dead = true;
                bot.target = m.self.tgt ?? null;
              }
              trackView(bot, m);
            }
          });
          // choose observer subset on first sight
          if (observers.length < OBSERVERS && joined % Math.max(1, Math.floor(BOTS / OBSERVERS)) === 0) {
            observers.push({ ws: bot.ws, times: [], sizes: [], count: 0, tickStart: now() });
            const obs = observers[observers.length - 1];
            bot.ws.on('message', (d) => {
              const s = d.toString();
              if (s.startsWith(SNAP_PREFIX)) { obs.times.push(now()); obs.sizes.push(s.length); obs.count++; }
            });
          }
          // activity
          const moving = i < Math.floor(BOTS * MOVE_RATIO);
          const combat = i < Math.floor(BOTS * COMBAT_RATIO);
          const stopActivity = startActivity(bot, { combat, moving });
          bot._stop = stopActivity;
        } catch (e) {
          failed++;
        }
        if (joined + failed >= BOTS && released >= BOTS) rampDone = true;
      }
    };

    const rampStart = Date.now();
    console.log(`[bb] ramping up: +${RAMP_STEP} bots every ${RAMP_INTERVAL_MS}ms...`);
    nextRelease = RAMP_STEP; // first wave opens immediately
    // wave scheduler: monotonically open +RAMP_STEP more bots every interval
    const waveTimer = setInterval(() => {
      nextRelease = Math.min(nextRelease + RAMP_STEP, BOTS);
    }, RAMP_INTERVAL_MS);

    const workers = Array.from({ length: CONCURRENCY }, connectWorker);
    // monitor ramp progress
    const rampProgress = setInterval(() => {
      const openNow = socks.filter((ws) => ws.readyState === WebSocket.OPEN).length;
      console.log(`  [ramp] released=${released}/${BOTS} joined=${joined} failed=${failed} open=${openNow}`);
    }, 10000);
    await Promise.all(workers);
    clearInterval(waveTimer);
    clearInterval(rampProgress);
    const rampSec = (Date.now() - rampStart) / 1000;
    console.log(`[bb] ramp complete: joined=${joined} failed=${failed} (${rampSec.toFixed(1)}s, ${(joined / Math.max(rampSec, 0.001)).toFixed(1)} join/s, join p50=${pct(joinTimes, 0.5).toFixed(0)}ms p95=${pct(joinTimes, 0.95).toFixed(0)}ms)`);

    // ---- shard histogram from pids (shard = pid % WORLD_SHARDS) ----
    const shardCounts = new Array(WORLD_SHARDS).fill(0);
    for (const b of bots) shardCounts[b.pid % WORLD_SHARDS]++;
    const populated = shardCounts.filter((n) => n > 0).length;
    const perShard = shardCounts.filter((n) => n > 0).sort((a, b) => a - b);
    console.log(`[bb] shards populated: ${populated}/${WORLD_SHARDS} min=${perShard[0] ?? 0} max=${perShard[perShard.length - 1] ?? 0} median=${pct(perShard, 0.5)}`);

    // ---- sustained phase ----
    console.log(`[bb] stabilized. sustained phase ${DURATION_MS / 1000}s with ${joined} bots (${observers.length} observers)...`);
    const sustainedStart = now();
    let lastSweepSample = { count: 0, times: [], sizes: [] };
    let healthTotal = 0, healthN = 0, healthFail = 0;
    let worstHz = Infinity, bestHz = 0;

    const sampleTimer = setInterval(async () => {
      const nowMs = now();
      const window = (nowMs - lastSweepSample.tick) / 1000;
      // observer delta over the window
      let winCount = 0, winSizes = [], winGaps = [];
      for (const o of observers) {
        const idx = o.times.findIndex((t) => t > lastSweepSample.tick);
        const slice = idx >= 0 ? o.times.slice(idx) : [];
        winCount += slice.length;
        winSizes.push(...o.sizes.slice(idx >= 0 ? idx : o.sizes.length));
        for (let i = 1; i < slice.length; i++) winGaps.push(slice[i] - slice[i - 1]);
      }
      const rateHz = observers.length ? winCount / observers.length / Math.max(window, 0.001) : 0;
      if (rateHz < worstHz) worstHz = rateHz;
      if (rateHz > bestHz) bestHz = rateHz;
      const openNow = socks.filter((ws) => ws.readyState === WebSocket.OPEN).length;
      const alive = bots.filter((b) => b.ws && b.ws.readyState === WebSocket.OPEN && !b.dead).length;
      // health probe: GET / (static) latency
      let healthMs = -1;
      try {
        const hs = performance.now();
        const res = await fetch(BASE + '/', { signal: AbortSignal.timeout(5000) });
        healthMs = performance.now() - hs;
        healthTotal += healthMs; healthN++;
        if (res.status !== 200) healthFail++;
      } catch { healthFail++; }
      console.log(`  [probe] t+${((now() - sustainedStart) / 1000).toFixed(0)}s open=${openNow}/${joined} alive=${alive} snapHz=${rateHz.toFixed(2)} (worst=${worstHz.toFixed(2)} best=${bestHz.toFixed(2)}) size p50=${pct(winSizes, 0.5)} p95=${pct(winSizes, 0.95)} gap p50=${pct(winGaps, 0.5).toFixed(1)} p95=${pct(winGaps, 0.95).toFixed(1)}ms health=${healthMs.toFixed(0)}ms`);
      lastSweepSample = { tick: now() };
    }, SAMPLE_MS);
    lastSweepSample.tick = now();

    await sleep(DURATION_MS);
    clearInterval(sampleTimer);

    // ---- final metrics ----
    const finalOpen = socks.filter((ws) => ws.readyState === WebSocket.OPEN).length;
    const finalAlive = bots.filter((b) => b.ws && b.ws.readyState === WebSocket.OPEN && !b.dead).length;
    const allGaps = [];
    for (const o of observers) for (let i = 1; i < o.times.length; i++) allGaps.push(o.times[i] - o.times[i - 1]);
    const allSizes = observers.flatMap((o) => o.sizes);

    console.log('\n===== RESULT =====');
    console.log(`bots: joined=${joined} failed=${failed} still-open=${finalOpen}/${socks.length} alive(combatant)=${finalAlive}`);
    console.log(`sustained snapshot Hz/observer: best=${bestHz.toFixed(2)} worst=${worstHz.toFixed(2)}`);
    console.log(`snapshot size: p50=${pct(allSizes, 0.5)} p95=${pct(allSizes, 0.95)} max=${pct(allSizes, 1)} bytes`);
    console.log(`snapshot gap: p50=${pct(allGaps, 0.5).toFixed(1)} p95=${pct(allGaps, 0.95).toFixed(1)} max=${pct(allGaps, 1).toFixed(1)} ms`);
    const totalSnapHz = observers.length ? observers.reduce((a, o) => a + o.count, 0) / (DURATION_MS / 1000) / observers.length : 0;
    console.log(`est. total snapshots/s: ${(totalSnapHz * joined).toFixed(0)}`);
    console.log(`health probe: avg=${(healthTotal / Math.max(healthN, 1)).toFixed(0)}ms fails=${healthFail} n=${healthN}`);
    console.log(`shards populated: ${populated}/${WORLD_SHARDS}`);
    console.log(`uptime: ${((Date.now() - t0) / 1000).toFixed(0)}s`);

    for (const b of bots) { try { b._stop && b._stop(); } catch {} }
    for (const ws of socks) { try { ws.close(); } catch {} }
    await sleep(2000);
    if (CLEANUP) { console.log('[bb] cleanup: deleting seeded accounts'); await cleanupBots(pool, accountIds); }
  } finally {
    await pool.end();
    for (const b of bots) { try { b._stop && b._stop(); } catch {} }
    for (const ws of socks) { try { ws.terminate(); } catch {} }
  }
  console.log(`[bb] done in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
  process.exit(0);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
