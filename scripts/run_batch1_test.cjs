// Convenience script: register 2 fresh accounts + characters, then run test_stage_d_batch1.cjs
// Usage: node scripts/run_batch1_test.cjs
const { spawn } = require('child_process');
const BASE = process.env.SERVER_URL || 'http://localhost:8787';

async function http(method, path, body, token) {
  const r = await fetch(BASE + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return r.json().catch(() => ({}));
}

(async () => {
  const suffix = Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
  const alnum = suffix.replace(/[^a-zA-Z0-9]/g, '');

  console.log('Registering accounts...');
  const regA = await http('POST', '/api/register', { username: 'b1a_' + suffix, password: 'testpass456' });
  const regB = await http('POST', '/api/register', { username: 'b1b_' + suffix, password: 'testpass456' });
  if (!regA.token || !regB.token) { console.error('FAIL: register'); process.exit(1); }
  console.log('OK: accounts registered');

  console.log('Creating characters...');
  const ca = await http('POST', '/api/characters', { name: 'Wa' + alnum.slice(0, 5) + 'X', class: 'warrior' }, regA.token);
  const cb = await http('POST', '/api/characters', { name: 'Mb' + alnum.slice(0, 5) + 'X', class: 'mage' }, regB.token);
  if (!ca.id || !cb.id) { console.error('FAIL: create character'); process.exit(1); }
  console.log('OK: characters created');

  console.log('Running batch 1 tests...\n');
  const child = spawn('node', [
    require('path').join(__dirname, 'test_stage_d_batch1.cjs'),
    regA.token, String(ca.id), regB.token, String(cb.id),
  ], { stdio: 'inherit' });
  child.on('close', code => process.exit(code));
})().catch(e => { console.error('ERR', e.message); process.exit(2); });
