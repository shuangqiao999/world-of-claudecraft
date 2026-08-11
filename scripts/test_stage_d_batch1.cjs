// Stage D batch 1: buyback, guild create/invite/accept/disband, guild_bank_log (gbanklog frame),
// party pdecline/pmoveRaid/setLootMaster/masterAssign, market_list_instance.
// Usage: node scripts/test_stage_d_batch1.cjs <tokenA> <charIdA> <tokenB> <charIdB>
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
    const c = { ws, label, snaps: [], logs: [], events: [], social: null, gbanklog: null, pid: null };
    const timer = setTimeout(() => reject(new Error(label + ' hello timeout')), 8000);
    ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
    ws.on('message', (d) => {
      let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
      if (m.t === 'hello') { clearTimeout(timer); c.pid = m.pid; resolve(c); }
      if (m.t === 'snap') c.snaps.push(m);
      if (m.t === 'events' && Array.isArray(m.list)) {
        c.events.push(...m.list);
        for (const ev of m.list) if (ev.type === 'log') c.logs.push(ev.text);
      }
      if (m.t === 'social') c.social = m;
      if (m.t === 'gbanklog') c.gbanklog = m;
    });
    ws.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

function send(c, obj) { c.ws.send(JSON.stringify(obj)); }

function waitGbankLog(c, ms) {
  const deadline = Date.now() + (ms || 6000);
  return new Promise((res) => {
    const t = setInterval(() => {
      if (c.gbanklog) { clearInterval(t); res(true); }
      else if (Date.now() > deadline) { clearInterval(t); res(false); }
    }, 100);
  });
}

function findItemInSnaps(c, itemId) {
  for (let i = c.snaps.length - 1; i >= 0; i--) {
    const self = c.snaps[i].self;
    if (self && self.inv) {
      for (const [slot, it] of Object.entries(self.inv))
        if (it && it.id === itemId) return Number(slot);
    }
  }
  return null;
}

function waitBuybackEntry(c, ms) {
  const deadline = Date.now() + (ms || 4000);
  return new Promise((res) => {
    const t = setInterval(() => {
      for (const s of c.snaps) {
        if (s.self && Array.isArray(s.self.buyback) && s.self.buyback.length > 0) {
          clearInterval(t); res(s.self.buyback); return;
        }
      }
      if (Date.now() > deadline) { clearInterval(t); res(null); }
    }, 100);
  });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

(async () => {
  if (!tokenA || !tokenB) {
    console.error('Usage: node scripts/test_stage_d_batch1.cjs <tokenA> <charIdA> <tokenB> <charIdB>');
    process.exit(2);
  }

  const a = await client(tokenA, charIdA, 'A');
  const b = await client(tokenB, charIdB, 'B');
  check('hello-A', !!a.pid);
  check('hello-B', !!b.pid);

  // --- buyback ---
  send(a, { cmd: 'dev_give', item: 'leather_gloves' });
  await sleep(2000);
  const sellSlot = findItemInSnaps(a, 'leather_gloves');
  check('buyback-sell-setup', sellSlot !== null);
  if (sellSlot !== null) {
    send(a, { cmd: 'sell', item: 'leather_gloves', slot: sellSlot });
    const bb = await waitBuybackEntry(a, 4000);
    check('buyback-appears', bb !== null && bb.length > 0);
    if (bb && bb.length > 0) {
      const idx = bb[bb.length - 1].index;
      send(a, { cmd: 'buyback', item: 'leather_gloves', index: idx });
      await sleep(1500);
      check('buyback-restores-item', findItemInSnaps(a, 'leather_gloves') !== null);
    }
  }

  // --- guild: create → invite → accept → deposit gold → gbanklog ---
  const gName = 'GT' + Date.now().toString(36).slice(-6).toUpperCase();
  send(a, { cmd: 'guild_create', name: gName });
  await sleep(2000);
  check('guild-created', a.social && a.social.guild);

  send(a, { cmd: 'guild_invite', name: 'Mb' + process.argv[2].slice(0, 5) + 'X' });
  await sleep(2000);
  send(b, { cmd: 'guild_accept' });
  await sleep(2500);
  check('guild-accepted-member', b.social && b.social.guild);

  send(a, { cmd: 'dev_give', item: 'leather_gloves' });
  await sleep(1500);
  const slot2 = findItemInSnaps(a, 'leather_gloves');
  if (slot2 !== null) send(a, { cmd: 'sell', item: 'leather_gloves', slot: slot2 });
  await sleep(1000);
  send(a, { cmd: 'guild_bank_deposit_gold', amount: 25 });
  await sleep(1000);

  send(a, { cmd: 'guild_bank_log' });
  const gotLog = await waitGbankLog(a, 6000);
  check('gbanklog-frame', gotLog && a.gbanklog && a.gbanklog.ok && Array.isArray(a.gbanklog.entries) && a.gbanklog.entries.length > 0);

  // --- party commands: no "not implemented" in logs ---
  send(a, { cmd: 'pdecline' });
  send(a, { cmd: 'pmoveRaid', id: b.pid, group: 1 });
  send(a, { cmd: 'setLootMaster', enabled: true, looter: a.pid, threshold: 'rare' });
  send(a, { cmd: 'masterAssign', rollId: 1, pids: [b.pid] });
  await sleep(1200);
  const partyOk = a.logs.every(l => l.indexOf('is not implemented') < 0);
  check('party-commands-no-notimpl', partyOk);

  // --- market_list_instance ---
  send(a, { cmd: 'market_list_instance', item: 'leather_gloves', price: 5, instance: {} });
  await sleep(2000);
  const mktOk = a.logs.some(l => l.indexOf('Market') >= 0);
  check('market-list-instance-responded', mktOk);

  // --- report ---
  a.ws.close(); b.ws.close();
  const fails = results.filter(x => !x).length;
  console.log('\n=== BATCH1: ' + (fails === 0 ? 'ALL PASS' : fails + ' FAILURES') + ' (' + results.length + ' checks) ===');
  process.exit(fails === 0 ? 0 : 1);
})().catch(e => { console.error('ERR', e.message); process.exit(2); });
