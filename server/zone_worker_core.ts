// Per-zone entity processing for the zone-sharding worker pool.
// Each worker receives a batch of entities for one zone and computes
// aggro proximity scans.  Mob combat, movement, AI decision execution,
// and ALL aura lifecycle (durations, ticks, expirations, fade events,
// stat recalc) remain on the main thread.

// ---------- Types ----------

export interface Vec3 { x: number; y: number; z: number; }

export interface ZoneEntitySlice {
  id: number;
  kind: 'mob' | 'npc' | 'object';
  templateId: string;
  pos: Vec3;
  dead: boolean;
  mob?: {
    aiState: string;
    ownerId: number | null;
  };
}

export interface ZonePlayerCell {
  id: number; x: number; z: number; dead: boolean; stealthed: boolean; level: number;
}

export interface ZoneBatch {
  zoneId: string;
  entities: ZoneEntitySlice[];
  playerCells: ZonePlayerCell[];
  dt: number;
}

export interface ZoneEntityMutation {
  id: number;
}

export interface ZoneResult {
  zoneId: string;
  aggroCandidates: [number, number][];
}

// ---------- Constants ----------

const MAX_AGGRO_RADIUS = 20;

// ---------- Helpers ----------

function dist2dSq(a: Vec3, b: { x: number; z: number }): number {
  const dx = a.x - b.x;
  const dz = a.z - b.z;
  return dx * dx + dz * dz;
}

// ---------- Computation ----------

export function computeZoneBatch(batch: ZoneBatch): ZoneResult {
  const aggroCandidates: [number, number][] = [];

  for (const e of batch.entities) {
    if (e.kind !== 'mob' || e.dead) continue;
    const m = e.mob;
    if (!m || m.aiState !== 'idle' || m.ownerId) continue;

    let closestDistSq = Infinity;
    let closestId = -1;
    for (const pc of batch.playerCells) {
      if (pc.dead || pc.stealthed) continue;
      const d2 = dist2dSq(e.pos, pc);
      if (d2 < MAX_AGGRO_RADIUS * MAX_AGGRO_RADIUS && d2 < closestDistSq) {
        closestDistSq = d2;
        closestId = pc.id;
      }
    }
    if (closestId > 0) {
      aggroCandidates.push([e.id, closestId]);
    }
  }

  return { zoneId: batch.zoneId, aggroCandidates };
}
