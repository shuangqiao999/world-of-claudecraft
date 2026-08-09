// Self-only sim tick computations that run in worker threads.
// Pure functions: no SimContext, no RNG, no side effects.
// Each receives flat data and returns flat mutation results.
//
// DESIGN: Workers compute self-only entity mutations (movement, regen,
// timers, idle AI decisions) while the main thread handles cross-entity
// mutations (combat, auras, threat) and RNG draws.

// ---------- Common types ----------

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface Vec2 {
  x: number;
  z: number;
}

// ---------- Player slice (data sent to worker) ----------

export interface PlayerSlice {
  id: number;
  // Movement
  pos: Vec3;
  prevPos: Vec3;
  vx: number;
  vy: number;
  vz: number;
  facing: number;
  prevFacing: number;
  moveDir: Vec2;
  jumpHeld: boolean;
  onGround: boolean;
  jumping: boolean;
  fallStartY: number;
  // State
  dead: boolean;
  ghost: boolean;
  mounted: boolean;
  // Regen
  hp: number;
  maxHp: number;
  resource: number;
  maxResource: number;
  spirit: number;
  combatTimer: number;
  sitting: boolean;
  eatingTicks: number;
  drinkingTicks: number;
  // Timers
  gcdRemaining: number;
  potionCooldownUntil: number;
  cooldowns: [number, number][];
  auraDurations: [number, number, number][]; // [index, remaining, tickTimer]
  // Breath
  breath: number;
  maxBreath: number;
  fatigueTicks: number;
  breathUsedTicks: number;
  inWater: boolean;
  // Mount
  mountCastRemaining: number;
  mountCastKey: string;
  mountRaceTotal: number;
  // Combo
  comboPoints: number;
  // Specific aura flags (for self-only computation)
  hasProtWarriorStance: boolean;
}

// ---------- Player mutation (result from worker) ----------

export interface PlayerMutation {
  id: number;
  // Regen results
  hp: number;
  resource: number;
  // Timer results
  gcdRemaining: number;
  potionCooldownUntil: number;
  cooldowns: [number, number][];
  auraDurations: [number, number][]; // [index, newRemaining]
  // Breath
  breath: number;
  fatigueTicks: number;
  breathUsedTicks: number;
  // Mount
  mountCastRemaining: number;
  mountCastKey: string | null;
  mountCastComplete: boolean;
  // Combo
  comboPoints: number;
  comboExpired: boolean;
  // Aura expiries
  expiredAuraIndices: number[];
  statsDirty: boolean;
}

// ---------- Mob slice ----------

export interface MobSlice {
  id: number;
  kind: 'mob';
  pos: Vec3;
  dead: boolean;
  ownerId: number | null;
  aiState: string;
  aggroTargetId: number | null;
  forcedTargetId: number | null;
  forcedTargetTimer: number;
  auras: number; // just count (idle mobs with 0 auras)
  chaseStall: number;
  templateId: string;
}

// ---------- Mob mutation ----------

export interface MobMutation {
  id: number;
  aggroCandidateId: number; // -1 if no candidate found (-1 to avoid accidental 0-entity lookup)
  aggroCandidateDistSq: number;
}

// ---------- Player playerCells for aggro scan ----------

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
  dt: number; // TICK_DT (1/20)
}

export interface MobBatch {
  slices: MobSlice[];
  playerCells: PlayerCell[]; // spatial grid contents relevant to these mobs
  config: MobConfig;
  tick: number;
  dt: number;
}

export interface MobConfig {
  maxAggroRadius: number;
  maxAggroRadiusSq: number;
  idleWanderRadius: number;
  idleWanderRadiusSq: number;
  minWanderRadius: number;
  chaseSpeedMult: number;
  meleeRange: number;
  meleeRangeSq: number;
}

// ---------- Pure computation functions ----------

const TICK_DT = 1 / 20;
const GCD = 1.5;
const FIVE_SEC_RULE_TICKS = 5 / TICK_DT; // 100 ticks = 5 seconds at 20 Hz
const SITTING_REGEN_MULT = 1.5;
const EATING_REGEN_TICK = 2 / TICK_DT; // 2 seconds
const BREATH_TICK_INTERVAL = 1 / TICK_DT; // 1 second
const FATIGUE_TICK_INTERVAL = 1 / TICK_DT;
const COMBO_EXPIRY_TICKS = 5 / TICK_DT; // 5 seconds
const MOUNT_CAST_TICKS = 3 / TICK_DT; // 3 second cast

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

export function computePlayerSelfOnly(batch: PlayerBatch): PlayerMutation[] {
  const out: PlayerMutation[] = [];
  const dt = batch.dt;

  for (const p of batch.slices) {
    const mut: PlayerMutation = {
      id: p.id,
      hp: p.hp,
      resource: p.resource,
      gcdRemaining: p.gcdRemaining,
      potionCooldownUntil: p.potionCooldownUntil,
      cooldowns: [],
      auraDurations: [],
      breath: p.breath,
      fatigueTicks: p.fatigueTicks,
      breathUsedTicks: p.breathUsedTicks,
      mountCastRemaining: p.mountCastRemaining,
      mountCastKey: null,
      mountCastComplete: false,
      comboPoints: p.comboPoints,
      comboExpired: false,
      expiredAuraIndices: [],
      statsDirty: false,
    };

    // Skip dead/ghost players (no regen, no combat timers)
    if (p.dead) {
      // Breath update
      updateBreathPure(mut, p, dt);
      // Aura timers still tick on dead
      tickAuraTimersPure(mut, p, dt);
      // Mount cast cancels on death
      if (p.mountCastRemaining > 0) {
        mut.mountCastRemaining = 0;
        mut.mountCastKey = null;
      }
      out.push(mut);
      continue;
    }

    // ----- Regen -----
    const silenced = p.combatTimer < FIVE_SEC_RULE_TICKS;

    if (!silenced) {
      // Mana/energy regen
      const manaPerTick = p.spirit * 0.25 * dt;
      if (p.resource < p.maxResource) {
        mut.resource = clamp(p.resource + manaPerTick, 0, p.maxResource);
      }

      // HP regen
      const sittingMult = p.sitting ? SITTING_REGEN_MULT : 1;
      const hpPerTick = p.spirit * 0.1 * sittingMult * dt;
      if (p.hp < p.maxHp) {
        mut.hp = clamp(p.hp + hpPerTick, 0, p.maxHp);
      }

      // Eating/drinking health ticks
      if (p.eatingTicks > 0) {
        const eatHp = p.maxHp * 0.02;
        mut.hp = clamp(mut.hp + eatHp, 0, p.maxHp);
      }
      if (p.drinkingTicks > 0) {
        const drinkMana = p.maxResource * 0.02;
        mut.resource = clamp(mut.resource + drinkMana, 0, p.maxResource);
      }
    }

    // ----- Timers -----
    // GCD
    mut.gcdRemaining = Math.max(0, p.gcdRemaining - dt);
    // Potion cooldown
    if (p.potionCooldownUntil > 0) {
      mut.potionCooldownUntil = p.potionCooldownUntil - dt;
    }
    // Ability cooldowns
    const cds: [number, number][] = [];
    for (const [id, remaining] of p.cooldowns) {
      const newRemaining = remaining - dt;
      if (newRemaining > 0) cds.push([id, newRemaining]);
    }
    mut.cooldowns = cds;

    // Aura timers: durations and expirations are handled by the main thread's
    // updateAuras() call. The worker only sets statsDirty as an optimization
    // hint (the main thread still validates).

    // ----- Breath -----
    updateBreathPure(mut, p, dt);

    // ----- Mount -----
    if (p.mountCastRemaining > 0) {
      mut.mountCastRemaining = p.mountCastRemaining - dt;
      if (mut.mountCastRemaining <= 0) {
        mut.mountCastRemaining = 0;
        mut.mountCastComplete = true;
      }
    }

    // Mount race timer
    if (p.mountRaceTotal > 0) {
      // mount race processing is simple timer decrement (the main thread
      // handles race completion logic since it may emit events)
    }

    // ----- Combo expiry -----
    if (p.comboPoints > 0 && p.combatTimer >= COMBO_EXPIRY_TICKS) {
      mut.comboPoints = 0;
      mut.comboExpired = true;
    }

    out.push(mut);
  }

  return out;
}

function updateBreathPure(mut: PlayerMutation, p: PlayerSlice, dt: number): void {
  if (!p.inWater || p.dead) {
    // Recover breath out of water or dead
    if (p.breath < p.maxBreath) {
      mut.breath = clamp(p.breath + p.maxBreath * 0.25 * dt, 0, p.maxBreath);
    }
    mut.fatigueTicks = Math.max(0, p.fatigueTicks - dt);
    mut.breathUsedTicks = 0;
    return;
  }

  breathUsedAdd: {
    mut.breathUsedTicks = p.breathUsedTicks + dt;
    if (mut.breathUsedTicks < BREATH_TICK_INTERVAL) break breathUsedAdd;
    mut.breathUsedTicks -= BREATH_TICK_INTERVAL;
    mut.breath = Math.max(0, p.breath - 1);
  }

  if (mut.breath <= 0) {
    mut.fatigueTicks = p.fatigueTicks + dt;
    if (mut.fatigueTicks >= FATIGUE_TICK_INTERVAL) {
      mut.fatigueTicks -= FATIGUE_TICK_INTERVAL;
      // Drown damage: flagged for main thread (cross-entity)
      // We just track the timer here; the main thread applies damage
    }
  }
}

function tickAuraTimersPure(mut: PlayerMutation, p: PlayerSlice, dt: number): void {
  const expired: number[] = [];
  const newDurations: [number, number][] = [];

  for (const [idx, remaining, tickTimer] of p.auraDurations) {
    let newRemaining = remaining - dt;
    let newTickTimer = tickTimer - dt;

    if (newRemaining <= 0) {
      expired.push(idx);
      mut.statsDirty = true;
      continue;
    }

    newDurations.push([idx, newRemaining]);
  }

  mut.expiredAuraIndices.push(...expired);
  mut.auraDurations = newDurations;
}

// ---------- Mob self-only computations ----------

export function computeMobSelfOnly(batch: MobBatch): MobMutation[] {
  const out: MobMutation[] = [];

  for (const m of batch.slices) {
    const mut: MobMutation = {
      id: m.id,
      aggroCandidateId: -1,
      aggroCandidateDistSq: Infinity,
    };

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
