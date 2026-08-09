// Self-only sim tick computations that run in worker threads.
// Pure functions: no SimContext, no RNG, no side effects.
// Each receives flat data and returns flat mutation results.
//
// WORKER RESPONSIBILITIES:
//   - Timer countdowns (cooldowns, GCD, potion CD)
//   - Breath timer tick (live players only)
//   - Mount cast timer
//   - Combo point expiry
//   - Mob aggro proximity pre-scan
//
// MAIN THREAD (NOT parallelized):
//   - updateRegen (hp/resource) — complex eating/drinking state
//   - updateAuras — cross-entity DoT/HoT + fade events
//   - updateBreath — drown pulse (cross-entity)
//   - Movement, triggers, mount transition

// ---------- Common types ----------

export interface Vec3 { x: number; y: number; z: number; }

// ---------- Player slice (data sent to worker: only fields the worker reads) ----------

export interface PlayerSlice {
  id: number;
  dead: boolean;
  hp: number;
  maxHp: number;
  resource: number;
  maxResource: number;
  spirit: number;
  combatTimer: number;
  sitting: boolean;
  gcdRemaining: number;
  potionCooldownUntil: number;
  cooldowns: [number, number][];
  breath: number;
  maxBreath: number;
  fatigueTicks: number;
  breathUsedTicks: number;
  inWater: boolean;
  mountCastRemaining: number;
  mountCastKey: string;
  comboPoints: number;
}

// ---------- Player mutation (result from worker: only applied mutations) ----------

export interface PlayerMutation {
  id: number;
  gcdRemaining: number;
  potionCooldownUntil: number;
  cooldowns: [number, number][];
  breath: number;
  fatigueTicks: number;
  breathUsedTicks: number;
  mountCastRemaining: number;
  mountCastKey: string | null;
  comboPoints: number;
}

// ---------- Mob slice ----------

export interface MobSlice {
  id: number;
  kind: 'mob';
  pos: Vec3;
  dead: boolean;
  ownerId: number | null;
  aiState: string;
  auras: number;
  templateId: string;
}

// ---------- Mob mutation ----------

export interface MobMutation {
  id: number;
  aggroCandidateId: number;
  aggroCandidateDistSq: number;
}

// ---------- Player cells for aggro scan ----------

export interface PlayerCell {
  x: number;
  z: number;
  id: number;
  stealthed: boolean;
  dead: boolean;
  level: number;
}

// ---------- Batch types ----------

export interface PlayerBatch {
  slices: PlayerSlice[];
  tick: number;
  dt: number;
}

export interface MobBatch {
  slices: MobSlice[];
  playerCells: PlayerCell[];
  config: MobConfig;
  tick: number;
  dt: number;
}

export interface MobConfig {
  maxAggroRadius: number;
  maxAggroRadiusSq: number;
}

// ---------- Pure computation functions ----------

const TICK_DT = 1 / 20;
const COMBO_EXPIRY_TICKS = 5 / TICK_DT; // 5s at 20Hz

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

export function computePlayerSelfOnly(batch: PlayerBatch): PlayerMutation[] {
  const out: PlayerMutation[] = [];
  const dt = batch.dt;

  for (const p of batch.slices) {
    const mut: PlayerMutation = {
      id: p.id,
      gcdRemaining: p.gcdRemaining,
      potionCooldownUntil: p.potionCooldownUntil,
      cooldowns: [],
      breath: p.breath,
      fatigueTicks: p.fatigueTicks,
      breathUsedTicks: p.breathUsedTicks,
      mountCastRemaining: p.mountCastRemaining,
      mountCastKey: p.mountCastKey || null,
      comboPoints: p.comboPoints,
    };

    if (p.dead) {
      out.push(mut); // no changes for dead players (main thread handles all)
      continue;
    }

    // Timer countdowns
    mut.gcdRemaining = Math.max(0, p.gcdRemaining - dt);
    if (p.potionCooldownUntil > 0) {
      mut.potionCooldownUntil = p.potionCooldownUntil - dt;
    }
    const cds: [number, number][] = [];
    for (const [id, remaining] of p.cooldowns) {
      const nr = remaining - dt;
      if (nr > 0) cds.push([id, nr]);
    }
    mut.cooldowns = cds;

    // Breath timer (live-only; dead handled by updateBreath on main thread)
    if (!p.inWater) {
      if (p.breath < p.maxBreath) mut.breath = clamp(p.breath + p.maxBreath * 0.25 * dt, 0, p.maxBreath);
      mut.fatigueTicks = Math.max(0, p.fatigueTicks - dt);
      mut.breathUsedTicks = 0;
    } else {
      mut.breathUsedTicks = p.breathUsedTicks + dt;
      if (mut.breathUsedTicks >= 1 / TICK_DT) {
        mut.breathUsedTicks -= 1 / TICK_DT;
        mut.breath = Math.max(0, p.breath - 1);
      }
      if (mut.breath <= 0) {
        mut.fatigueTicks = p.fatigueTicks + dt;
        if (mut.fatigueTicks >= 1 / TICK_DT) {
          mut.fatigueTicks -= 1 / TICK_DT;
          // Drown pulse: main thread's updateBreath handles dealDamage
        }
      }
    }

    // Mount cast timer
    if (p.mountCastRemaining > 0) {
      mut.mountCastRemaining = p.mountCastRemaining - dt;
      if (mut.mountCastRemaining <= 0) {
        mut.mountCastRemaining = 0;
      }
    }

    // Combo point expiry
    if (p.comboPoints > 0 && p.combatTimer >= COMBO_EXPIRY_TICKS) {
      mut.comboPoints = 0;
    }

    out.push(mut);
  }

  return out;
}

// ---------- Mob self-only computations ----------

export function computeMobSelfOnly(batch: MobBatch): MobMutation[] {
  const out: MobMutation[] = [];

  for (const m of batch.slices) {
    const mut: MobMutation = { id: m.id, aggroCandidateId: -1, aggroCandidateDistSq: Infinity };

    if (m.dead || m.ownerId !== null || m.aiState !== 'idle' || m.auras > 0) {
      out.push(mut);
      continue;
    }

    const cfg = batch.config;
    for (const pc of batch.playerCells) {
      if (pc.dead || pc.stealthed) continue;
      const dx = pc.x - m.pos.x;
      const dz = pc.z - m.pos.z;
      const d2 = dx * dx + dz * dz;
      if (d2 < cfg.maxAggroRadiusSq && d2 < mut.aggroCandidateDistSq) {
        mut.aggroCandidateDistSq = d2;
        mut.aggroCandidateId = pc.id;
      }
    }

    out.push(mut);
  }

  return out;
}
