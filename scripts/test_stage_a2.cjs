// Stage A test 2: verify snap flow + command dispatch + successful commandOutcome via enter_dungeon
const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";
const ws = new WebSocket('ws://localhost:8787/');
let pid = 0, seq = 0, snaps = 0, moved = false, outcomeRid = null, outcomeOk = null;
let lastX = null, lastZ = null;

ws.on('open', () => {
  ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 }));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.t === 'hello') {
    pid = msg.pid;
    console.log('AUTH OK pid=' + pid + ' seed=' + msg.seed);
    setInterval(() => {
      seq++;
      ws.send(JSON.stringify({ t: "input", seq, mi: { f: 1, b: 0, tl: 0, tr: 0, sl: 0, sr: 0, j: 0, dv: 0, sf: 0 }, facing: 0 }));
    }, 50);
    setTimeout(() => {
      // a dispatch-only command with rid: enter_dungeon (not implemented yet -> ok=false but SHOULD answer)
      ws.send(JSON.stringify({ t: "cmd", cmd: "enter_dungeon", dungeon: "hollow_crypt", rid: 777 }));
    }, 1500);
  } else if (msg.t === 'snap') {
    snaps++;
    const s = msg.self;
    if (s && (lastX === null)) { lastX = s.x; lastZ = s.z; }
    if (s && lastX !== null && (Math.abs(s.x - lastX) > 0.5 || Math.abs(s.z - lastZ) > 0.5)) {
      if (!moved) { moved = true; console.log('MOVEMENT CONFIRMED x=' + s.x.toFixed(1) + ' z=' + s.z.toFixed(1) + ' (snap ' + snaps + ')'); }
    }
  } else if (msg.t === 'commandOutcome') {
    outcomeRid = msg.rid; outcomeOk = msg.ok;
    console.log('COMMAND OUTCOME rid=' + msg.rid + ' ok=' + msg.ok);
    finish();
  }
});

function finish() {
  const pass = snaps > 5 && moved && outcomeRid === 777 && outcomeOk === false;
  console.log('=== RESULT === snaps=' + snaps + ' moved=' + moved + ' outcome=' + (outcomeRid === 777 ? 'ANSWERED' : 'MISSING'));
  ws.close();
  process.exit(pass ? 0 : 1);
}
ws.on('close', () => { process.exit(outcomeRid === 777 ? 0 : 1); });
ws.on('error', (e) => { console.error('err', e.message); process.exit(1); });
setTimeout(() => { console.log('TIMEOUT snaps=' + snaps + ' outcomeRid=' + outcomeRid); process.exit(1); }, 12000);
