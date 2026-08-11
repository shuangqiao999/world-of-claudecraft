// Stage D batch 3: delve (companion_upgrade, delve_buy, lockpick_engage/action/abort, collect_delve_chest_loot,
// delve_rite_choose), card duel queue/forfeit, dungeon finder listing/proposal/application.
// Usage: node scripts/test_stage_d_batch3.cjs <tokenA> <charIdA> <tokenB> <charIdB>
// Server must be running on :8787 with ALLOW_DEV_COMMANDS=1.
const WebSocket = require('ws');
const tokenA = process.argv[2], charIdA = parseInt(process.argv[3]) || 1;
const tokenB = process.argv[4], charIdB = parseInt(process.argv[5]) || 2;
const WSU = (process.env.WS_URL || 'ws://localhost:8787') + '/';

const results = [];
function check(name, cond) {
  results.push(!!cond);
  console.log((cond ? 'PASS' : 'FAIL') + ' ' + name);
}

function client(token, charId, label) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WSU);
    const c = { ws, label, logs: [], pid: null };
    const timer = setTimeout(() => reject(new Error(label + ' hello timeout')), 8000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', (d) => {
      let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
      if (m.t === 'hello') { clearTimeout(timer); c.pid = m.pid; resolve(c); }
      if (m.t === 'events' && Array.isArray(m.list))
        for (const ev of m.list) if (ev.type === 'log') c.logs.push(ev.text);
    });
    ws.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

function send(c, obj) { c.ws.send(JSON.stringify(obj)); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
function hasLog(c, needle) { return c.logs.some(l => l.indexOf(needle) >= 0); }

(async () => {
  if (!tokenA || !tokenB) {
    console.error('Usage: node scripts/test_stage_d_batch3.cjs <tokenA> <charIdA> <tokenB> <charIdB>');
    process.exit(2);
  }

  const a = await client(tokenA, charIdA, 'A');
  const b = await client(tokenB, charIdB, 'B');
  check('hello-A', !!a.pid);
  check('hello-B', !!b.pid);

  // --- Card duel queue ---
  send(a, { cmd: 'card_queue_join' });
  await sleep(1000);
  check('card-queue-join-ok', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'card_queue_leave' });
  await sleep(800);
  check('card-queue-leave-ok', !hasLog(a, 'not implemented'));

  // --- Dungeon finder listings ---
  send(a, { cmd: 'df_list_create', activity: 'dungeon_run', tags: ['chill'] });
  await sleep(1000);
  check('df-list-create-ok', hasLog(a, 'Listing'));
  send(b, { cmd: 'df_apply', listing: 1 });
  await sleep(1000);
  check('df-apply-ok', !hasLog(b, 'not implemented'));
  send(a, { cmd: 'df_app_respond', applicant: b.pid, accept: true });
  await sleep(1000);
  check('df-respond-ok', !hasLog(a, 'not implemented'));
  send(a, { cmd: 'df_list_close' });
  await sleep(800);
  check('df-list-close-ok', hasLog(a, 'closed'));

  // --- Delve commands (no active delve needed, just no crash) ---
  send(a, { cmd: 'companion_upgrade', companionId: 'brann' });
  await sleep(800);
  check('companion-upgrade-ok', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'delve_buy', delveId: 'any', itemId: 'health_potion' });
  await sleep(800);
  check('delve-buy-ok', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'lockpick_engage', objectId: 1, ante: 1 });
  await sleep(800);
  check('lockpick-engage-ok', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'lockpick_action', sid: 'none', action: 'pick' });
  await sleep(800);
  check('lockpick-action-ok', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'lockpick_abort', sid: 'none' });
  await sleep(800);
  check('lockpick-abort-ok', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'collect_delve_chest_loot', objectId: 5 });
  await sleep(800);
  check('collect-chest-ok', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'delve_rite_choose', intensity: 'easy' });
  await sleep(800);
  check('rite-choose-ok', !hasLog(a, 'not implemented'));

  // --- Card forfeit (no active duel, just no crash) ---
  send(a, { cmd: 'card_forfeit' });
  await sleep(800);
  check('card-forfeit-ok', !hasLog(a, 'not implemented'));

  a.ws.close(); b.ws.close();
  const fails = results.filter(x => !x).length;
  console.log('\n=== BATCH3: ' + (fails === 0 ? 'ALL PASS' : fails + ' FAILURES') + ' (' + results.length + ' checks) ===');
  process.exit(fails === 0 ? 0 : 1);
})().catch(e => { console.error('ERR', e.message); process.exit(2); });
