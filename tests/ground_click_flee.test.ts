import { describe, expect, it } from 'vitest';
import { shouldFleeOnGroundClick } from '../src/game/ground_click_flee';

describe('shouldFleeOnGroundClick', () => {
  it('flees while auto-fighting a mob', () => {
    expect(shouldFleeOnGroundClick('auto_fight', false)).toBe(true);
  });

  it('flees while in a mutual PvP fight', () => {
    expect(shouldFleeOnGroundClick('pvp_fight', true)).toBe(true);
  });

  it('does not re-flee when already fleeing', () => {
    expect(shouldFleeOnGroundClick('fleeing', false)).toBe(false);
  });

  it('does nothing when idle or dead', () => {
    expect(shouldFleeOnGroundClick('idle', false)).toBe(false);
    expect(shouldFleeOnGroundClick('dead', false)).toBe(false);
  });

  it('offline (no combatState) falls back to the auto-attack flag', () => {
    expect(shouldFleeOnGroundClick(undefined, true)).toBe(true);
    expect(shouldFleeOnGroundClick(undefined, false)).toBe(false);
  });
});
