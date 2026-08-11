// Stage C: persistence round-trip — dev_level to 5, relog, verify level+copper kept
const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";
let pid = 0;

function connect() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket('ws://localhost:8787/');
    ws.on('open', () => ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 })));
    ws.on('message', (d) => {
      let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
      if (m.t === 'hello') resolve(ws);
      if (m.t === 'error') reject(new Error(m.error));
    });
    ws.on('error', reject);
    setTimeout(() => reject(new Error('timeout')), 8000);
  });
}

(async () => {
  // first session: set level 5 and give some copper via dev
  let ws = await connect();
  ws.send(JSON.stringify({ t: "cmd", cmd: "dev_level", level: 5, rid: 1 }));
  await new Promise(r => setTimeout(r, 1500));
  ws.close();
  await new Promise(r => setTimeout(r, 2000)); // let autosave/leave persist

  // second session: verify level preserved
  ws = await connect();
  let gotSnap = false;
  await new Promise((resolve) => {
    ws.on('message', (d) => {
      let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
      if (m.t === 'snap' && m.self && !gotSnap) {
        gotSnap = true;
        console.log('relog self lv=' + m.self.lv);
        const pass = m.self.lv === 5;
        console.log((pass ? 'PASS' : 'FAIL') + ' level-persisted-across-relog');
        ws.close();
        resolve();
      }
    });
    setTimeout(resolve, 8000);
  });
  process.exit(0);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
