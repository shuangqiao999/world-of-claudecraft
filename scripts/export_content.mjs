#!/usr/bin/env node
/**
 * World of ClaudeCraft — 内容数据表导出脚本
 * 从 TypeScript 源文件提取静态数据表，输出 JSON 文件供 Moon Lua 加载
 *
 * 使用方法:
 *   node scripts/export_content.mjs
 *
 * 输出目录:
 *   E:\gongxiang\moon\woc\proto\*.json
 */

import { writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const moonProtoDir = 'E:\\gongxiang\\moon\\woc\\proto';

// 确保输出目录存在
if (!existsSync(moonProtoDir)) {
  mkdirSync(moonProtoDir, { recursive: true });
}

function saveJson(filename, data) {
  const path = join(moonProtoDir, filename);
  writeFileSync(path, JSON.stringify(data, null, 2));
  console.log(`  ✓ Saved: ${filename} (${JSON.stringify(data).length} bytes)`);
}

function exportIfAvailable(modulePath, filename, transform = (x) => x) {
  try {
    const mod = require(modulePath);
    const data = transform(mod);
    if (data) {
      saveJson(filename, data);
      return true;
    }
  } catch (err) {
    console.log(`  ✗ Skipped: ${filename} — module not available (${err.message.split('\n')[0]})`);
  }
  return false;
}

console.log('\nWorld of ClaudeCraft — Content Data Exporter');
console.log('===========================================\n');

// --- Extensions ---
// Load ts-node or tsx to handle TypeScript imports
// If those aren't available, try loading from pre-built dist or use tsx

console.log('Exporting content data tables...\n');

// 注意: TypeScript 导入可能需要 tsx 或 ts-node
// 如果编译后的 JS 文件存在，优先使用

// --- 尝试导出主要数据表 ---
// 以下按原项目 src/sim/content/ 的结构组织

const contentPath = '../src/sim/content/';

// 1. Items
try {
  // 需要从合并后的数据表导入 (src/sim/data.ts)
  // 如果 data.ts 不可用，尝试直接导入 content
  const { ALL_ITEMS } = await import('../src/sim/data.js');
  saveJson('items.json', ALL_ITEMS);
} catch (err) {
  console.log('  ✗ Items: not available, trying individual imports...');
  try {
    const items = await import('../src/sim/content/items.js');
    saveJson('items.json', items.ITEMS || items.default || items);
  } catch (e2) {
    console.log('  ✗ Items: skipped');
  }
}

// 2. Abilities
try {
  const { ABILITIES_BY_CLASS } = await import('../src/sim/data.js');
  // 转换为 Lua 友好的数组格式
  saveJson('abilities.json', ABILITIES_BY_CLASS);
} catch (err) {
  console.log('  ✗ Abilities: not available');
}

// 3. Quests
try {
  const { ALL_QUESTS } = await import('../src/sim/data.js');
  saveJson('quests.json', ALL_QUESTS);
} catch (err) {
  console.log('  ✗ Quests: not available');
}

// 4. Recipes
try {
  const { ALL_RECIPES } = await import('../src/sim/data.js');
  saveJson('recipes.json', ALL_RECIPES);
} catch (err) {
  console.log('  ✗ Recipes: not available');
}

// 5. Talents
try {
  const { TALENT_TREES } = await import('../src/sim/data.js');
  saveJson('talents.json', TALENT_TREES);
} catch (err) {
  console.log('  ✗ Talents: not available');
}

// 6. Classes
try {
  const { CLASSES } = await import('../src/sim/data.js');
  saveJson('classes.json', CLASSES);
} catch (err) {
  console.log('  ✗ Classes: not available');
}

// 7. Zones
try {
  const { ZONES } = await import('../src/sim/data.js');
  saveJson('zones.json', ZONES);
} catch (err) {
  console.log('  ✗ Zones: not available');
}

// 8. Dungeons
try {
  const { DUNGEONS } = await import('../src/sim/data.js');
  saveJson('dungeons.json', DUNGEONS);
} catch (err) {
  console.log('  ✗ Dungeons: not available');
}

// 9. Delves
try {
  const { DELVES } = await import('../src/sim/data.js');
  saveJson('delves.json', DELVES);
} catch (err) {
  console.log('  ✗ Delves: not available');
}

// 10. Mobs (mob templates)
try {
  const { MOB_TEMPLATES } = await import('../src/sim/data.js');
  saveJson('mobs.json', MOB_TEMPLATES);
} catch (err) {
  console.log('  ✗ Mobs: not available');
}

// 11. Deeds
try {
  const { ALL_DEEDS } = await import('../src/sim/data.js');
  saveJson('deeds.json', ALL_DEEDS);
} catch (err) {
  console.log('  ✗ Deeds: not available');
}

// 12. Nodes (harvest nodes)
try {
  const { HARVEST_NODES } = await import('../src/sim/data.js');
  saveJson('nodes.json', HARVEST_NODES);
} catch (err) {
  console.log('  ✗ Nodes: not available');
}

// 13. Mounts
try {
  const { MOUNTS } = await import('../src/sim/data.js');
  saveJson('mounts.json', MOUNTS);
} catch (err) {
  console.log('  ✗ Mounts: not available');
}

console.log('\nExport complete!');
console.log(`Output directory: ${moonProtoDir}\n`);
