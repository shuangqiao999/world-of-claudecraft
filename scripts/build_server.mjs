// Bundles the authoritative server. The bot detector is resolved through the
// abstract `#bot-detector` specifier: the private implementation if its clone is
// present, otherwise the open-source no-op stub. Mirrors the resolution in
// vite.config.ts (vitest/dev) and tsconfig.json `paths` (typecheck).
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const privateImpl = fileURLToPath(new URL('../private/bot_detector/src/index.ts', import.meta.url));
const stubImpl = fileURLToPath(new URL('../server/bot_detector/stub.ts', import.meta.url));
const usePrivate = existsSync(privateImpl);

await esbuild.build({
  entryPoints: ['server/main.ts'],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  external: ['pg-native', 'bufferutil', 'utf-8-validate'],
  outfile: 'dist-server/server.cjs',
  alias: { '#bot-detector': usePrivate ? privateImpl : stubImpl },
});

await esbuild.build({
  entryPoints: ['scripts/migrate_old_cragmaw_pelt.ts'],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  external: ['pg-native'],
  outfile: 'dist-server/migrate_old_cragmaw_pelt.cjs',
  alias: { '#bot-detector': usePrivate ? privateImpl : stubImpl },
});

// Snapshot worker thread：TypeScript 入口需要被打包成 CJS，否则 Node Worker
// 无法加载 .ts 依赖。esbuild 会把 ./snapshot_worker_core (以及它的 src/sim 引用)
// 全部内联到这个 CJS 文件里。
await esbuild.build({
  entryPoints: ['server/snapshot_thread.ts'],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  outfile: 'dist-server/snapshot_thread.cjs',
});

console.log(`[build:server] bot detector: ${usePrivate ? 'private' : 'stub (no-op)'}`);
