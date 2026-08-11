// Stage D batch 2: profession commands — train_recipe, slot/recharge_tool_effect, disenchant/apply_enchant,
// salvage_item, unbind_item, place_mobile_station, commission orders (open/cancel/accept/deliver).
// Usage: node scripts/test_stage_d_batch2.cjs <tokenA> <charIdA> <tokenB> <charIdB>
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
    const c = { ws, label, snaps: [], logs: [], pid: null };
    const timer = setTimeout(() => reject(new Error(label + ' hello timeout')), 8000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', (d) => {
      let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
      if (m.t === 'hello') { clearTimeout(timer); c.pid = m.pid; resolve(c); }
      if (m.t === 'snap') c.snaps.push(m);
      if (m.t === 'events' && Array.isArray(m.list)) {
        for (const ev of m.list) if (ev.type === 'log') c.logs.push(ev.text);
      }
    });
    ws.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

function send(c, obj) { c.ws.send(JSON.stringify(obj)); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function hasLog(c, needle) {
  return c.logs.some(l => l.indexOf(needle) >= 0);
}

(async () => {
  if (!tokenA || !tokenB) {
    console.error('Usage: node scripts/test_stage_d_batch2.cjs <tokenA> <charIdA> <tokenB> <charIdB>');
    process.exit(2);
  }

  const a = await client(tokenA, charIdA, 'A');
  const b = await client(tokenB, charIdB, 'B');
  check('hello-A', !!a.pid);
  check('hello-B', !!b.pid);

  // --- train_recipe ---
  send(a, { cmd: 'train_recipe', recipeId: 'health_potion_brew' });
  await sleep(1500);
  check('train-recipe-ok', !hasLog(a, 'Unknown recipe'));

  // --- give item for disenchant/salvage/unbind/enchant ---
  send(a, { cmd: 'dev_give', item: 'leather_gloves' });
  await sleep(2000);

  // --- disenchant_item ---
  send(a, { cmd: 'disenchant_item', itemId: 'leather_gloves' });
  await sleep(1500);
  check('disenchant-item-ok', hasLog(a, 'Disenchanted'));

  // give another item for salvage
  send(a, { cmd: 'dev_give', item: 'leather_gloves' });
  await sleep(2000);

  // --- salvage_item ---
  send(a, { cmd: 'salvage_item', itemId: 'leather_gloves' });
  await sleep(1500);
  check('salvage-item-ok', hasLog(a, 'Salvaged'));

  // another item for enchant/unbind
  send(a, { cmd: 'dev_give', item: 'leather_gloves' });
  await sleep(2000);

  // --- apply_enchant ---
  send(a, { cmd: 'apply_enchant', itemId: 'leather_gloves', enchantId: 'enchant_fire', slot: 1 });
  await sleep(1500);
  check('apply-enchant-ok', hasLog(a, 'Enchant applied'));

  // --- unbind_item ---
  send(a, { cmd: 'unbind_item', itemId: 'leather_gloves' });
  await sleep(1500);
  check('unbind-item-ok', hasLog(a, 'unbound'));

  // --- slot_tool_effect ---
  send(a, { cmd: 'slot_tool_effect', professionId: 'alchemy', effectId: 'philosopher_stone' });
  await sleep(1000);
  check('slot-tool-effect-ok', !hasLog(a, 'not implemented'));

  // --- recharge_tool_effect ---
  send(a, { cmd: 'recharge_tool_effect', professionId: 'alchemy' });
  await sleep(1000);
  check('recharge-tool-ok', !hasLog(a, 'not implemented'));

  // --- place_mobile_station ---
  send(a, { cmd: 'place_mobile_station', craftId: 'portable_anvil' });
  await sleep(1000);
  check('place-station-ok', !hasLog(a, 'not implemented'));

  // --- commission orders ---
  send(a, { cmd: 'open_commission_order', recipeId: 'health_potion_brew', scope: 'public' });
  await sleep(1500);
  check('commission-open-ok', hasLog(a, 'Commission order'));

  send(a, { cmd: 'cancel_commission_order', orderId: 1 });
  await sleep(1000);
  check('commission-cancel-ok', hasLog(a, 'cancelled'));

  // open a new one for accept/deliver
  send(a, { cmd: 'open_commission_order', recipeId: 'health_potion_brew', scope: 'public' });
  await sleep(1500);

  send(b, { cmd: 'accept_commission_order', orderId: 2 });
  await sleep(1500);
  check('commission-accept-ok', hasLog(b, 'accepted'));

  send(b, { cmd: 'deliver_commission_order', orderId: 2 });
  await sleep(1500);
  check('commission-deliver-ok', hasLog(b, 'completed'));

  a.ws.close(); b.ws.close();
  const fails = results.filter(x => !x).length;
  console.log('\n=== BATCH2: ' + (fails === 0 ? 'ALL PASS' : fails + ' FAILURES') + ' (' + results.length + ' checks) ===');
  process.exit(fails === 0 ? 0 : 1);
})().catch(e => { console.error('ERR', e.message); process.exit(2); });
