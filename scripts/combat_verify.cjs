// Minimal combat verification: teleport onto a mob, attack, watch for damage.
const WebSocket = require('ws');
const BASE = 'http://localhost:8787';
const WS = BASE.replace(/^http/, 'ws') + '/';
const USER = 'cb' + Date.now().toString(36).slice(-4);
const PASS = 'testpass';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function http(m, p, b, t) { const r = await fetch(BASE + p, { method: m, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: b ? JSON.stringify(b) : undefined }); return r.json().catch(() => ({})); }

(async () => {
  let reg = await http('POST', '/api/register', { username: USER, password: PASS, email: USER + '@t.com' });
  if (!reg.token) reg = await http('POST', '/api/login', { username: USER, password: PASS });
  const name = 'B' + Date.now().toString(36).replace(/[0-9]/g, 'a');
  const ca = await http('POST', '/api/characters', { name, class: 'warrior' }, reg.token);
  const ws = new WebSocket(WS);
  let pid = null, self = null, seq = 0;
  const entState = {};
  const combatEvents = [];

  ws.on('open', () => ws.send(JSON.stringify({ t: 'auth-world-5', token: reg.token, character: ca.id, clientSeed: '', timerWire: 2 })));
  ws.on('message', (d) => {
    try {
      const m = JSON.parse(d.toString());
      if (m.t === 'hello') { pid = m.pid; console.log('connected pid=' + pid); start(); }
      else if (m.t === 'snap') {
        if (m.self !== undefined) self = typeof m.self === 'string' ? JSON.parse(m.self) : m.self;
        if (Array.isArray(m.ents)) for (const rec of m.ents) { const r = typeof rec === 'string' ? JSON.parse(rec) : rec; if (r.id !== undefined) { let s = entState[r.id]; if (!s) { s = {}; entState[r.id] = s; } for (const k in r) s[k] = r[k]; } }
      } else if (m.t === 'events') {
        const arr = Array.isArray(m.list) ? m.list : (m.list ? [m.list] : []);
        for (const ev of arr) if (ev.type === 'damage' || ev.type === 'heal2' || ev.type === 'death') combatEvents.push(ev);
      }
    } catch (e) {}
  });
  function cmd(name, args) { ws.send(JSON.stringify({ t: 'cmd', cmd: name, ...args })); }

  async function start() {
    await sleep(1500);
    // teleport to wolf camp
    cmd('dev_teleport', { x: 24, z: 70 });
    await sleep(800);
    let mob = Object.values(entState).filter((e) => e.k === 'mob' && !e.dead);
    console.log(`mobs visible: ${mob.length}`);
    if (mob.length === 0) { console.log('NO MOB — skipping'); process.exit(0); }
    const target = mob.sort((a, b) => ((a.x - self.x) ** 2 + (a.z - self.z) ** 2) - ((b.x - self.x) ** 2 + (b.z - self.z) ** 2))[0];
    const targetId = Object.keys(entState).find((k) => entState[k] === target);
    console.log(`target id=${targetId} hp=${target.hp}/${target.mhp}`);
    cmd('target', { id: Number(targetId) });
    cmd('attack');
    // re-teleport onto the mob every 250ms to pin it in melee range despite wandering
    const t0 = Date.now();
    const hpBefore = target.hp;
    while (Date.now() - t0 < 6000) {
      const t = entState[targetId];
      if (t) cmd('dev_teleport', { x: t.x, z: t.z });
      await sleep(250);
    }
    const t2 = entState[targetId];
    console.log(`combat events: ${JSON.stringify(combatEvents.map((e) => e.type))}`);
    console.log(`mob hp: ${hpBefore} -> ${t2 ? t2.hp : '?'}${t2 && t2.dead ? ' DEAD' : ''}`);
    console.log(combatEvents.length > 0 ? 'RESULT: COMBAT OK' : 'RESULT: COMBAT BROKEN');
    ws.close(); process.exit(combatEvents.length > 0 ? 0 : 1);
  }
  setTimeout(() => { console.log('TIMEOUT'); ws.close(); process.exit(1); }, 30000);
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
