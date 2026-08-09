// Sim worker thread pool for parallel self-only entity computations.
// Follows the SnapshotPool pattern: MessageChannel + receiveMessageOnPort
// for synchronous result collection without event-loop deadlock.
//
// Adaptive default: Math.floor(os.cpus().length / 2), min 2, capped at 8.
// Zero workers when cpuCount < 4 (fallback to main-thread serial).

import { MessageChannel, Worker, receiveMessageOnPort } from 'node:worker_threads';
import os from 'node:os';
import path from 'node:path';

import type {
  MobBatch,
  MobMutation,
  PlayerBatch,
  PlayerMutation,
} from './sim_worker_core';

export interface SimWorkerPoolOptions {
  workers?: number;
}

interface WorkerSlot {
  worker: Worker;
  port: any;
}

export class SimWorkerPool {
  private slots: WorkerSlot[] = [];
  private log: (msg: string) => void;

  constructor(opts: SimWorkerPoolOptions = {}, log: (msg: string) => void = () => {}) {
    this.log = log;
    const count = resolveWorkerCount(opts.workers);
    if (count <= 0) return;
    const workerPath = path.join(__dirname, 'sim_worker_thread.cjs');
    for (let i = 0; i < count; i++) {
      const w = new Worker(workerPath);
      const channel = new MessageChannel();
      w.postMessage({ type: 'init', port: channel.port2 }, [channel.port2]);
      w.on('error', (err: Error) => {
        this.log(`sim worker error: ${err.message}`);
      });
      this.slots.push({ worker: w, port: channel.port1 });
    }
    this.log(`sim pool: ${count} workers`);
  }

  get active(): boolean {
    return this.slots.length > 0;
  }

  /** Run player self-only computations in parallel. Returns mutations keyed by entity id. */
  computePlayers(batch: PlayerBatch): Map<number, PlayerMutation> {
    if (!this.active) {
      // Fallback: compute on main thread
      const muts = require('./sim_worker_core').computePlayerSelfOnly(batch);
      return new Map(muts.map((m: PlayerMutation) => [m.id, m]));
    }
    const chunks = splitIntoChunks(batch.slices, this.slots.length);
    const result = new Map<number, PlayerMutation>();

    for (let i = 0; i < chunks.length; i++) {
      this.slots[i].worker.postMessage({
        batch: { kind: 'players', data: { ...batch, slices: chunks[i] }, chunkIndex: i },
      });
    }

    for (let i = 0; i < chunks.length; i++) {
      const resp = receiveMessageOnPort(this.slots[i].port);
      if (!resp) continue;
      const msg = (resp as any)?.message as { results?: { playerMuts?: PlayerMutation[] }; error?: string } | undefined;
      if (msg?.error) {
        this.log(`sim worker error: ${msg.error}`);
        continue;
      }
      if (msg?.results?.playerMuts) {
        for (const m of msg.results.playerMuts) {
          result.set(m.id, m);
        }
      }
    }

    return result;
  }

  /** Run mob self-only computations in parallel. Returns mutations keyed by entity id. */
  computeMobs(batch: MobBatch): Map<number, MobMutation> {
    if (!this.active) {
      const muts = require('./sim_worker_core').computeMobSelfOnly(batch);
      return new Map(muts.map((m: MobMutation) => [m.id, m]));
    }
    const chunks = splitIntoChunks(batch.slices, this.slots.length);
    const result = new Map<number, MobMutation>();

    for (let i = 0; i < chunks.length; i++) {
      this.slots[i].worker.postMessage({
        batch: { kind: 'mobs', data: { ...batch, slices: chunks[i] }, chunkIndex: i },
      });
    }

    for (let i = 0; i < chunks.length; i++) {
      const resp = receiveMessageOnPort(this.slots[i].port);
      if (!resp) continue;
      const msg = (resp as any)?.message as { results?: { mobMuts?: MobMutation[] }; error?: string } | undefined;
      if (msg?.error) {
        this.log(`sim worker error: ${msg.error}`);
        continue;
      }
      if (msg?.results?.mobMuts) {
        for (const m of msg.results.mobMuts) {
          result.set(m.id, m);
        }
      }
    }

    return result;
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
  if (logical < 4) return 0; // fallback to serial for small machines
  return Math.min(logical, 32);
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
