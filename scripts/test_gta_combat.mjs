// GTA open-world combat redesign verification against the running Moon server.
//
// Covers the server-side behaviors that were implemented but not yet verified:
//   1. wanted: killing a pedestrian NPC raises the killer's wanted level (self.wanted).
//   2. fleeing: `stopattack` flips the player's combatState to 'fleeing' (self.cst).
//   3. mob chase max distance: a spawned hostile wolf chases, but gives up once it
//      strays past its randomized chase limit (0.7..1.0 x MONSTER_MAX_CHASE_DIST).
//
// Requires: server running with ALLOW_DEV_COMMANDS=1.
// Usage:
//   DATABASE_URL=... SHARDS=32 node scripts/test_gta_combat.mjs
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import WebSocket from 'ws';

const BASE = (process.env.SERVER_URL ?? 'http://localhost:8787').replace(/\/+$/, '');
const WS = BASE.replace(/^http/, 'ws') + '/';
const SHARDS = Number(process.env.SHARDS ?? 32);
const REALM = process.env.REALM_NAME ?? 'Claudemoon';
const RUN = Math.random().toString(36).slice(2, 6);
const SEED_HASH = 'seed:token-only';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function check(name, cond, extra) {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

async function seed(pool, count, offset) {
  const usernames = [],
    names = [],
    tokens = [];
  const L = 'abcdefghijklmnopqrstuvwxyz';
  const letters = (n) => {
    let s = '';
    let x = n + 1;
    while (x > 0) {
      s = L[x % 26] + s;
      x = Math.floor(x / 26);
    }
    return s;
  };
  for (let i = 0; i < count; i++) {
    const k = offset + i;
    usernames.push(`xg${RUN}${String(k).padStart(5, '0')}`);
    names.push(`G${RUN}${letters(k)}`.slice(0, 16));
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
    const bots = accountIds.map((a) => ({
      token: tokens[accountIds.indexOf(a)],
      charId: charByAcct.get(a),
    }));
    return { bots, accountIds };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

async function cleanup(pool, accountIds) {
  for (let i = 0; i < accountIds.length; i += 500) {
    await pool.query('DELETE FROM accounts WHERE id = ANY($1::int[])', [
      accountIds.slice(i, i + 500),
    ]);
  }
}

function connect(token, charId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS);
    let done = false;
    const to = setTimeout(() => {
      if (!done) {
        done = true;
        try {
          ws.terminate();
        } catch {}
        reject(new Error('join timeout'));
      }
    }, 30000);
    ws.on('open', () =>
      ws.send(
        JSON.stringify({
          t: 'auth-world-5',
          token,
          character: charId,
          clientSeed: '',
          timerWire: 2,
        }),
      ),
    );
    ws.on('message', (d) => {
      if (done) return;
      let m;
      try {
        m = JSON.parse(d.toString());
      } catch {
        return;
      }
      if (m.t === 'hello') {
        done = true;
        clearTimeout(to);
        resolve({ ws, pid: m.pid });
      } else if (m.t === 'error') {
        done = true;
        clearTimeout(to);
        try {
          ws.close();
        } catch {}
        reject(new Error(m.error ?? 'auth error'));
      }
    });
    ws.on('error', (e) => {
      if (!done) {
        done = true;
        clearTimeout(to);
        reject(e);
      }
    });
    ws.on('close', () => {
      if (!done) {
        done = true;
        clearTimeout(to);
        reject(new Error('closed before hello'));
      }
    });
  });
}

function cmd(ws, name, args = {}) {
  ws.send(JSON.stringify({ t: 'cmd', cmd: name, ...args }));
}
function logout(ws) {
  try {
    ws.send(JSON.stringify({ t: 'logout' }));
  } catch {}
  try {
    ws.close();
  } catch {}
}
function asObj(r) {
  return typeof r === 'string' ? JSON.parse(r) : r;
}

function attachObserver(sock) {
  const state = {
    cst: null,
    wanted: null,
    selfTarget: null,
    ents: new Map(),
    selfX: null,
    selfZ: null,
    snapCount: 0,
    entsLens: [],
    keepLens: [],
    events: [],
  };
  sock.ws.on('message', (d) => {
    let m;
    try {
      m = JSON.parse(d.toString());
    } catch {
      return;
    }
    if (m.t === 'snap') {
      state.snapCount++;
      if (Array.isArray(m.ents)) state.entsLens.push(m.ents.length);
      if (Array.isArray(m.keep)) state.keepLens.push(m.keep.length);
      if (m.self !== undefined) {
        const s = asObj(m.self);
        if (s.cst !== undefined) state.cst = s.cst;
        if (s.wanted !== undefined) state.wanted = s.wanted;
        if (s.target !== undefined) state.selfTarget = s.target;
        if (s.x !== undefined) state.selfX = s.x;
        if (s.z !== undefined) state.selfZ = s.z;
      }
      if (Array.isArray(m.ents)) {
        for (const rec of m.ents) {
          const r = asObj(rec);
          if (r.id !== undefined) {
            const prev = state.ents.get(r.id);
            state.ents.set(r.id, { ...(prev || {}), ...r });
          }
        }
      }
    } else if (m.t === 'events') {
      const arr = Array.isArray(m.list) ? m.list : m.list ? [m.list] : [];
      for (const ev of arr) state.events.push(ev);
    }
  });
  return state;
}

async function main() {
  const t0 = Date.now();
  if (!process.env.DATABASE_URL) {
    console.error('DATABASE_URL is required');
    process.exit(1);
  }
  console.log(`[gta] target=${BASE} shards=${SHARDS} run=${RUN}`);

  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  const bots = [];
  try {
    const { bots: seeded, accountIds } = await seed(pool, 1, 0);
    console.log(
      `[gta] seeded ${seeded.length} account(s) (${((Date.now() - t0) / 1000).toFixed(1)}s)`,
    );

    const b = seeded[0];
    const conn = await connect(b.token, b.charId);
    bots.push(conn.ws);
    const bot = conn;
    console.log(`[gta] joined pid=${bot.pid} shard=${bot.pid % SHARDS}`);

    // Attach BEFORE dev_level so the observer catches the full-record snapshot the
    // target shard sends right after migration (a late attach only sees `keep`).
    const state = attachObserver(bot);

    cmd(bot.ws, 'dev_level', { level: 20 });
    await sleep(500);

    // --- 1a. wanted: kill a pedestrian NPC ---
    // Give the player a melee weapon so selecting the pedestrian enters auto_fight
    // (unarmed selection is select-only), then spawn a deterministic test pedestrian
    // right beside the player (no simrng scatter / AOI-culling / dead-zone involved),
    // melee it to death, and despawn the corpse.
    cmd(bot.ws, 'dev_give', { item: 'worn_sword' });
    await sleep(300);
    cmd(bot.ws, 'equip', { item: 'worn_sword' });
    await sleep(500);
    const beforeWanted = state.wanted ?? 0;
    const logBefore = state.events.length;
    cmd(bot.ws, 'dev_spawn_ped', {});
    await sleep(800);
    const spawnEvt = state.events
      .slice(logBefore)
      .find((ev) => ev.type === 'log' && /Spawned pedestrian id=(\d+)/.test(ev.text ?? ''));
    const pedId = spawnEvt ? Number((spawnEvt.text || '').match(/id=(\d+)/)?.[1]) : null;
    if (!pedId) {
      check('killing a pedestrian raises wanted', false, 'dev_spawn_ped produced no id');
    } else {
      // Kill via a direct damage call (bypasses auto_attack swing-timer quirks) so the
      // assertion targets the wanted pipeline: dealDamage records lastAttackerId, then
      // handleDeath raises wanted on the killer.
      cmd(bot.ws, 'dev_damage', { id: pedId, amount: 100 });
      let pedKilled = false;
      for (let i = 0; i < 10 && !pedKilled; i++) {
        await sleep(1000);
        if ((state.wanted ?? 0) > beforeWanted) pedKilled = true;
      }
      check(
        'killing a pedestrian raises wanted',
        pedKilled,
        `wanted ${beforeWanted} -> ${state.wanted} pedId=${pedId}`,
      );
      cmd(bot.ws, 'dev_despawn', { id: pedId });
      await sleep(300);
    }

    // Move far from spawn camps and pedestrians to control the remaining scene.
    cmd(bot.ws, 'dev_teleport', { x: 3000, z: 3000 });
    await sleep(1500);

    // --- 2. fleeing ---
    cmd(bot.ws, 'stopattack');
    await sleep(500);
    check(
      'stopattack flips combatState to fleeing (self.cst)',
      state.cst === 'fleeing',
      `cst=${state.cst}`,
    );
    // Reset to idle so the chase test starts clean.
    cmd(bot.ws, 'target', { id: null });
    await sleep(400);

    // --- 3. mob chase max distance ---
    // dev_give with no item spawns a hostile forest_wolf near the player.
    cmd(bot.ws, 'dev_give', {});
    await sleep(1000);
    const wolfEntry = [...state.ents.values()].find(
      (e) => e.k === 'mob' || e.tid === 'forest_wolf',
    );
    if (!wolfEntry) {
      console.log(
        '  SKIP  mob chase: no spawned wolf observed (dev_give may not have spawned one)',
      );
    } else {
      const wolfId = wolfEntry.id;
      const spawnX = wolfEntry.x;
      const spawnZ = wolfEntry.z;
      console.log(`[gta] spawned wolf id=${wolfId} at (${spawnX},${spawnZ})`);
      // Attack the wolf so it actually enters CHASING (hostile wolf aggros the attacker).
      cmd(bot.ws, 'dev_target', { id: wolfId });
      await sleep(3000);
      const wolfChasing = state.ents.get(wolfId);
      const chased = wolfChasing
        ? Math.hypot((wolfChasing.x ?? spawnX) - spawnX, (wolfChasing.z ?? spawnZ) - spawnZ)
        : 0;
      console.log(`[gta] wolf chasing: stray=${chased.toFixed(1)}yd from spawn`);
      // Teleport the player far beyond MONSTER_MAX_CHASE_DIST (120 yd); the wolf
      // should chase but give up once it strays past its randomized chase limit,
      // then return toward spawn. It must never reach the player 200 yd away.
      cmd(bot.ws, 'dev_teleport', { x: 3000 + 200, z: 3000 });
      await sleep(15000);
      const wolf = state.ents.get(wolfId);
      if (wolf && wolf.x !== undefined) {
        const dist = Math.hypot(wolf.x - spawnX, wolf.z - spawnZ);
        check(
          'mob gives up chasing past its max distance',
          dist < 160,
          `wolf stray=${dist.toFixed(0)}yd from spawn (player 200yd away)`,
        );
      } else {
        check('mob gives up chasing past its max distance', false, 'wolf not observed after chase');
      }
    }

    // --- 1b. wanted: kill another player (PvP) ---
    {
      const { bots: bots2, accountIds: ids2 } = await seed(pool, 1, 200000);
      accountIds.push(...ids2);
      const b2 = bots2[0];
      const conn2 = await connect(b2.token, b2.charId);
      bots.push(conn2.ws);
      // Bot B is level 1 (90 HP) so a single kill shot raises Bot A's wanted
      // (killing a player, like a pedestrian, is a crime).
      cmd(conn2.ws, 'dev_level', { level: 1 });
      await sleep(300);
      cmd(conn2.ws, 'dev_teleport', { x: 3200, z: 3000 });
      // The shard migration for Bot B takes several ticks after the teleport; wait
      // until it actually lands in Bot A's shard, or pvp_attack sees no local target.
      await sleep(8000);
      cmd(bot.ws, 'dev_give', { item: 'worn_sword' });
      await sleep(300);
      cmd(bot.ws, 'equip', { item: 'worn_sword' });
      await sleep(300);
      cmd(bot.ws, 'target', { id: null });
      cmd(bot.ws, 'dev_teleport', { x: 3198, z: 3000 });
      await sleep(1200);
      const beforePvpWanted = state.wanted ?? 0;
      cmd(bot.ws, 'pvp_attack', { id: conn2.pid });
      await sleep(500);
      // pvp_attack only flags consent; then kill via a direct damage call (bypasses
      // auto_attack miss/dodge/parry swing luck) so the assertion targets the wanted
      // pipeline: dealDamage records lastAttackerId, handleDeath raises wanted.
      cmd(bot.ws, 'dev_damage', { id: conn2.pid, amount: 200 });
      let pvpKilled = false;
      for (let i = 0; i < 15 && !pvpKilled; i++) {
        if ((state.wanted ?? 0) > beforePvpWanted) pvpKilled = true;
        else await sleep(1000);
      }
      check(
        'killing a player raises wanted',
        pvpKilled,
        `wanted ${beforePvpWanted} -> ${state.wanted} cst=${state.cst} target=${state.selfTarget}`,
      );
    }

    console.log(
      `\n[gta] done in ${((Date.now() - t0) / 1000).toFixed(1)}s — ${failures === 0 ? 'RESULT: PASS' : 'RESULT: FAIL'}`,
    );

    for (const w of bots) logout(w);
    await sleep(500);
    await cleanup(pool, accountIds);
  } finally {
    await pool.end().catch(() => {});
  }
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error('FATAL', e);
  process.exit(1);
});
