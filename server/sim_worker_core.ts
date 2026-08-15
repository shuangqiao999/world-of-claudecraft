// Self-only sim tick computations that run in worker threads.
// Pure functions: no SimContext, no RNG, no side effects.
//
// WORKER RESPONSIBILITY (narrow):
//   - Timer countdowns (cooldowns, GCD, potion CD) for LIVE players only
//
// EXCLUDED (stay on main thread, authoritative):
//   - Breath, drowning, fatigue — updateBreath owns all of this
//   - Combo point expiry — updateComboExpiry owns this
//   - Mount cast timers — updateMountTransition owns this
//   - Aura durations/expirations — updateAuras owns all of this
//   - Regen (hp/resource) — updateRegen owns this
//   - Dead players — no mutations (all handled by main thread)

// ---------- Types ----------

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface PlayerSlice {
  id: number;
  dead: boolean;
  combatTimer: number;
  gcdRemaining: number;
  potionCooldownUntil: number;
  cooldowns: [string, number][];
}

export interface PlayerMutation {
  id: number;
  gcdRemaining: number;
  potionCooldownUntil: number;
  cooldowns: [string, number][];
}

export interface PlayerBatch {
  slices: PlayerSlice[];
  tick: number;
  dt: number;
}

// ---------- Mob types ----------

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

export interface PlayerCell {
  x: number;
  z: number;
  id: number;
  stealthed: boolean;
  dead: boolean;
  level: number;
}

export interface MobMutation {
  id: number;
  aggroCandidateId: number;
  aggroCandidateDistSq: number;
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

export function computePlayerSelfOnly(batch: PlayerBatch): PlayerMutation[] {
  const out: PlayerMutation[] = [];
  const dt = batch.dt;

  for (const p of batch.slices) {
    const mut: PlayerMutation = {
      id: p.id,
      gcdRemaining: p.gcdRemaining,
      potionCooldownUntil: p.potionCooldownUntil,
      cooldowns: Array.from(p.cooldowns),
    };

    // Dead players: pass through unchanged (main thread handles everything)
    if (p.dead) {
      out.push(mut);
      continue;
    }

    // Timer countdowns
    mut.gcdRemaining = Math.max(0, p.gcdRemaining - dt);
    if (p.potionCooldownUntil > 0) {
      mut.potionCooldownUntil = p.potionCooldownUntil - dt;
    }
    const cds: [string, number][] = [];
    for (const [id, remaining] of p.cooldowns) {
      const nr = remaining - dt;
      if (nr > 0) cds.push([id, nr]);
    }
    mut.cooldowns = cds;

    out.push(mut);
  }

  return out;
}

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
