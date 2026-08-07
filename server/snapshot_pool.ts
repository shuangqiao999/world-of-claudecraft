// Snapshot worker thread pool for the broadcastSnapshots phase.
// Workers run on separate OS threads; the main loop blocks synchronously
// via Atomics.wait/notify until every worker has finished its batch.
//
// Adaptive default: when WOC_SNAPSHOT_WORKERS is unset, the pool uses
// Math.floor(os.cpus().length / 2) workers (capped at 16).  Set to 0 to
// disable and keep the serial broadcast path.

import { Worker } from 'node:worker_threads';
import os from 'node:os';
import path from 'node:path';

import type {
  BroadcastContext,
  EncodedEntity,
  SessionResult,
  SessionTask,
} from './snapshot_worker_core';

export interface SnapshotPoolOptions {
  workers?: number;
}

export class SnapshotPool {
  private workers: Worker[] = [];
  private pending: SessionResult[] = [];
  private doneCount = 0;
  private sab: SharedArrayBuffer | null = null;
  private barrier: Int32Array | null = null;
  private log: (msg: string) => void;

  constructor(opts: SnapshotPoolOptions, log: (msg: string) => void = () => {}) {
    this.log = log;
    const count = resolveWorkerCount(opts.workers);
    if (count <= 0) return;
    const workerPath = path.join(__dirname, 'snapshot_thread.cjs');
    for (let i = 0; i < count; i++) {
      const w = new Worker(workerPath);
      w.on('message', (reply: { results?: SessionResult[]; error?: string }) => {
        if (reply.results) {
          for (const r of reply.results) this.pending.push(r);
        }
        this.doneCount++;
        if (this.barrier) {
          Atomics.add(this.barrier, 0, 1);
        }
      });
      w.on('error', (err: Error) => {
        this.log(`snapshot worker error: ${err.message}`);
        this.doneCount++;
        if (this.barrier) {
          Atomics.add(this.barrier, 0, 1);
        }
      });
      this.workers.push(w);
    }
    this.log(`snapshot pool: ${count} workers`);
  }

  get active(): boolean {
    return this.workers.length > 0;
  }

  broadcast(
    ctx: BroadcastContext,
    entityEntries: [number, EncodedEntity][],
    tasks: SessionTask[],
  ): SessionResult[] {
    if (!this.active || tasks.length === 0) return [];
    const batches = splitIntoChunks(tasks, this.workers.length);
    const n = batches.length;
    this.pending = [];
    this.doneCount = 0;
    this.sab = new SharedArrayBuffer(4);
    this.barrier = new Int32Array(this.sab);

    // Fan work to workers — each gets the full entity map + its batch
    for (let i = 0; i < n; i++) {
      this.workers[i].postMessage({
        ctx,
        entityMap: entityEntries,
        tasks: batches[i],
      });
    }

    // Block until every worker signals completion
    while (this.doneCount < n) {
      Atomics.wait(this.barrier!, 0, this.doneCount);
    }

    const results = this.pending;
    this.pending = [];
    this.sab = null;
    this.barrier = null;
    return results;
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
  if (result.length > chunks) {
    // Merge extra chunks into the last
    while (result.length > chunks) {
      const last = result.pop()!;
      result[result.length - 1].push(...last);
    }
  }
  return result;
}
