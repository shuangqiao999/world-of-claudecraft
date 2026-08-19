// Diagnostic: capture raw snap frames, analyze tick/time/position stability
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace('http', 'ws') + '/';
const USER = 'jit' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
async function http(method, path, body, token) {
  const r = await fetch(BASE + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return r.json().catch(() => ({}));
}

(async () => {
  const reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  let token = reg.token;
  if (!token) token = (await http('POST', '/api/login', { username: USER, password: PASS })).token;
  let chars = await http('GET', '/api/characters', null, token);
  let charId;
  if (!chars?.length) {
    const name = 'J' + Date.now().toString(36).slice(-8).replace(/[0-9]/g, 'a');
    charId = (await http('POST', '/api/characters', { name, class: 'warrior' }, token)).id;
  } else charId = chars[0].id;

  const ws = new WebSocket(WS);
  const snaps = [];
  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token, character: charId, clientSeed: '', timerWire: 2 })));
  ws.on('message', d => {
    try {
      const m = JSON.parse(d.toString());
      if (m.t === 'snap') snaps.push(m);
    } catch (e) {}
  });

  // Wait for connection + settle
  await sleep(3000);
  const startIdx = snaps.length;
  console.log('Standing still, capturing 4 seconds...');
  await sleep(4000);
  const window = snaps.slice(startIdx);

  // --- Analyze tick/time ---
  console.log(`\ncaptured ${window.length} snaps in 4s (rate=${(window.length/4).toFixed(1)} Hz)`);
  const ticks = window.map(s => s.tick);
  const times = window.map(s => s.time);
  console.log(`first tick=${ticks[0]} last tick=${ticks[ticks.length-1]}`);
  let tickGaps = [];
  for (let i = 1; i < ticks.length; i++) tickGaps.push(ticks[i] - ticks[i-1]);
  console.log(`tick gaps: ${[...new Set(tickGaps)].join(',')}`);

  let timeGaps = [];
  for (let i = 1; i < times.length; i++) timeGaps.push(+(times[i] - times[i-1]).toFixed(4));
  console.log(`time gaps: ${[...new Set(timeGaps)].join(',')}`);

  // --- Analyze self position stability ---
  const selfs = window.map(s => typeof s.self === 'string' ? JSON.parse(s.self) : s.self).filter(Boolean);
  if (selfs.length > 0) {
    const x = selfs.map(s => s.x), y = selfs.map(s => s.y), z = selfs.map(s => s.z);
    const f = selfs.map(s => s.f);
    const xRange = Math.max(...x) - Math.min(...x);
    const yRange = Math.max(...y) - Math.min(...y);
    const zRange = Math.max(...z) - Math.min(...z);
    const fRange = Math.max(...f) - Math.min(...f);
    console.log(`\nself x: ${x[0]}..${x[x.length-1]} range=${xRange.toFixed(6)}`);
    console.log(`self y: ${y[0]}..${y[y.length-1]} range=${yRange.toFixed(6)}`);
    console.log(`self z: ${z[0]}..${z[z.length-1]} range=${zRange.toFixed(6)}`);
    console.log(`self facing: ${f[0]}..${f[f.length-1]} range=${fRange.toFixed(6)}`);
    // show first 5 x values with full precision
    console.log(`first 5 x: ${x.slice(0,5).join(', ')}`);
    console.log(`first 5 y: ${y.slice(0,5).join(', ')}`);
  }

  // --- Analyze raw self JSON field set ---
  if (selfs.length > 0) {
    const keys = Object.keys(selfs[selfs.length - 1]);
    console.log(`\nself keys (${keys.length}): ${keys.join(', ')}`);
  }

  ws.close();
  process.exit(0);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
