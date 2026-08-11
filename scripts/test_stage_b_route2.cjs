// Stage B: verify whisper to offline name only reaches sender (not other sessions)
const WebSocket = require('ws');
const token = process.argv[2], charA = process.argv[3] || "1", charB = process.argv[4] || "2";
const wsA = new WebSocket('ws://localhost:8787/');
const wsB = new WebSocket('ws://localhost:8787/');
let aReady = false, bReady = false;
let aSaw = [], bSaw = [];

function connect(ws, charId, tag, collector) {
  ws.on('open', () => ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 })));
  ws.on('message', (d) => {
    let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
    if (m.t === 'hello') {
      if (tag === 'A') { aReady = true; } else { bReady = true; }
      maybeStart();
    } else if (m.t === 'events') {
      m.list.forEach(ev => { if (ev.channel === 'whisper' || (ev.type === 'log' && ev.text && ev.text.indexOf('not online') >= 0)) collector.push(ev); });
    }
  });
}
function maybeStart() {
  if (!aReady || !bReady) return;
  setTimeout(() => {
    // B whispers to "Nobody" (not online) — only B should get the "not online" log; A must get nothing
    wsB.send(JSON.stringify({ t: "cmd", cmd: "chat", text: "hi", channel: "whisper", target: "Nobody" }));
  }, 400);
  setTimeout(() => {
    const bGot = bSaw.length > 0;
    const aGot = aSaw.length > 0;
    const pass = bGot && !aGot;
    console.log('A whisper-related frames: ' + aSaw.length + ' | B: ' + bSaw.length);
    console.log((pass ? 'PASS' : 'FAIL') + ' offline-whisper-logs-only-to-sender');
    wsA.close(); wsB.close();
    process.exit(pass ? 0 : 1);
  }, 3000);
}
wsA.on('error', () => {});
wsB.on('error', () => {});
setTimeout(() => { console.log('timeout'); process.exit(1); }, 12000);
connect(wsA, charA, 'A', aSaw);
connect(wsB, charB, 'B', bSaw);
