// Stage A dispatch verification: vendor/quest/equip + previously-mismatched names
const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";
const ws = new WebSocket('ws://localhost:8787/');
let pid = 0, seq = 0;
const results = {};
function check(name, cond, extra) { results[name] = !!cond; console.log((cond ? 'PASS' : 'FAIL') + ' ' + name + (extra ? ' ' + extra : '')); }

ws.on('open', () => {
  ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 }));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.t === 'hello') { pid = msg.pid; console.log('AUTH OK pid=' + pid + ' seed=' + msg.seed); run(); }
  else if (msg.t === 'events') {
    msg.list.forEach(ev => {
      if (ev.type === 'log') console.log('[log] ' + ev.text);
    });
  } else if (msg.t === 'commandOutcome') {
    console.log('[outcome] rid=' + msg.rid + ' ok=' + msg.ok);
  }
});

function send(c) { ws.send(JSON.stringify({ t: "cmd", ...c })); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function run() {
  // harvest_node by node template id (real proto gather node)
  await sleep(300);
  send({ cmd: "harvest_node", node: "copper_vein", rid: 101 });
  await sleep(300);
  // buy from vendor (needs NPC within 6 yards — spawn near one later; just verify dispatch no crash)
  send({ cmd: "buy", item: "health_potion", rid: 102 });
  await sleep(300);
  // quest accept (real proto quest)
  send({ cmd: "accept", quest: "q_wolves", rid: 103 });
  await sleep(300);
  // mount_toggle (previously mount_summon mismatch)
  send({ cmd: "mount_toggle" });
  await sleep(300);
  // enter_delve (previously delve_enter mismatch) — will be "not implemented" but should log, not crash
  send({ cmd: "enter_delve", delveId: "drowned_litany" });
  await sleep(300);
  // chat with channel field
  send({ cmd: "chat", text: "dispatch test ok", channel: "say" });
  await sleep(600);
  console.log('=== DISPATCH TEST COMPLETE ===');
  ws.close();
  process.exit(0);
}
ws.on('error', (e) => { console.error('err', e.message); process.exit(1); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 15000);
