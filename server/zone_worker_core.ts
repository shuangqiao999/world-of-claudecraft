// Per-zone entity processing for the zone-sharding worker pool.
// Each worker receives a batch of entities for one zone and computes
// aggro proximity scans and aura tick detection.  Mob combat, movement,
// and AI decision execution remain on the main thread (where they have
// access to the full `ctx` seam for dealDamage, threat, etc.).
//
// RNG: each zone batch includes a deterministic seed.  The worker's
// mulberry32 is byte-identical to the sim's `src/sim/rng.ts`.

import { Rng } from '../src/sim/rng';

// ---------- Types ----------

export interface Vec3 { x: number; y: number; z: number; }

export interface ZoneEntitySlice {
  id: number;
  kind: 'mob' | 'npc' | 'object';
  templateId: string;
  pos: Vec3;
  dead: boolean;
  hp: number; maxHp: number;
  resource: number; maxResource: number;
  /** Mob fields (null for non-mobs) */
  mob?: {
    aiState: string;
    aggroTargetId: number | null;
    ownerId: number | null;
    auras: ZoneAuraSlice[];
  };
  /** NPC fields */
  npc?: { auras: ZoneAuraSlice[] };
  /** Object fields */
  obj?: { remaining: number; state: string };
}

export interface ZoneAuraSlice {
  id: string;
  kind: string;
  remaining: number;
  tickTimer: number;
  tickInterval: number;
  value: number;
  school?: string;
  sourceId: number;
}

export interface ZonePlayerCell {
  id: number; x: number; z: number; dead: boolean; stealthed: boolean; level: number;
}

export interface ZoneBatch {
  zoneId: string;
  entities: ZoneEntitySlice[];
  playerCells: ZonePlayerCell[];
  tick: number;
  dt: number;
  rngSeed: number;
}

export interface ZoneEntityMutation {
  id: number;
  hp: number;
  resource: number;
  dead: boolean;
  pos?: Vec3;
  auras: ZoneAuraMutation[];
}

export interface ZoneAuraMutation {
  kind: 'expire' | 'tick';
  index: number;
  tickValue?: number; // dot/hot tick amount (0 = purely timer update)
  sourceId?: number;
  targetId?: number;
}

export interface ZoneResult {
  zoneId: string;
  mutations: ZoneEntityMutation[];
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

// ---------- Mob processing ----------

function processMob(
  e: ZoneEntitySlice,
  batch: ZoneBatch,
  rng: Rng,
): ZoneEntityMutation {
  const mut: ZoneEntityMutation = {
    id: e.id, hp: e.hp, resource: e.resource, dead: e.dead, auras: [],
  };

  if (e.dead) return mut;

  const m = e.mob;
  if (!m) return mut;

  // Idle mob: aggro proximity scan
  if (m.aiState === 'idle' && !m.ownerId) {
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
      (batch as any)._aggroCandidates = (batch as any)._aggroCandidates || [];
      (batch as any)._aggroCandidates.push([e.id, closestId] as [number, number]);
    }
  }

  // Aura processing: detect expirations and tick thresholds.
  // The main thread's updateAuras() is the authoritative duration keeper.
  // We report only what the worker can detect from the consumed snapshot.
  processAuras(e, mut, batch.dt);

  return mut;
}

// ---------- Aura processing: expiry detection only ----------
// updateAuras() on the main thread handles all duration decrements, DoT/HoT
// tick application, and fade events.  The worker detects what WILL expire
// or tick this frame so the main thread can apply the correct index-based
// removals/tick values without a second scan.

function processAuras(
  e: ZoneEntitySlice,
  mut: ZoneEntityMutation,
  dt: number,
): void {
  const auras = e.kind === 'mob' ? e.mob?.auras : e.kind === 'npc' ? e.npc?.auras : null;
  if (!auras || auras.length === 0) return;

  for (let i = 0; i < auras.length; i++) {
    const a = auras[i];
    const newRemaining = a.remaining - dt;

    if (newRemaining <= 0) {
      mut.auras.push({ kind: 'expire', index: i });
      continue;
    }

    if (a.tickInterval > 0) {
      const newTickTimer = a.tickTimer - dt;
      if (newTickTimer <= 0 && (a.kind === 'dot' || a.kind === 'hot')) {
        mut.auras.push({
          kind: 'tick',
          index: i,
          tickValue: a.value,
          sourceId: a.sourceId,
          targetId: e.id,
        });
      }
    }
  }
}

// ---------- NPC + Object processing ----------

function processNpc(
  e: ZoneEntitySlice,
  batch: ZoneBatch,
): ZoneEntityMutation {
  const mut: ZoneEntityMutation = {
    id: e.id, hp: e.hp, resource: e.resource, dead: e.dead, auras: [],
  };
  if (e.dead) return mut;
  processAuras(e, mut, batch.dt);
  return mut;
}

function processObject(
  e: ZoneEntitySlice,
  _batch: ZoneBatch,
): ZoneEntityMutation {
  // Object respawn timers are decremented by the main thread's per-entity loop.
  // The worker only handles mobs and NPCs.
  return { id: e.id, hp: e.hp, resource: e.resource, dead: e.dead, auras: [] };
}

// ---------- Main entry point ----------

export function computeZoneBatch(batch: ZoneBatch): ZoneResult {
  const rng = new Rng(batch.rngSeed);
  const mutations: ZoneEntityMutation[] = [];

  // Process entities in fixed order (by id) for determinism
  const sorted = batch.entities.slice().sort((a, b) => a.id - b.id);

  for (const e of sorted) {
    let mut: ZoneEntityMutation;

    switch (e.kind) {
      case 'mob':
        mut = processMob(e, batch, rng);
        break;
      case 'npc':
        mut = processNpc(e, batch);
        break;
      case 'object':
        mut = processObject(e, batch);
        break;
      default:
        mut = { id: e.id, hp: e.hp, resource: e.resource, dead: e.dead, auras: [] };
    }

    mutations.push(mut);
  }

  // Collect aggro candidates
  const aggroCandidates: [number, number][] = (batch as any)._aggroCandidates || [];

  return { zoneId: batch.zoneId, mutations, aggroCandidates };
}
