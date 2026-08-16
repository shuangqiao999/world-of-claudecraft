import { describe, expect, it } from 'vitest';
import { buildWantedIndicatorModel } from '../src/ui/wanted_indicator_view';

describe('buildWantedIndicatorModel', () => {
  it('clamps wanted level to 0-5 from the wire mirror', () => {
    expect(buildWantedIndicatorModel(undefined, undefined).wantedLevel).toBe(0);
    expect(buildWantedIndicatorModel(-1, undefined).wantedLevel).toBe(0);
    expect(buildWantedIndicatorModel(3, undefined).wantedLevel).toBe(3);
    expect(buildWantedIndicatorModel(9, undefined).wantedLevel).toBe(5);
    expect(buildWantedIndicatorModel(2.9, undefined).wantedLevel).toBe(2);
  });

  it('maps combatState to fleeing / inCombat flags', () => {
    expect(buildWantedIndicatorModel(0, 'fleeing')).toMatchObject({
      fleeing: true,
      inCombat: false,
    });
    expect(buildWantedIndicatorModel(0, 'auto_fight')).toMatchObject({
      fleeing: false,
      inCombat: true,
    });
    expect(buildWantedIndicatorModel(0, 'pvp_fight')).toMatchObject({
      fleeing: false,
      inCombat: true,
    });
    expect(buildWantedIndicatorModel(0, 'idle')).toMatchObject({ fleeing: false, inCombat: false });
    expect(buildWantedIndicatorModel(0, 'dead')).toMatchObject({ fleeing: false, inCombat: false });
    expect(buildWantedIndicatorModel(0, undefined)).toMatchObject({
      fleeing: false,
      inCombat: false,
    });
  });
});
