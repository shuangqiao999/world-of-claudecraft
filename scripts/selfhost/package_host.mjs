// World of ClaudeCraft self-host payload assembler.
// Builds a self-contained LAN host bundle:
//   dist-host/
//     WorldOfClaudeCraft.exe   (Node SEA launcher, built from launcher.mjs)
//     node.exe                 (Node runtime for the game server)
//     dist-server/server.cjs   (esbuild-bundled authoritative server)
//     dist/                    (built client, served by the server)
//     postgres/                (portable PostgreSQL 16 binaries)
//
// Prereqs: npm run build, npm run build:server, postject on PATH,
// and the zonky @embedded-postgres/windows-x64 tarball extracted into
// postgres-src/ (bin/initdb.exe etc). Run from the repo root.
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);

const ROOT = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
const OUT = path.join(ROOT, 'dist-host');
const LAUNCHER = path.join(ROOT, 'scripts', 'selfhost', 'launcher.mjs');
const SEA_CONFIG = path.join(ROOT, 'scripts', 'selfhost', 'sea-config.json');
const PG_SRC = path.join(ROOT, 'postgres-src');

const EXE_NAME = 'WorldOfClaudeCraft.exe';

function log(...args) {
  console.log(`[host-bundle]`, ...args);
}

function check(cond, message) {
  if (!cond) {
    console.error(`[host-bundle] FAILED: ${message}`);
    process.exit(1);
  }
}

function run(cmd, args) {
  const res = spawnSync(cmd, args, { stdio: 'inherit' });
  check(res.status === 0, `${cmd} exited ${res.status}`);
}

function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const from = path.join(src, entry.name);
    const to = path.join(dest, entry.name);
    if (entry.isDirectory()) copyDir(from, to);
    else fs.copyFileSync(from, to);
  }
}

async function main() {
  log(`assembling self-host payload into ${OUT}`);
  check(fs.existsSync(path.join(ROOT, 'dist', 'index.html')), 'dist/ missing; run `npm run build` first');
  check(fs.existsSync(path.join(ROOT, 'dist-server', 'server.cjs')), 'dist-server/server.cjs missing; run `npm run build:server` first');
  check(fs.existsSync(path.join(PG_SRC, 'bin', 'postgres.exe')), 'postgres-src/bin missing; extract the zonky windows-x64 tarball into postgres-src/');

  fs.rmSync(OUT, { recursive: true, force: true });
  fs.mkdirSync(OUT, { recursive: true });

  log('copying client build (dist/)...');
  copyDir(path.join(ROOT, 'dist'), path.join(OUT, 'dist'));

  log('copying server bundle...');
  copyDir(path.join(ROOT, 'dist-server'), path.join(OUT, 'dist-server'));

  log('copying Node runtime (node.exe)...');
  const nodeExe = process.execPath;
  check(fs.existsSync(nodeExe), 'could not resolve node.exe');
  fs.copyFileSync(nodeExe, path.join(OUT, 'node.exe'));

  log('copying portable PostgreSQL...');
  copyDir(PG_SRC, path.join(OUT, 'postgres'));

  log('building SEA launcher exe...');
  // SEA loads the embedded main as CJS, so bundle the ESM launcher to a single
  // CJS file with esbuild before generating the blob.
  const launcherCjs = path.join(OUT, 'launcher.cjs');
  const esbuild = require('esbuild');
  await esbuild.build({
    entryPoints: [LAUNCHER],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    outfile: launcherCjs,
  });
  const blob = path.join(OUT, 'sea-prep.blob');
  const seaConfig = {
    main: launcherCjs,
    output: blob,
    disableExperimentalSEAWarning: true,
  };
  fs.writeFileSync(SEA_CONFIG, JSON.stringify(seaConfig, null, 2));
  run(process.execPath, ['--experimental-sea-config', SEA_CONFIG]);
  check(fs.existsSync(blob), 'sea-prep.blob was not produced');

  const exeOut = path.join(OUT, EXE_NAME);
  fs.copyFileSync(nodeExe, exeOut);
  // postject is a .cmd shim; invoke its JS entry directly through node so the
  // script does not depend on the shell or PATH (the Windows .cmd shim cannot
  // be spawnSync'd without a shell, and the user's PATH may differ).
  const postjectCli = require.resolve('postject/dist/cli.js', {
    paths: [path.join(ROOT, 'node_modules'), path.join(os.homedir(), 'AppData', 'Roaming', 'npm', 'node_modules')],
  });
  run(process.execPath, [
    postjectCli,
    exeOut,
    'NODE_SEA_BLOB',
    blob,
    '--sentinel-fuse',
    'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2',
  ]);
  fs.rmSync(blob, { force: true });
  fs.rmSync(launcherCjs, { force: true });
  fs.rmSync(SEA_CONFIG, { force: true });

  const size = (fs.statSync(exeOut).size / 1024 / 1024).toFixed(1);
  log(`done. launcher exe ${EXE_NAME} (${size} MB) in ${OUT}`);
  const payloadBytes = ['dist', 'postgres', 'dist-server']
    .map((d) => dirSize(path.join(OUT, d)))
    .reduce((a, b) => a + b, 0);
  log(`total payload approx ${(payloadBytes / 1024 / 1024 / 1024).toFixed(2)} GB`);

  if (process.argv.includes('--installer')) {
    buildInstaller();
  }
}

function buildInstaller() {
  const makensis = findMakensis();
  check(makensis, 'NSIS makensis.exe not found (looked in Program Files, Program Files (x86), and PATH)');
  const nsi = path.join(ROOT, 'scripts', 'selfhost', 'installer.nsi');
  check(fs.existsSync(nsi), `installer script missing: ${nsi}`);
  log(`compiling installer with ${makensis} (lzma over ~1.1 GB, this takes several minutes)...`);
  run(makensis, ['/V2', nsi]);
  const setup = path.join(OUT, 'WorldOfClaudeCraft-Server-Setup.exe');
  check(fs.existsSync(setup), `installer was not produced: ${setup}`);
  log(`done. installer ${(fs.statSync(setup).size / 1024 / 1024).toFixed(0)} MB in ${OUT}`);
}

function findMakensis() {
  const candidates = [
    path.join(process.env['ProgramFiles(x86)'] || '', 'NSIS', 'makensis.exe'),
    path.join(process.env.ProgramFiles || '', 'NSIS', 'makensis.exe'),
    process.env.NSIS ? path.join(process.env.NSIS, 'makensis.exe') : '',
  ].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

function dirSize(dir) {
  let total = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) total += dirSize(p);
    else total += fs.statSync(p).size;
  }
  return total;
}

main().catch((err) => {
  console.error(`[host-bundle] FAILED:`, err);
  process.exit(1);
});
