// Pure view core for the screen-top GTA-style wanted stars + combat-state
// indicator. Maps the player's wire-mirrored `wantedLevel` (0-5) and
// `combatState` (moon-server GTA combat state machine) to a render model the
// thin `wanted_indicator_painter` turns into toggled classes. No DOM, no i18n
// (the painter/Hud resolves the aria-label text); defensive clamping only.

import type { PlayerCombatState } from '../sim/types';

export interface WantedIndicatorModel {
  /** 0-5, clamped from the wire mirror; 0 means "not wanted". */
  wantedLevel: number;
  /** combatState === 'fleeing' (ground-click escape / stopattack). */
  fleeing: boolean;
  /** combatState === 'auto_fight' or 'pvp_fight' (engaged in GTA combat). */
  inCombat: boolean;
}

export function buildWantedIndicatorModel(
  wantedLevel: number | undefined,
  combatState: PlayerCombatState | undefined,
): WantedIndicatorModel {
  return {
    wantedLevel: Math.max(0, Math.min(5, Math.floor(wantedLevel ?? 0))),
    fleeing: combatState === 'fleeing',
    inCombat: combatState === 'auto_fight' || combatState === 'pvp_fight',
  };
}
