// Stage D batch 4: pet_water_jet, pet_feed, mount_train_begin, mount_race_start, mount_race_cancel,
// prestige, selectTalentRow, arena_augment.
// Usage: node scripts/test_stage_d_batch4.cjs <tokenA> <charIdA> <tokenB> <charIdB>
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
    console.error('Usage: node scripts/test_stage_d_batch4.cjs <tokenA> <charIdA> <tokenB> <charIdB>');
    process.exit(2);
  }

  const a = await client(tokenA, charIdA, 'A');
  const b = await client(tokenB, charIdB, 'B');
  check('hello-A', !!a.pid);
  check('hello-B', !!b.pid);

  // --- pet commands (no pet needed, just no "not implemented") ---
  send(a, { cmd: 'pet_water_jet' });
  await sleep(800);
  check('pet-water-jet', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'pet_feed', item: 'fresh_meat' });
  await sleep(800);
  check('pet-feed', !hasLog(a, 'not implemented'));

  // --- mount commands ---
  send(a, { cmd: 'mount_train_begin' });
  await sleep(800);
  check('mount-train-begin', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'mount_race_start' });
  await sleep(800);
  check('mount-race-start', !hasLog(a, 'not implemented'));

  send(a, { cmd: 'mount_race_cancel' });
  await sleep(800);
  check('mount-race-cancel', !hasLog(a, 'not implemented'));

  // --- prestige ---
  send(a, { cmd: 'prestige' });
  await sleep(800);
  check('prestige', !hasLog(a, 'not implemented'));

  // --- talent row select ---
  send(a, { cmd: 'selectTalentRow', level: 5, optionId: 'war_row_double_charge' });
  await sleep(800);
  check('select-talent-row', !hasLog(a, 'not implemented'));

  // --- arena augment ---
  send(a, { cmd: 'arena_augment', augment: 'zerker' });
  await sleep(800);
  check('arena-augment', !hasLog(a, 'not implemented'));

  a.ws.close(); b.ws.close();
  const fails = results.filter(x => !x).length;
  console.log('\n=== BATCH4: ' + (fails === 0 ? 'ALL PASS' : fails + ' FAILURES') + ' (' + results.length + ' checks) ===');
  process.exit(fails === 0 ? 0 : 1);
})().catch(e => { console.error('ERR', e.message); process.exit(2); });
