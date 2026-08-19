// raw snap probe
const WebSocket = require('ws');
const token = process.argv[2], charId = process.argv[3] || "1";
const ws = new WebSocket('ws://localhost:8787/');
let gotHello = false;
ws.on('open', () => { ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 })); });
ws.on('message', (d) => {
  const t = d.toString();
  let m; try { m = JSON.parse(t); } catch (e) { console.log('RAW NON-JSON len=' + t.length + ': ' + t.slice(0,80)); return; }
  if (m.t === 'hello') { gotHello = true; console.log('HELLO pid=' + m.pid); }
  else if (m.t === 'snap') { console.log('SNAP tick=' + m.tick + ' self?' + (m.self ? 'y' : 'n') + ' ents=' + (m.ents||[]).length + ' keep=' + (m.keep||[]).length + ' firstSelfKeys=' + (m.self ? Object.keys(m.self).slice(0,12).join(',') : 'none')); }
  else if (m.t === 'events') { console.log('EVENTS ' + m.list.length + ' ' + JSON.stringify(m.list.map(e=>e.type)).slice(0,100)); }
  else { console.log('FRAME ' + m.t); }
});
ws.on('close', () => { console.log('closed gotHello=' + gotHello); process.exit(0); });
ws.on('error', (e) => { console.error('err', e.message); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 8000);
