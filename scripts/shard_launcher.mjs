// Multi-process shard launcher with adaptive zone allocation.
//
// TWO MODES (detected automatically):
//
//   Manual — a `processes` array exists in shard_config.json.
//     Zones are assigned exactly as listed. cpuCount only caps the
//     number of spawned processes (useful for A/B or dedicated hosts).
//
//   Auto — no `processes` array (or SHARD_AUTO=1).
//     Detects cpuCount, computes an optimal zone-to-process split, and
//     launches all processes.  Gateway starts on port 8787; zone
//     processes start on 9001+.  Zone strings are the canonical 14
//     open-world zone ids.
//
//     SHARD_MIN_PROCESSES=2  SHARD_MAX_PROCESSES=<cpuCount>
//     (env override, default min=2, max=cpuCount, floor=1)
//
//   node scripts/shard_launcher.mjs                # auto mode
//   SHARD_AUTO=0 node scripts/shard_launcher.mjs   # manual mode from config

import { spawn } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');

// ── Canonical open-world zone list (same order as zone_config.ts) ──
const ALL_ZONES = [
  'eastbrook_vale', 'mirefen_marsh', 'thornpeak_heights',
  'veiled_hollow', 'frostveil',
  'willowfen', 'palmreach', 'nightbloom', 'amberfall',
  'farshore_isle', 'galecrest', 'evergarden', 'wraithwood', 'drakelands',
];

const CONFIG_PATH = process.env.SHARD_CONFIG ?? resolve(ROOT, 'shard_config.json');
const cpuCount = os.cpus?.()?.length ?? 1;
const autoMode = process.env.SHARD_AUTO !== '0' || cpuCount > 1;

// ── Resolve config ──
let gatewayPort = parseInt(process.env.GATEWAY_PORT ?? '8787', 10);
let internalPort = parseInt(process.env.INTERNAL_PORT ?? '9000', 10);
let minProcs = parseInt(process.env.SHARD_MIN_PROCESSES ?? '2', 10);
let maxProcs = Math.min(parseInt(process.env.SHARD_MAX_PROCESSES ?? String(cpuCount), 10), cpuCount);
let assigned: { id: number; zones: string[]; port: number }[] = [];

if (existsSync(CONFIG_PATH)) {
  const raw = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
  if (raw.gatewayPort) gatewayPort = raw.gatewayPort;
  if (raw.internalPort) internalPort = raw.internalPort;
  if (raw.minProcesses) minProcs = raw.minProcesses;
  if (raw.maxProcesses) maxProcs = Math.min(raw.maxProcesses, cpuCount);
  if (autoMode && raw.processes?.length) {
    // Manual override exists → use it
    assigned = raw.processes.map((p, i) => ({
      id: p.id ?? i + 1,
      zones: p.zones ?? [],
      port: p.port ?? 9001 + i,
    }));
  }
}

// ── Auto-allocation (when no explicit assignment) ──
if (assigned.length === 0) {
  const procCount = Math.min(Math.max(ALL_ZONES.length, minProcs), maxProcs, ALL_ZONES.length);
  const perProc = Math.ceil(ALL_ZONES.length / procCount);
  for (let i = 0; i < procCount; i++) {
    const start = i * perProc;
    const end = Math.min(start + perProc, ALL_ZONES.length);
    if (start >= ALL_ZONES.length) break;
    assigned.push({
      id: i + 1,
      zones: ALL_ZONES.slice(start, end),
      port: 9001 + i,
    });
  }
}

const procCount = assigned.length;
console.log(`[shard] cpu=${cpuCount} processes=${procCount} gateway=${gatewayPort} internal=${internalPort}`);
for (const p of assigned) {
  console.log(`[shard]   zone ${p.id}: ${p.zones.join(',')}  port=${p.port}`);
}

// ── Spawn zone processes ──
const children = [];

for (const proc of assigned) {
  const env = {
    ...process.env,
    ZONES: proc.zones.join(','),
    PORT: String(proc.port),
    GATEWAY_PORT: String(internalPort),
    GATEWAY_HOST: '127.0.0.1',
  };

  const child = spawn('node', ['dist-server/server.cjs'], {
    cwd: ROOT, env, stdio: 'inherit',
  });

  child.on('exit', (code) => {
    console.log(`[shard zone ${proc.id}] exited (${code}), restarting in 3s...`);
    setTimeout(() => {
      const restarted = spawn('node', ['dist-server/server.cjs'], { cwd: ROOT, env, stdio: 'inherit' });
      children.push(restarted);
    }, 3000);
  });

  children.push(child);
  console.log(`[shard zone ${proc.id}] started (pid=${child.pid}) zones=${env.ZONES}`);
}

// ── Graceful shutdown ──
function shutdown() {
  console.log('[shard] shutting down...');
  for (const child of children) { child.kill('SIGTERM'); }
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

console.log('[shard] all processes started');
