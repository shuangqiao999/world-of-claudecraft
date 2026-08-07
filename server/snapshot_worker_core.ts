// Pure snapshot-building types shared between the main thread and worker
// threads.  The types define the data contract for the parallel broadcast
// path; the actual per-session computation functions will be extracted from
// game.ts broadcastSnapshots when the parallel path is activated.
//
// When the worker pool is enabled (WOC_SNAPSHOT_WORKERS), the main thread
// pre-computes every session's sim readout and every candidate entity's
// wire encodings, then distributes session batches to workers via the
// SnapshotPool.  Workers assemble the final snapshot JSON strings from
// pre-computed pieces and return updated per-session delta state.

import type { SimReadout } from '../src/sim/sim_readout';

// ---------- wire encoding for a single entity variant ----------
export interface WireVariant {
  full: string;
  fullAura: string;
  lite: string;
  liteAura: string;
}

// ---------- worker session state (mirrors ClientSession delta fields) ----------
export interface SessionSnapshotState {
  pid: number;
  sentEnts: Array<[number, { idVer: number; dynVer: number; auraVer: number; sentAtTick: number; settled: boolean }]>;
  lastSent: Record<string, string>;
}

// ---------- per-session input bundle ----------
export interface SessionBundle {
  state: SessionSnapshotState;
  anchor: { pid: number; id: number };
  simReadout: SimReadout;
}

// ---------- global broadcast context ----------
export interface BroadcastContext {
  tick: number;
  time: number;
  head: string;
}

// ---------- per-session output ----------
export interface SessionSnapshot {
  pid: number;
  json: string;
  state: SessionSnapshotState;
}
