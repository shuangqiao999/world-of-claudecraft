// Generate the REAL heightmap from the full TS terrain pipeline, covering the
// ENTIRE overworld (all zone bands, x[-540,540] x z[-180,2420]), so the Moon
// server's ground height matches the client's rendered terrain everywhere.
//
// Run: npx tsx scripts/gen_real_heightmap.mts
//
// Storage: a flat row-major array of INTEGER CENTIMETERS (heights rounded to
// the nearest cm), so a 1081 x 2601 grid stays a compact ~17 MB and the Lua
// side does one integer table lookup + bilinear blend, then /100 back to yards.
import { WORLD_MAX_X, WORLD_MAX_Z, WORLD_MIN_X, WORLD_MIN_Z } from '../src/sim/data';
import { groundHeight } from '../src/sim/world';
import { WORLD_SEED } from '../src/sim/world_seed';
import * as fs from 'fs';

const GRID = 1;
const xMin = WORLD_MIN_X;
const xMax = WORLD_MAX_X;
const zMin = WORLD_MIN_Z;
const zMax = WORLD_MAX_Z;

const xCount = Math.floor((xMax - xMin) / GRID) + 1;
const zCount = Math.floor((zMax - zMin) / GRID) + 1;

const heights: number[] = new Array(xCount * zCount);
for (let ix = 0; ix < xCount; ix++) {
  const x = xMin + ix * GRID;
  for (let iz = 0; iz < zCount; iz++) {
    const z = zMin + iz * GRID;
    heights[ix * zCount + iz] = Math.round(groundHeight(x, z, WORLD_SEED) * 100);
  }
}

const json = {
  seed: WORLD_SEED,
  grid: GRID,
  cm: true,
  xMin,
  xMax,
  zMin,
  zMax,
  xCount,
  zCount,
  heights,
};

const out = 'dist-host-moon/moon-server/woc/proto/heightmap.json';
fs.mkdirSync('dist-host-moon/moon-server/woc/proto', { recursive: true });
fs.writeFileSync(out, JSON.stringify(json));

console.log(`heightmap written to ${out}`);
console.log(`world x[${xMin}..${xMax}] z[${zMin}..${zMax}], grid ${GRID}, ${xCount}x${zCount} = ${heights.length} points`);
console.log(`origin (0,0): ${(heights[(0 - xMin) * zCount + (0 - zMin)] / 100).toFixed(2)} yd`);
console.log(`(63,71): ${groundHeight(63, 71, WORLD_SEED).toFixed(2)}`);
console.log(`(-88,82): ${groundHeight(-88, 82, WORLD_SEED).toFixed(2)}`);
console.log(`(0,300) mirefen hub: ${groundHeight(0, 300, WORLD_SEED).toFixed(2)}`);
console.log(`(0,660) peaks hub: ${groundHeight(0, 660, WORLD_SEED).toFixed(2)}`);
console.log(`(404,1900) drakelands hub: ${groundHeight(404, 1900, WORLD_SEED).toFixed(2)}`);
console.log(`(-360,2072) amberfall hub: ${groundHeight(-360, 2072, WORLD_SEED).toFixed(2)}`);
