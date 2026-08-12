// Generate the REAL heightmap from the full TS terrain pipeline.
// Run: npx tsx scripts/gen_real_heightmap.mts
import { groundHeight } from '../src/sim/world';
import { WORLD_SEED } from '../src/sim/world_seed';
import * as fs from 'fs';

const GRID = 5;
const R = 50; // ±50yd

const map: Record<string, number[]> = {};
const zTicks: number[] = [];
for (let z = -R; z <= R; z += GRID) zTicks.push(z);

for (let x = -R; x <= R; x += GRID) {
  const row: number[] = [];
  for (let z = -R; z <= R; z += GRID) {
    row.push(+(groundHeight(x, z, WORLD_SEED).toFixed(3)));
  }
  map[String(x)] = row;
}

const json = { seed: WORLD_SEED, grid: GRID, zTicks, points: map };
const out = 'dist-host-moon/moon-server/woc/proto/heightmap.json';
fs.mkdirSync('dist-host-moon/moon-server/woc/proto', { recursive: true });
fs.writeFileSync(out, JSON.stringify(json));

console.log(`heightmap written to ${out}`);
console.log(`origin (0,0): ${groundHeight(0, 0, WORLD_SEED).toFixed(3)}`);
console.log(`(10,0): ${groundHeight(10, 0, WORLD_SEED).toFixed(3)}`);
console.log(`(0,10): ${groundHeight(0, 10, WORLD_SEED).toFixed(3)}`);
console.log(`(30,0): ${groundHeight(30, 0, WORLD_SEED).toFixed(3)}`);
console.log(`(0,30): ${groundHeight(0, 30, WORLD_SEED).toFixed(3)}`);
console.log(`(-30,0): ${groundHeight(-30, 0, WORLD_SEED).toFixed(3)}`);
