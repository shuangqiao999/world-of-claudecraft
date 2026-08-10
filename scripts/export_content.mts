#!/usr/bin/env tsx
// World of ClaudeCraft — Content Exporter
// Exports all game data tables from src/sim/data.ts to proto/*.json
// Run: npx tsx scripts/export_content.mts

import { writeFileSync, mkdirSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, '..');
const OUT_DIR = resolve(PROJECT_ROOT, 'dist-host-moon', 'moon-server', 'woc', 'proto');

mkdirSync(OUT_DIR, { recursive: true });

// ────────────────────────────────────────
// Helper: JSON serialize with special value handling
// ────────────────────────────────────────
function writeTable(name: string, data: any) {
  if (!data) { console.log(`  SKIP ${name}: empty`); return; }
  const json = JSON.stringify(data, replacer, 2);
  const path = resolve(OUT_DIR, `${name}.json`);
  writeFileSync(path, json);
  const keys = Array.isArray(data) ? data.length : Object.keys(data).length;
  console.log(`  [${keys} entries] → proto/${name}.json`);
}

function replacer(_key: string, val: any): any {
  if (typeof val === 'function') return '[Function]';
  if (val === Infinity) return 1e9;
  if (val === -Infinity) return -1e9;
  if (typeof val === 'bigint') return Number(val);
  if (val instanceof Set) return Array.from(val);
  if (val instanceof Map) return Object.fromEntries(val);
  return val;
}

// ────────────────────────────────────────
// MAIN
// ────────────────────────────────────────
async function main() {
  console.log('Exporting content from src/sim/data.ts ...\n');

  try {
    // Dynamic import handles tsx transpilation
    const mod = await import('../src/sim/data.ts');

    writeTable('items', mod.ITEMS);
    writeTable('mobs', mod.MOBS);
    writeTable('npcs', mod.NPCS);
    writeTable('quests', mod.QUESTS);
    writeTable('quest_order', mod.QUEST_ORDER);
    writeTable('camps', (mod as any).CAMPS);
    writeTable('dungeons', (mod as any).DUNGEONS);
    writeTable('delves', (mod as any).DELVES);
    writeTable('zones', (mod as any).ZONES);
    writeTable('classes', (mod as any).CLASSES);
    writeTable('abilities', (mod as any).ABILITIES);
    writeTable('item_sets', (mod as any).ITEM_SETS);

    // Gather nodes
    try {
      writeTable('gather_nodes', (mod as any).GATHER_NODES);
    } catch { console.log('  SKIP gather_nodes'); }

    // Deposition props (roads, mailboxes, etc.)
    try {
      writeTable('roads', (mod as any).ROADS);
    } catch { console.log('  SKIP roads'); }

    // Zone props (buildings/stalls/wells/crates/docks → colliders)
    try {
      writeTable('props', (mod as any).PROPS);
    } catch { console.log('  SKIP props'); }

    // Mounts (content/mounts.ts)
    try {
      const mountsMod = await import('../src/sim/content/mounts.ts');
      writeTable('mounts', (mountsMod as any).MOUNTS);
    } catch { console.log('  SKIP mounts'); }

    // Dungeon interior layouts (dungeon_layout.ts → colliders)
    try {
      const layoutMod = await import('../src/sim/dungeon_layout.ts');
      const layouts: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(layoutMod)) {
        if (/LAYOUT$/.test(k) && typeof v === 'object' && v !== null && (v as any).zMin !== undefined) {
          layouts[k.replace(/_LAYOUT$/, '').toLowerCase()] = v;
        }
      }
      writeTable('dungeon_layouts', layouts);
    } catch { console.log('  SKIP dungeon_layouts'); }

    console.log(`\nDone. All files → ${OUT_DIR}/`);
  } catch (err: any) {
    console.error('Export FAILED:', err.message);
    console.error('Try: npx tsx scripts/export_content.mts');
    process.exit(1);
  }
}

main();
