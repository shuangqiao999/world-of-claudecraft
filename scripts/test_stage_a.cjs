// Stage A test: jump input mapping + command dispatch + commandOutcome
const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";
const ws = new WebSocket('ws://localhost:8787/');
let pid = 0, seq = 0, startY = null, jumped = false, snaps = 0;
let harvestOk = false, outcomeRid = null, outcomeOk = null;

ws.on('open', () => {
  ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 }));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.t === 'hello') {
    pid = msg.pid;
    console.log('AUTH OK pid=' + pid + ' seed=' + msg.seed);
    // send forward+jump
    setInterval(() => {
      seq++;
      ws.send(JSON.stringify({ t: "input", seq, mi: { f: 1, b: 0, tl: 0, tr: 0, sl: 0, sr: 0, j: 1, dv: 0, sf: 0 }, facing: 0 }));
    }, 50);
    setTimeout(() => {
      // command with rid (harvest_node uses cmdWithOutcome)
      ws.send(JSON.stringify({ t: "cmd", cmd: "harvest_node", node: "herb_1", rid: 777 }));
    }, 1500);
    setTimeout(() => {
      // a dispatch-only command that should resolve via new dispatcher: set_helm
      ws.send(JSON.stringify({ t: "cmd", cmd: "set_helm", hidden: true }));
    }, 2500);
  } else if (msg.t === 'snap') {
    snaps++;
    const s = msg.self;
    if (s && !startY) { startY = s.y; console.log('start pos x=' + s.x + ' z=' + s.z + ' y=' + s.y); }
    if (s && startY !== null && snaps > 5 && !jumped) {
      const dy = Math.abs(s.y - startY);
      if (dy > 0.1) { jumped = true; console.log('JUMP DETECTED y=' + s.y + ' (dy=' + dy.toFixed(2) + ')'); }
      else if (s.x !== 0 || s.z !== 0) { console.log('MOVING x=' + s.x.toFixed(1) + ' z=' + s.z.toFixed(1)); }
    }
  } else if (msg.t === 'events') {
    msg.list.forEach(ev => {
      if (ev.type === 'chat' || ev.type === 'log') console.log('[log]', ev.text || ev.channel + ':' + ev.text);
    });
  } else if (msg.t === 'commandOutcome') {
    outcomeRid = msg.rid; outcomeOk = msg.ok;
    console.log('COMMAND OUTCOME rid=' + msg.rid + ' ok=' + msg.ok);
    finish();
  }
});

function finish() {
  console.log('=== Stage A verification ===');
  console.log('jumped=' + jumped + ' snaps=' + snaps + ' outcome=' + (outcomeOk === true ? 'OK' : 'MISSING/FAIL'));
  ws.close();
  process.exit(jumped && outcomeOk === true ? 0 : 1);
}

ws.on('close', () => { console.log('closed'); process.exit(0); });
ws.on('error', (e) => { console.error('err', e.message); process.exit(1); });
setTimeout(() => { console.log('TIMEOUT jumped=' + jumped + ' outcomeRid=' + outcomeRid); process.exit(1); }, 15000);
