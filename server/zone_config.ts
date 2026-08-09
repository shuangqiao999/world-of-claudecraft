// Zone metadata, entity-to-zone mapping, and border-margin detection for
// the zone-sharding parallel tick pipeline.  Each open-world zone is a
// rectangular region defined by [xMin,xMax) × [zMin,zMax); instanced
// content (dungeons, arena, delves, rifts) lives far east and is handled
// separately.

// Re-exported so callers don't need the sim import just for zone lookups.
export { zoneAt } from '../src/sim/data';

export interface ZoneExtent {
  id: string;
  xMin: number;
  xMax: number;
  zMin: number;
  zMax: number;
}

// All 14 open-world zones with their bounding rectangles.
// xMin/xMax default to the original strip [-180,180] when undefined.
const STRIP_MIN_X = -180;
const STRIP_MAX_X = 180;

export const OPEN_WORLD_ZONES: ZoneExtent[] = [
  { id: 'eastbrook_vale',  xMin: -180, xMax: 180, zMin: -180, zMax: 180 },
  { id: 'mirefen_marsh',   xMin: -180, xMax: 180, zMin: 180,  zMax: 540 },
  { id: 'thornpeak_heights', xMin: -180, xMax: 180, zMin: 540, zMax: 900 },
  { id: 'veiled_hollow',   xMin: -180, xMax: 180, zMin: 900, zMax: 1440 },
  { id: 'frostveil',       xMin: -180, xMax: 180, zMin: 1440, zMax: 1960 },
  { id: 'willowfen',       xMin: -540, xMax: -180, zMin: 180, zMax: 700 },
  { id: 'palmreach',       xMin: -540, xMax: -180, zMin: 700, zMax: 1260 },
  { id: 'nightbloom',      xMin: -540, xMax: -180, zMin: 1260, zMax: 1820 },
  { id: 'amberfall',       xMin: -540, xMax: -180, zMin: 1820, zMax: 2380 },
  { id: 'farshore_isle',   xMin: 180, xMax: 540,  zMin: -180, zMax: 180 },
  { id: 'galecrest',       xMin: 180, xMax: 540,  zMin: 180,  zMax: 700 },
  { id: 'evergarden',      xMin: 180, xMax: 540,  zMin: 700,  zMax: 1260 },
  { id: 'wraithwood',      xMin: 180, xMax: 540,  zMin: 1260, zMax: 1820 },
  { id: 'drakelands',      xMin: 180, xMax: 540,  zMin: 1820, zMax: 2420 },
];

// Entities within this margin of ANY zone boundary stay on the main thread.
// 50 yards covers the worst-case AoE (8yd) + leash (45yd) + projectile (~100yd
// with travel) — projectile caster and target are both live by the time the
// bolt resolves, and an intra-zone bolt never crosses a margin.  A mob pulled
// to the margin stays on main after the next rebucket.
export const BORDER_MARGIN_YD = 50;

const zoneLookup = new Map<string, ZoneExtent>();
for (const z of OPEN_WORLD_ZONES) zoneLookup.set(z.id, z);

export function zoneExtentById(id: string): ZoneExtent | undefined {
  return zoneLookup.get(id);
}

/** Which open-world zone does (x,z) fall into? null if in instance band or void. */
export function zoneIdFor(x: number, z: number): string | null {
  for (const z of OPEN_WORLD_ZONES) {
    if (z >= z.zMin && z < z.zMax && x >= z.xMin && x < z.xMax) return z.id;
  }
  return null;
}

/** True when (x,z) is within BORDER_MARGIN_YD of ANY zone boundary. */
export function isBorderPosition(x: number, z: number): boolean {
  for (const z of OPEN_WORLD_ZONES) {
    const dxMin = x - (z.xMin + BORDER_MARGIN_YD);
    const dxMax = (z.xMax - BORDER_MARGIN_YD) - x;
    const dzMin = z - (z.zMin + BORDER_MARGIN_YD);
    const dzMax = (z.zMax - BORDER_MARGIN_YD) - z;
    if (dxMin <= 0 || dxMax <= 0 || dzMin <= 0 || dzMax <= 0) return true;
  }
  return false;
}

/** Group entity ids by their open-world zone.  Entities in instances, voids,
 *  or border margins are assigned to the special key `null`. */
export function groupEntitiesByZone(
  entities: Iterable<{ id: number; pos: { x: number; z: number } }>,
): { zoneIds: string[]; groups: Map<string | null, number[]> } {
  const groups = new Map<string | null, number[]>();

  for (const e of entities) {
    let key: string | null = null;
    for (const z of OPEN_WORLD_ZONES) {
      if (
        e.pos.z >= z.zMin &&
        e.pos.z < z.zMax &&
        e.pos.x >= z.xMin &&
        e.pos.x < z.xMax
      ) {
        // Check border margin — if near boundary, keep on main thread.
        const inMargin =
          e.pos.x - (z.xMin + BORDER_MARGIN_YD) <= 0 ||
          (z.xMax - BORDER_MARGIN_YD) - e.pos.x <= 0 ||
          e.pos.z - (z.zMin + BORDER_MARGIN_YD) <= 0 ||
          (z.zMax - BORDER_MARGIN_YD) - e.pos.z <= 0;
        key = inMargin ? null : z.id;
        break;
      }
    }
    // null key = border margin, instance band, or void → main thread
    let arr = groups.get(key);
    if (!arr) { arr = []; groups.set(key, arr); }
    arr.push(e.id);
  }

  const zoneIds: string[] = [];
  for (const k of groups.keys()) {
    if (k !== null) zoneIds.push(k);
  }

  return { zoneIds, groups };
}
