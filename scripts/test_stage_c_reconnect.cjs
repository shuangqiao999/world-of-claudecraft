// Stage C: reconnect resume test — connect, get pid, drop, reconnect, must get SAME pid
const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";

function connect() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket('ws://localhost:8787/');
    ws.on('open', () => ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 })));
    ws.on('message', (d) => {
      let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
      if (m.t === 'hello') resolve({ ws, pid: m.pid });
      if (m.t === 'error') reject(new Error('auth error: ' + m.error));
    });
    ws.on('error', reject);
    setTimeout(() => reject(new Error('timeout')), 8000);
  });
}

(async () => {
  const { ws: ws1, pid: pid1 } = await connect();
  console.log('first auth pid=' + pid1);
  ws1.close(); // simulate drop
  await new Promise(r => setTimeout(r, 500));
  const { ws: ws2, pid: pid2 } = await connect();
  console.log('reconnect pid=' + pid2);
  const pass = pid1 === pid2;
  console.log((pass ? 'PASS' : 'FAIL') + ' reconnect-resumes-same-pid');
  ws2.close();
  process.exit(pass ? 0 : 1);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
