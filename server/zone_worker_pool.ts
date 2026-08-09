// Zone worker thread pool for parallel per-zone entity processing.
// Same MessageChannel + receiveMessageOnPort pattern as SnapshotPool
// and SimWorkerPool.  Workers are assigned to zones dynamically: a
// busy zone gets a dedicated worker, idle zones share.
//
// Adaptive: up to Math.min(os.cpus().length, 32) workers.
// Fallback to serial for < 4 CPUs.

import { MessageChannel, Worker, receiveMessageOnPort } from 'node:worker_threads';
import os from 'node:os';
import path from 'node:path';
import type { ZoneBatch, ZoneResult } from './zone_worker_core';

export interface ZoneWorkerPoolOptions {
  workers?: number;
}

interface WorkerSlot {
  worker: Worker;
  port: any;
}

export class ZoneWorkerPool {
  private slots: WorkerSlot[] = [];
  private log: (msg: string) => void;

  constructor(opts: ZoneWorkerPoolOptions = {}, log: (msg: string) => void = () => {}) {
    this.log = log;
    const count = resolveWorkerCount(opts.workers);
    if (count <= 0) return;
    const workerPath = path.join(__dirname, 'zone_worker_thread.cjs');
    for (let i = 0; i < count; i++) {
      const w = new Worker(workerPath);
      const channel = new MessageChannel();
      w.postMessage({ type: 'init', port: channel.port2 }, [channel.port2]);
      w.on('error', (err: Error) => {
        this.log(`zone worker error: ${err.message}`);
      });
      this.slots.push({ worker: w, port: channel.port1 });
    }
    this.log(`zone pool: ${count} workers`);
  }

  get active(): boolean {
    return this.slots.length > 0;
  }

  get workerCount(): number {
    return this.slots.length;
  }

  /** Process multiple zone batches in parallel. Returns results keyed by zoneId. */
  computeZones(batches: ZoneBatch[]): Map<string, ZoneResult> {
    if (!this.active || batches.length === 0) {
      const results = new Map<string, ZoneResult>();
      if (batches.length > 0) {
        const { computeZoneBatch } = require('./zone_worker_core');
        for (const b of batches) results.set(b.zoneId, computeZoneBatch(b));
      }
      return results;
    }

    // Adaptive: assign one batch per worker, round-robin extra batches
    const assigned: { workerIdx: number; batch: ZoneBatch }[] = [];
    for (let i = 0; i < batches.length; i++) {
      assigned.push({ workerIdx: i % this.slots.length, batch: batches[i] });
    }

    // Fan out
    for (const { workerIdx, batch } of assigned) {
      this.slots[workerIdx].worker.postMessage({ batch });
    }

    // Collect with time-bounded spin. Track pending by batch index (not by
    // worker) so that round-robin reuse of a worker for multiple batches
    // doesn't silently drop results after the first batch is collected.
    const results = new Map<string, ZoneResult>();
    const pending = new Set<number>(assigned.map((_, i) => i));
    const collected = new Set<string>();
    const deadline = Date.now() + 45;
    while (pending.size > 0 && collected.size < batches.length && Date.now() < deadline) {
      for (const batchIdx of pending) {
        const { workerIdx } = assigned[batchIdx];
        const resp = receiveMessageOnPort(this.slots[workerIdx].port);
        if (!resp) continue;
        const msg = (resp as any)?.message as { result?: ZoneResult; error?: string } | undefined;
        if (msg?.error) {
          this.log(`zone worker error: ${msg.error}`);
          pending.delete(batchIdx);
          continue;
        }
        if (msg?.result) {
          results.set(msg.result.zoneId, msg.result);
          collected.add(msg.result.zoneId);
          pending.delete(batchIdx);
        }
      }
    }

    // Any still-pending batches after the deadline are silently dropped.
    // Their entities stay on the main thread for this tick (no mutations applied).
    if (pending.size > 0) {
      this.log(`zone pool: ${pending.size} worker(s) timed out, ${collected.size}/${batches.length} collected`);
    }

    return results;
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
  return Math.min(logical, 32);
}
