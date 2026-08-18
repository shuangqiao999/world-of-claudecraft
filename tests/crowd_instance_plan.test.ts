// Crowd-instancing membership policy. Each arm of the predicate is pinned
// separately: the frozen far band collapses to a SHARED material, so a single
// lost arm can leak actionable information (a stealthed body rendering opaque
// from the shared InstancedMesh) or double-draw a rig, and no other test would
// notice. The slot bookkeeping is pinned for the same reason a buffer slot
// reused out of order draws a stale matrix.
import { describe, expect, it } from 'vitest';
import {
  CrowdInstanceSlots,
  crowdInstanceWriteMatrix,
  shouldCrowdInstance,
  type CrowdInstanceInputs,
} from '../src/render/crowd_instance_plan_core';
import { assertAllocationStable } from './util/alloc_probe';

const base = (over: Partial<CrowdInstanceInputs> = {}): CrowdInstanceInputs => ({
  isFar: true,
  baseVisualActive: true,
  fireballForm: false,
  farStateActive: false,
  poolKey: 'mob:boar:16711680:1',
  visible: true,
  ...over,
});

describe('shouldCrowdInstance', () => {
  it('instances an ordinary frozen far mob', () => {
    expect(shouldCrowdInstance(base())).toBe(true);
  });

  it('never instances anything the far mesh swap itself does not apply to', () => {
    expect(shouldCrowdInstance(base({ isFar: false }))).toBe(false);
    expect(shouldCrowdInstance(base({ baseVisualActive: false }))).toBe(false);
    expect(shouldCrowdInstance(base({ fireballForm: true }))).toBe(false);
  });

  it('exempts any per-entity far-mesh material state (stealth/glow/tint/soul rend)', () => {
    expect(shouldCrowdInstance(base({ farStateActive: true }))).toBe(false);
  });

  it('never instances a visual without a pool key (players, objects)', () => {
    expect(shouldCrowdInstance(base({ poolKey: null }))).toBe(false);
  });

  it('drops culled/off-screen views even when their stale flag says far', () => {
    expect(shouldCrowdInstance(base({ visible: false }))).toBe(false);
  });

  it('pins the allocation budget of the per-frame decision', () => {
    const inputs = base();
    const probe = () => {
      shouldCrowdInstance(inputs);
      return inputs;
    };
    expect(() => assertAllocationStable(probe, 32, 'crowd-instance decision')).not.toThrow();
  });
});

describe('CrowdInstanceSlots', () => {
  it('allocates fresh slots, reuses freed ones, and reports the draw count', () => {
    const slots = new CrowdInstanceSlots();
    expect(slots.alloc(10)).toBe(0);
    expect(slots.alloc(20)).toBe(1);
    expect(slots.alloc(30)).toBe(2);
    expect(slots.activeCount).toBe(3);
    expect(slots.highWater).toBe(3);

    expect(slots.remove(20)).toBe(true);
    expect(slots.activeCount).toBe(2);
    expect(slots.alloc(40)).toBe(1); // freed slot reused before growing
    expect(slots.highWater).toBe(3);
  });

  it('alloc is idempotent for an already-present entity', () => {
    const slots = new CrowdInstanceSlots();
    const first = slots.alloc(7);
    expect(slots.alloc(7)).toBe(first);
    expect(slots.activeCount).toBe(1);
  });

  it('remove is a no-op for an entity with no slot', () => {
    const slots = new CrowdInstanceSlots();
    expect(slots.remove(7)).toBe(false);
    expect(slots.remove(7)).toBe(false);
    expect(slots.has(7)).toBe(false);
  });

  it('keeps the free list bounded and reuses every hole before growing', () => {
    const slots = new CrowdInstanceSlots();
    for (let i = 0; i < 8; i++) slots.alloc(i);
    for (let i = 0; i < 8; i++) slots.remove(i);
    expect(slots.activeCount).toBe(0);
    const reused = new Set<number>();
    for (let i = 0; i < 8; i++) reused.add(slots.alloc(i));
    expect(reused).toEqual(new Set([0, 1, 2, 3, 4, 5, 6, 7])); // every hole, in LIFO order
    expect(slots.highWater).toBe(8);
  });

  it('grows the high-water mark only when every hole is taken', () => {
    const slots = new CrowdInstanceSlots();
    slots.alloc(1); // slot 0
    slots.alloc(2); // slot 1
    slots.remove(2); // free [1]
    expect(slots.alloc(3)).toBe(1); // hole reused
    expect(slots.alloc(4)).toBe(2); // grew past the hole
    expect(slots.highWater).toBe(3);
  });
});

describe('crowdInstanceWriteMatrix', () => {
  it('writes the 16 floats at the slot offset and reports a change', () => {
    const arr = new Float32Array(4 * 16).fill(0);
    const src = new Float32Array(16);
    for (let i = 0; i < 16; i++) src[i] = i + 1;
    expect(crowdInstanceWriteMatrix(arr, 2, src)).toBe(true);
    expect(Array.from(arr.slice(32, 48))).toEqual(Array.from(src));
  });

  it('reports no change when the slot already holds the same matrix', () => {
    const arr = new Float32Array(16).fill(0);
    const src = new Float32Array(16);
    for (let i = 0; i < 16; i++) src[i] = i + 1;
    crowdInstanceWriteMatrix(arr, 0, src);
    expect(crowdInstanceWriteMatrix(arr, 0, src)).toBe(false);
  });

  it('does not disturb neighbouring slots', () => {
    const arr = new Float32Array(3 * 16).fill(0);
    const src = new Float32Array(16).fill(7);
    crowdInstanceWriteMatrix(arr, 0, src);
    crowdInstanceWriteMatrix(arr, 2, src);
    expect(Array.from(arr.slice(0, 16))).toEqual(Array.from(src));
    expect(Array.from(arr.slice(16, 32))).toEqual(new Array(16).fill(0));
    expect(Array.from(arr.slice(32, 48))).toEqual(Array.from(src));
  });

  it('pins the allocation budget of the hot-path write', () => {
    const arr = new Float32Array(16).fill(0);
    const src = new Float32Array(16);
    for (let i = 0; i < 16; i++) src[i] = i;
    const probe = () => {
      crowdInstanceWriteMatrix(arr, 0, src);
      return arr;
    };
    expect(() => assertAllocationStable(probe, 32, 'crowd-instance matrix write')).not.toThrow();
  });
});
