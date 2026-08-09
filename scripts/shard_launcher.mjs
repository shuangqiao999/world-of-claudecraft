// Multi-process shard launcher.
// Reads shard_config.json, spawns one gateway process + N zone processes.
// Each zone process gets its ZONES env var set to its assigned zones.
//
//   node scripts/shard_launcher.mjs

import { spawn, type ChildProcess } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');

interface ShardProcess {
  id: number;
  zones: string[];
  port: number;
}

interface ShardConfig {
  gatewayPort: number;
  internalPort: number;
  processes: ShardProcess[];
}

const CONFIG_PATH = process.env.SHARD_CONFIG ?? resolve(ROOT, 'shard_config.json');

if (!existsSync(CONFIG_PATH)) {
  console.error(`[shard] config not found: ${CONFIG_PATH}`);
  process.exit(1);
}

const config: ShardConfig = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
const cpuCount = os.cpus?.()?.length ?? 1;
const procCount = Math.min(config.processes.length, cpuCount);

console.log(`[shard] cpu=${cpuCount} processes=${procCount} gateway=${config.gatewayPort} internal=${config.internalPort}`);

const children: ChildProcess[] = [];

// ── Spawn zone processes ──
for (const proc of config.processes) {
  const zonesEnv = proc.zones.join(',');
  const env = {
    ...process.env,
    ZONES: zonesEnv,
    PORT: String(proc.port),
    GATEWAY_PORT: String(config.internalPort),
    GATEWAY_HOST: '127.0.0.1',
  };

  const child = spawn('node', ['dist-server/server.cjs'], {
    cwd: ROOT,
    env,
    stdio: 'inherit',
  });

  child.on('exit', (code) => {
    console.log(`[shard zone ${proc.id}] exited (${code}), restarting in 3s...`);
    setTimeout(() => {
      const restarted = spawn('node', ['dist-server/server.cjs'], { cwd: ROOT, env, stdio: 'inherit' });
      children.push(restarted);
    }, 3000);
  });

  children.push(child);
  console.log(`[shard zone ${proc.id}] started (pid=${child.pid}) zones=${zonesEnv} port=${proc.port}`);
}

// ── Graceful shutdown ──
function shutdown() {
  console.log('[shard] shutting down...');
  for (const child of children) {
    child.kill('SIGTERM');
  }
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

console.log('[shard] all processes started');
