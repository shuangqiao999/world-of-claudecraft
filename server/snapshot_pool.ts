// Snapshot worker thread pool for the broadcastSnapshots phase.  The main
// game loop is single-threaded (it owns sim.tick and determinism), but the
// per-session snapshot assembly is embarrassingly parallel: each session's
// snapshot depends only on shared world state and its own private delta
// state, with zero cross-session ordering constraints.
//
// When the env var WOC_SNAPSHOT_WORKERS is set to a positive number, the
// broadcastSnapshots phase fans out per-session batches to that many worker
// threads and joins before returning.  Without the env var (or set to 0) the
// serial broadcast path is used unchanged.
//
// Adaptive default: when WOC_SNAPSHOT_WORKERS is set but empty, the pool
// uses Math.floor(os.cpus().length / 2) workers (capped at 16), leaving the
// other half for the main loop, socket I/O, and Postgres.

import { Worker } from 'node:worker_threads';
import os from 'node:os';
import path from 'node:path';

import type { BroadcastContext, SessionBundle, SessionSnapshot } from './snapshot_worker_core';

export interface SnapshotPoolOptions {
  workers?: number; // 0 = disabled (serial path); undefined/empty = adaptive
}

interface PendingWork {
  resolve: (results: SessionSnapshot[]) => void;
  reject: (err: Error) => void;
}

export class SnapshotPool {
  private workers: Worker[] = [];
  private pending = new Map<number, PendingWork>();
  private nextId = 0;
  private busy = false;
  private log: (msg: string) => void;

  constructor(opts: SnapshotPoolOptions, log: (msg: string) => void = () => {}) {
    this.log = log;
    const count = resolveWorkerCount(opts.workers);
    if (count <= 0) return;
    const workerPath = path.join(__dirname, 'snapshot_thread.mjs');
    for (let i = 0; i < count; i++) {
      const w = new Worker(workerPath);
      w.on('message', (reply: { id: number; results?: SessionSnapshot[]; error?: string }) => {
        const pending = this.pending.get(reply.id);
        if (!pending) return;
        this.pending.delete(reply.id);
        if (reply.error) {
          pending.reject(new Error(`snapshot worker error: ${reply.error}`));
        } else {
          pending.resolve(reply.results ?? []);
        }
      });
      w.on('error', (err: Error) => {
        this.log(`snapshot worker error: ${err.message}`);
      });
      this.workers.push(w);
    }
    this.log(`snapshot pool: ${count} workers`);
  }

  get active(): boolean {
    return this.workers.length > 0;
  }

  async broadcast(
    ctx: BroadcastContext,
    batch: SessionBundle[],
  ): Promise<SessionSnapshot[]> {
    if (!this.active || batch.length === 0) return [];
    if (this.busy) throw new Error('SnapshotPool: overlapping broadcast calls');
    this.busy = true;
    try {
      const chunks = splitIntoChunks(batch, this.workers.length);
      const promises = chunks.map((bundles, i) => {
        return new Promise<SessionSnapshot[]>((resolve, reject) => {
          const id = this.nextId++;
          this.pending.set(id, { resolve, reject });
          this.workers[i].postMessage({ ctx, bundles, id });
        });
      });
      const results = await Promise.all(promises);
      return results.flat();
    } finally {
      this.busy = false;
    }
  }

  async shutdown(): Promise<void> {
    for (const w of this.workers) {
      w.unref();
      await w.terminate();
    }
  }
}

function resolveWorkerCount(explicit?: number): number {
  if (explicit !== undefined && explicit >= 0) return explicit;
  // Adaptive: half the logical CPUs, capped at 16.  The main loop and
  // socket I/O occupy one thread, Postgres another; the rest are available
  // for snapshot encoding.  Below 4 logical CPUs we keep it serial (faster
  // than the thread-spawn overhead).
  const logical = os.cpus?.()?.length ?? 1;
  if (logical < 4) return 0;
  return Math.min(Math.floor(logical / 2), 16);
}

function splitIntoChunks<T>(arr: T[], chunks: number): T[][] {
  const result: T[][] = [];
  const per = Math.ceil(arr.length / chunks);
  for (let i = 0; i < arr.length; i += per) {
    result.push(arr.slice(i, i + per));
  }
  return result;
}
