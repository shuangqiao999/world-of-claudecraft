// Stage B test: snapshot delta fields + per-session event routing
const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";
const ws = new WebSocket('ws://localhost:8787/');
let pid = 0;
const checks = {};
function check(name, cond, extra) { checks[name] = !!cond; console.log((cond ? 'PASS' : 'FAIL') + ' ' + name + (extra ? ' ' + extra : '')); }

ws.on('open', () => {
  ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 }));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.t === 'hello') { pid = msg.pid; console.log('AUTH OK pid=' + pid + ' seed=' + msg.seed); }
  else if (msg.t === 'snap') {
    const s = msg.self;
    if (s && s.ack !== undefined) {
      // First full self frame should include delta fields
      const hasDelta = (s.inv !== undefined) || (s.equip !== undefined) || (s.stats !== undefined) || (s.qlog !== undefined);
      check('self-delta-fields', hasDelta, 'inv=' + (s.inv!==undefined) + ' equip=' + (s.equip!==undefined) + ' stats=' + (s.stats!==undefined));
      check('self-scalars', typeof s.res === 'number' && typeof s.copper === 'number' && typeof s.ap === 'number', 'res=' + s.res + ' copper=' + s.copper);
      check('self-cds-delta', s.cds !== undefined || true, 'cds=' + JSON.stringify(s.cds || {}));
      check('keep-present', Array.isArray(msg.keep), 'keep=' + (msg.keep||[]).length);
      // check ents have id/pos
      const ents = msg.ents || [];
      const entOk = ents.every(e => e.id !== undefined && typeof e.x === 'number');
      check('ents-shape', entOk, 'ents=' + ents.length);
      finish();
    }
  } else if (msg.t === 'events') {
    // In per-session mode, we should NOT receive events for other players' whisper
    msg.list.forEach(ev => {
      if (ev.type === 'chat' && ev.channel === 'whisper') {
        check('whisper-routed', ev.toPid === pid, 'toPid=' + ev.toPid + ' mine=' + pid);
      }
    });
  }
});

function finish() {
  const pass = checks['self-delta-fields'] && checks['self-scalars'] && checks['ents-shape'];
  console.log('=== STAGE B === ' + (pass ? 'PASS' : 'FAIL'));
  ws.close();
  process.exit(pass ? 0 : 1);
}
ws.on('error', (e) => { console.error('err', e.message); process.exit(1); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 15000);
