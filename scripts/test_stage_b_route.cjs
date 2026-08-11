// Stage B: per-session event routing — create 2nd char, A whispers to B, A must not receive B's events
const WebSocket = require('ws');
const token = process.argv[2], charA = process.argv[3] || "1", charB = process.argv[4] || "2";
const wsA = new WebSocket('ws://localhost:8787/');
const wsB = new WebSocket('ws://localhost:8787/');
let pidA = 0, pidB = 0, aReady = false, bReady = false;
const results = {};

function connect(ws, charId, tag) {
  ws.on('open', () => ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 })));
  ws.on('message', (d) => {
    let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
    if (m.t === 'hello') {
      if (tag === 'A') { pidA = m.pid; aReady = true; console.log('A hello pid=' + pidA); }
      else { pidB = m.pid; bReady = true; console.log('B hello pid=' + pidB); }
      maybeStart();
    } else if (m.t === 'events') {
      m.list.forEach(ev => {
        if (tag === 'A' && ev.channel === 'whisper') {
          results.aGotWhisper = true;
          console.log('[A received whisper!] toPid=' + ev.toPid + ' text=' + ev.text);
        }
      });
    }
  });
}
function maybeStart() {
  if (!aReady || !bReady) return;
  setTimeout(() => {
    // B sends a whisper to B (self) — A must NOT receive it
    wsB.send(JSON.stringify({ t: "cmd", cmd: "chat", text: "secret for me", channel: "whisper", target: "Arthur" }));
  }, 500);
  setTimeout(() => {
    results.pass = !results.aGotWhisper;
    console.log((results.pass ? 'PASS' : 'FAIL') + ' per-session-whisper-routing aGotWhisper=' + !!results.aGotWhisper);
    wsA.close(); wsB.close();
    process.exit(results.pass ? 0 : 1);
  }, 3000);
}
wsA.on('error', (e) => console.error('A err', e.message));
wsB.on('error', (e) => console.error('B err', e.message));
setTimeout(() => { console.log('timeout aReady=' + aReady + ' bReady=' + bReady); process.exit(1); }, 12000);
connect(wsA, charA, 'A');
connect(wsB, charB, 'B');
