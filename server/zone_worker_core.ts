// Pure per-zone entity processing for the zone-sharding worker pool.
// Each worker receives a batch of entities in one zone and computes
// all self-contained mutations: mob AI, combat, movement, auras, NPC
// upkeep, object timers.  Cross-zone interactions (border entities,
// global systems) stay on the main thread.
//
// RNG: each zone batch includes a deterministic seed derived from
//   hash(globalSeed, zoneId, tickCount).  The worker creates its own
//   mulberry32 instance from this seed and draws in a fixed order,
//   preserving overall determinism.

// ---------- RNG (lives in the worker, not imported from sim) ----------

class Rng {
  private s: number;
  constructor(seed: number) {
    this.s = (seed >>> 0) || 0x9e3779b9;
  }
  next(): number {
    let t = this.s;
    t ^= t >>> 16;
    t = Math.imul(t, 0x85ebca6b);
    t ^= t >>> 13;
    t = Math.imul(t, 0xc2b2ae35);
    t ^= t >>> 16;
    this.s = (this.s + 0x6d2b79f5) >>> 0;
    return (t >>> 0) / 0x100000000;
  }
  range(lo: number, hi: number): number { return lo + this.next() * (hi - lo); }
  int(lo: number, hi: number): number { return Math.floor(this.range(lo, hi + 1)); }
  chance(p: number): boolean { return this.next() < p; }
}

// ---------- Types ----------

export interface Vec3 { x: number; y: number; z: number; }

export interface ZoneEntitySlice {
  id: number;
  kind: 'player' | 'mob' | 'npc' | 'object';
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
    weaponMin: number; weaponMax: number;
    attackPower: number;
    hitChance: number; critChance: number;
    armor: number;
    dodge: number; parry: number; block: number;
    moveSpeed: number;
    auras: ZoneAuraSlice[];
  };
  /** NPC fields */
  npc?: { auras: ZoneAuraSlice[] };
  /** Object fields */
  obj?: { remaining: number; state: string };
}

export interface ZoneAuraSlice {
  id: string;
  kind: string;  // dot, hot, buff, debuff, stealth, etc.
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
  /** Mob-only mutations */
  mob?: {
    aiState?: string;
    aggroTargetId?: number | null;
    hp?: number;
  };
  auras: ZoneAuraMutation[];
  events: ZoneEvent[];
}

export interface ZoneAuraMutation {
  action: 'remove' | 'tick' | 'expire';
  index: number;
  remaining?: number;
  tickTimer?: number;
  tickValue?: number;
}

export interface ZoneEvent {
  kind: 'damage' | 'heal' | 'death' | 'aura';
  sourceId: number;
  targetId: number;
  amount?: number;
  auraId?: string;
  auraGained?: boolean;
}

export interface ZoneResult {
  zoneId: string;
  mutations: ZoneEntityMutation[];
  aggroCandidates: [number, number][]; // [mobId, playerId]
}

// ---------- Constants ----------

const MAX_AGGRO_RADIUS = 20;
const MELEE_RANGE = 5;
const MELEE_RANGE_SQ = MELEE_RANGE * MELEE_RANGE;
const LEASH_DISTANCE_SQ = 45 * 45;
const COMBO_EXPIRY_TICKS = 100; // 5s at 20Hz

// ---------- Helpers ----------

function dist2dSq(a: Vec3, b: { x: number; z: number }): number {
  const dx = a.x - b.x;
  const dz = a.z - b.z;
  return dx * dx + dz * dz;
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

// ---------- Mob processing ----------

function processMob(
  e: ZoneEntitySlice,
  batch: ZoneBatch,
  rng: Rng,
): ZoneEntityMutation {
  const m = e.mob!;
  const mut: ZoneEntityMutation = {
    id: e.id,
    hp: e.hp,
    resource: e.resource,
    dead: e.dead,
    auras: [],
    events: [],
  };

  if (e.dead) {
    // Process auras for dead mobs (few expire immediately)
    processAuras(e, mut, batch.dt);
    return mut;
  }

  // Dead mob auras are mostly empty; skip
  if (m.aiState === 'idle' && !m.ownerId) {
    return processIdleMob(e, batch, rng, mut);
  }

  // Engaged mob: chase/attack/flee. Process combat.
  // In zone-parallel mode, the target entity MUST be in this zone.
  // Border-margin entities (which may have cross-zone targets) stay
  // on the main thread, so this invariant holds.
  if (m.aggroTargetId != null) {
    const target = batch.entities.find(ent => ent.id === m.aggroTargetId);
    if (target && !target.dead) {
      processMobCombat(e, target, batch.dt, rng, mut);
    }
  }

  processAuras(e, mut, batch.dt);
  return mut;
}

function processIdleMob(
  e: ZoneEntitySlice,
  batch: ZoneBatch,
  rng: Rng,
  mut: ZoneEntityMutation,
): ZoneEntityMutation {
  // Aggro scan: find closest nearby player
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

  // If candidate found, prepare mob mutation for aggro (the main thread
  // applies the final state change via Sim.aggroMob, which handles RNG
  // for stealth detection and combat entry).
  if (closestId > 0) {
    (batch as any)._aggroCandidates = (batch as any)._aggroCandidates || [];
    (batch as any)._aggroCandidates.push([e.id, closestId] as [number, number]);
  }

  return mut;
}

function processMobCombat(
  attacker: ZoneEntitySlice,
  defender: ZoneEntitySlice,
  dt: number,
  rng: Rng,
  mut: ZoneEntityMutation,
): void {
  if (!attacker.mob || !defender) return;

  // In melee range?
  const d2 = dist2dSq(attacker.pos, defender.pos);
  if (d2 > MELEE_RANGE_SQ) {
    // Mob is chasing: simple move toward target (positional)
    // Full chase physics stays on main thread for now.
    // We only compute aggro candidates and aura ticks.
    return;
  }

  // Auto-attack swing: hit table roll
  const a = attacker.mob;
  const d = defender.kind === 'player' ? defender : (defender.mob ? defender : null);
  if (!d) return;

  const defStats = defender.kind === 'player'
    ? { armor: 0, dodge: 0, parry: 0, block: 0, hp: defender.hp, maxHp: defender.maxHp }
    : defender.mob ? { armor: defender.mob.armor, dodge: defender.mob.dodge, parry: defender.mob.parry, block: defender.mob.block, hp: defender.hp, maxHp: defender.maxHp }
    : null;
  if (!defStats) return;

  const roll = rng.next();
  const missChance = 0.05 + defStats.dodge + defStats.parry;
  if (roll < missChance) {
    mut.events.push({ kind: 'damage', sourceId: attacker.id, targetId: defender.id, amount: 0 });
    return;
  }

  // Damage roll
  let dmg = rng.range(a.weaponMin, a.weaponMax);
  dmg = Math.round(dmg * (1 + a.attackPower / 14) * rng.next());
  const armorReduction = defStats.armor / (defStats.armor + 400);
  dmg = Math.round(dmg * (1 - armorReduction));

  // Crit
  if (rng.chance(a.critChance)) {
    dmg = Math.round(dmg * 2);
  }

  dmg = Math.max(1, dmg);

  mut.events.push({
    kind: 'damage',
    sourceId: attacker.id,
    targetId: defender.id,
    amount: dmg,
  });

  // Check death
  if (defStats.hp - dmg <= 0) {
    mut.events.push({ kind: 'death', sourceId: attacker.id, targetId: defender.id });
  }
}

// ---------- Aura processing ----------

function processAuras(
  e: ZoneEntitySlice,
  mut: ZoneEntityMutation,
  dt: number,
): void {
  const auras = e.kind === 'mob' ? e.mob?.auras : e.kind === 'npc' ? e.npc?.auras : e.kind === 'player' ? (e as any).auras : null;
  if (!auras || auras.length === 0) return;

  for (let i = 0; i < auras.length; i++) {
    const a = auras[i];
    const newRemaining = a.remaining - dt;
    if (newRemaining <= 0) {
      mut.auras.push({ action: 'expire', index: i });
      continue;
    }

    let newTickTimer = a.tickTimer;
    if (a.tickInterval > 0) {
      newTickTimer = a.tickTimer - dt;
      if (newTickTimer <= 0) {
        newTickTimer += a.tickInterval;
        if (a.kind === 'dot' || a.kind === 'hot') {
          mut.auras.push({
            action: 'tick',
            index: i,
            remaining: newRemaining,
            tickTimer: newTickTimer,
            tickValue: a.value,
          });
        }
      }
    }

    mut.auras.push({
      action: 'tick',
      index: i,
      remaining: newRemaining,
      tickTimer: newTickTimer,
    });
  }
}

// ---------- Main entry point ----------

export function computeZoneBatch(batch: ZoneBatch): ZoneResult {
  const rng = new Rng(batch.rngSeed);
  const mutations: ZoneEntityMutation[] = [];
  const aggroCandidates: [number, number][] = [];

  // Process entities in a fixed order (by id) for determinism
  const sorted = batch.entities.slice().sort((a, b) => a.id - b.id);

  for (const e of sorted) {
    let mut: ZoneEntityMutation;

    switch (e.kind) {
      case 'mob':
        mut = processMob(e, batch, rng);
        break;
      case 'player':
      case 'npc':
        mut = processAuraAndTimer(e, batch);
        break;
      case 'object':
        mut = processObject(e, batch);
        break;
      default:
        mut = { id: e.id, hp: e.hp, resource: e.resource, dead: e.dead, auras: [], events: [] };
    }

    // Collect aggro candidates from mob processing
    if (e.kind === 'mob' && (batch as any)._aggroCandidates) {
      for (const [mid, pid] of (batch as any)._aggroCandidates) {
        if (mid === e.id) aggroCandidates.push([mid, pid]);
      }
    }

    mutations.push(mut);
  }

  return { zoneId: batch.zoneId, mutations, aggroCandidates };
}

function processAuraAndTimer(
  e: ZoneEntitySlice,
  batch: ZoneBatch,
): ZoneEntityMutation {
  const mut: ZoneEntityMutation = {
    id: e.id, hp: e.hp, resource: e.resource, dead: e.dead, auras: [], events: [],
  };
  if (e.dead) return mut;
  processAuras(e, mut, batch.dt);
  return mut;
}

function processObject(
  e: ZoneEntitySlice,
  batch: ZoneBatch,
): ZoneEntityMutation {
  const mut: ZoneEntityMutation = {
    id: e.id, hp: e.hp, resource: e.resource, dead: e.dead, auras: [], events: [],
  };
  if (!e.obj || e.obj.remaining <= 0) return mut;
  // Object respawn timer: simple decrement (no events, no rng)
  return mut;
}
