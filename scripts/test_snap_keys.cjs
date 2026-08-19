const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";
const ws = new WebSocket('ws://localhost:8787/');
ws.on('open', () => { ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 })); });
ws.on('message', (d) => {
  let m; try { m = JSON.parse(d.toString()); } catch (e) { return; }
  if (m.t === 'snap' && m.self) {
    const keys = Object.keys(m.self);
    console.log('snap self keys (' + keys.length + '): ' + keys.join(','));
    console.log('has inv=' + ('inv' in m.self) + ' equip=' + ('equip' in m.self) + ' qlog=' + ('qlog' in m.self) + ' stats=' + ('stats' in m.self));
    ws.close(); process.exit(0);
  }
});
ws.on('error', (e) => { console.error('err', e.message); });
setTimeout(() => { process.exit(1); }, 8000);
