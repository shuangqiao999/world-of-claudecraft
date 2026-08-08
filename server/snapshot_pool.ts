// Snapshot worker thread pool for the broadcastSnapshots phase.
// Workers run on separate OS threads; the main loop receives results
// synchronously via MessageChannel + receiveMessageOnPort, which does
// NOT require the Node event loop (unlike Atomics.wait + postMessage,
// which deadlocks because the blocked main thread cannot process
// worker.on('message') callbacks).
//
// Adaptive default: Math.floor(os.cpus().length / 2), capped at 16.

import { MessageChannel, Worker, receiveMessageOnPort } from 'node:worker_threads';
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

interface WorkerSlot {
  worker: Worker;
  port: any; // Node MessagePort (avoids TS name clash with global Web API MessagePort)
}

export class SnapshotPool {
  private slots: WorkerSlot[] = [];
  private log: (msg: string) => void;

  constructor(opts: SnapshotPoolOptions, log: (msg: string) => void = () => {}) {
    this.log = log;
    const count = resolveWorkerCount(opts.workers);
    if (count <= 0) return;
    const workerPath = path.join(__dirname, 'snapshot_thread.cjs');
    for (let i = 0; i < count; i++) {
      const w = new Worker(workerPath);
      const channel = new MessageChannel();
      w.postMessage({ type: 'init', port: channel.port2 }, [channel.port2]);
      w.on('error', (err: Error) => {
        this.log(`snapshot worker error: ${err.message}`);
      });
      this.slots.push({ worker: w, port: channel.port1 });
    }
    this.log(`snapshot pool: ${count} workers`);
  }

  get active(): boolean {
    return this.slots.length > 0;
  }

  broadcast(
    ctx: BroadcastContext,
    entityEntries: [number, EncodedEntity][],
    tasks: SessionTask[],
  ): SessionResult[] {
    if (!this.active || tasks.length === 0) return [];
    const batches = splitIntoChunks(tasks, this.slots.length);
    const allResults: SessionResult[] = [];

    // Fan work to workers — each gets the full entity map + its batch
    for (let i = 0; i < batches.length; i++) {
      this.slots[i].worker.postMessage({
        ctx,
        entityMap: entityEntries,
        tasks: batches[i],
      });
    }

    // Synchronously collect results from each worker via MessageChannel
    for (let i = 0; i < batches.length; i++) {
      const resp = receiveMessageOnPort(this.slots[i].port);
      if (!resp) {
        // Worker may have crashed; mark remaining as done
        continue;
      }
      const msg = (resp as any)?.message as { results?: SessionResult[]; error?: string } | undefined;
      if (msg?.error) {
        this.log(`snapshot worker error: ${msg.error}`);
      }
      if (msg?.results) {
        allResults.push(...msg.results);
      }
    }

    return allResults;
  }

  async shutdown(): Promise<void> {
    for (const s of this.slots) {
      s.worker.unref();
      await s.worker.terminate();
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
  while (result.length > 1 && result.length > chunks) {
    const last = result.pop()!;
    result[result.length - 1].push(...last);
  }
  return result;
}
