// Thin painter for the screen-top GTA-style wanted stars + combat-state
// indicator. The pure render model lives in wanted_indicator_view.ts; this routes
// EVERY per-frame write through the host's elided writers so an unchanged state
// costs zero DOM work. The indicator element and its star/state children are built
// ONCE by the Hud (creation-time markup, not per-frame), mirroring proc_overlay_painter.
// The localized combat-state text and the aria-label are resolved by the Hud (so the
// painter stays i18n-free and only writes strings).

import type { PainterHostWriters } from './painter_host';
import type { WantedIndicatorModel } from './wanted_indicator_view';

export class WantedIndicatorPainter {
  constructor(
    private readonly writers: PainterHostWriters,
    private readonly root: HTMLElement, // #wanted-indicator
    private readonly combatStateEl: HTMLElement, // .combat-state
  ) {}

  paint(model: WantedIndicatorModel, combatStateText: string, ariaLabel: string): void {
    const n = model.wantedLevel;
    this.writers.toggleClass(this.root, 'wanted', n > 0);
    this.writers.toggleClass(this.root, 'w1', n >= 1);
    this.writers.toggleClass(this.root, 'w2', n >= 2);
    this.writers.toggleClass(this.root, 'w3', n >= 3);
    this.writers.toggleClass(this.root, 'w4', n >= 4);
    this.writers.toggleClass(this.root, 'w5', n >= 5);
    this.writers.toggleClass(this.root, 'fleeing', model.fleeing);
    this.writers.toggleClass(this.root, 'combat', model.inCombat);
    this.writers.setText(this.combatStateEl, combatStateText);
    this.writers.setAttr(this.root, 'aria-label', ariaLabel);
  }
}
