// Pure decision: GTA open-world "click any non-monster ground to stop attacking
// and flee". The moon server flips combatState to 'fleeing' on `stopattack`; the
// offline Sim carries no combatState, so it falls back to the classic autoAttack
// flag. Kept DOM/Three-free so it unit-tests in isolation (the click_move pattern).
import type { PlayerCombatState } from '../sim/types';

export function shouldFleeOnGroundClick(
  combatState: PlayerCombatState | undefined,
  autoAttack: boolean,
): boolean {
  if (combatState === 'auto_fight' || combatState === 'pvp_fight') return true;
  // Offline (no combatState mirror) uses the classic auto-attack boolean.
  return combatState === undefined && autoAttack;
}
