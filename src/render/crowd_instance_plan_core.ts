// Crowd-instancing membership policy for the frozen far band. Pure (no Three,
// no DOM, no i18n, deterministic), so the renderer stays a thin painter and the
// decision ladder is unit-tested. Sibling of `crowd_lod.ts`: that module owns
// the band EDGES; this one owns WHICH frozen far entities collapse into a shared
// `THREE.InstancedMesh` and WHERE each one lands in the instance buffer.
//
// The invariant it serves: a performance knob may shed cosmetic richness but
// must never hide OR LEAK actionable information. The frozen far mesh is a
// shared material, so any per-entity material state (stealth transparency,
// aura glow, shape-shift tints, soul rend) is not representable per instance -
// a stealthed body must stay translucent, never render opaque from the shared
// mesh, or the crowd knob reveals it. `farStateActive` is that carve-out.

export interface CrowdInstanceInputs {
  /** past the static band edge (the crowd-pulled frozen-mesh swap already
   *  applied its `actionableStaticRangeSq` floor to this flag). */
  isFar: boolean;
  /** the base visual is the one being far-drawn (a druid form keeps its own
   *  rig and must never collapse into the base visual's instanced mesh). */
  baseVisualActive: boolean;
  /** Mage travel form: like forms, never instances. */
  fireballForm: boolean;
  /** any active per-entity far-mesh material state (ghost/glow/tint/soul rend):
   *  exempt, that visual keeps its own frozen mesh. */
  farStateActive: boolean;
  /** the visual pool key (`visualPoolKeyFor`); null for players/objects, which
   *  never instance. Doubles as the group key (color/skin are in it, so the
   *  group's shared material is homogeneous by construction). */
  poolKey: string | null;
  /** the view's group is visible this frame (culled/off-screen views must not
   *  keep a stale instance). */
  visible: boolean;
}

/** Whether this frozen far entity joins a shared InstancedMesh this frame. */
export function shouldCrowdInstance(inputs: CrowdInstanceInputs): boolean {
  return (
    inputs.isFar &&
    inputs.baseVisualActive &&
    !inputs.fireballForm &&
    !inputs.farStateActive &&
    inputs.poolKey !== null &&
    inputs.visible
  );
}

/**
 * Instance-slot bookkeeping for one InstancedMesh group: entityId -> slot index,
 * with a free list so a vacated slot is reused before the buffer grows. The
 * painter owns the matrix array (16 floats per slot); this class owns the index
 * math only, so it stays Three-free and unit-testable.
 */
export class CrowdInstanceSlots {
  /** entityId -> slot index (the painter writes `slot * 16` floats there). */
  readonly byId = new Map<number, number>();
  /** vacant slot indices (swap-remove leaves holes; reused before growing). */
  private readonly free: number[] = [];
  /** next never-used slot index (the buffer's high-water mark). */
  private next = 0;

  /** Idempotent: returns the entity's current slot or allocates one. */
  alloc(id: number): number {
    const existing = this.byId.get(id);
    if (existing !== undefined) return existing;
    const slot = this.free.length > 0 ? (this.free.pop() as number) : this.next++;
    this.byId.set(id, slot);
    return slot;
  }

  /** True when the entity had a slot (removed); false when it had none. */
  remove(id: number): boolean {
    const slot = this.byId.get(id);
    if (slot === undefined) return false;
    this.byId.delete(id);
    this.free.push(slot);
    return true;
  }

  has(id: number): boolean {
    return this.byId.has(id);
  }

  /** Number of drawn instances (also the InstancedMesh `count`). */
  get activeCount(): number {
    return this.byId.size;
  }

  /** Highest slot index handed out + 1 (the buffer capacity the group needs). */
  get highWater(): number {
    return this.next;
  }
}

/**
 * Compare-and-write a 16-float matrix into `arr` at `slot * 16`; returns whether
 * any element changed. The painter skips the GPU re-upload (`needsUpdate`) in
 * steady state, where a static frozen crowd leaves every element unchanged.
 * Zero-allocation: writes into the InstancedMesh's own Float32Array.
 */
export function crowdInstanceWriteMatrix(
  arr: Float32Array,
  slot: number,
  src: Float32Array,
): boolean {
  const off = slot * 16;
  let changed = false;
  for (let i = 0; i < 16; i++) {
    const v = src[i];
    if (arr[off + i] !== v) changed = true;
    arr[off + i] = v;
  }
  return changed;
}
