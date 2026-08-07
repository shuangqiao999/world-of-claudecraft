// Snapshot worker entry for the worker_threads pool.
// When the parallel broadcast path is activated, workers receive pre-computed
// entity wire JSONs and session sim readouts from the main thread, then
// assemble per-session snapshot JSON strings and return updated session delta
// state via postMessage.

import { parentPort } from 'node:worker_threads';
import type { BroadcastContext, SessionBundle, SessionSnapshot } from './snapshot_worker_core';

if (!parentPort) throw new Error('This file must be run as a worker');

parentPort.on('message', (msg: { ctx: BroadcastContext; bundles: SessionBundle[]; id: number }) => {
  const { ctx, bundles, id } = msg;
  try {
    // Placeholder: the parallel snapshot assembly will be extracted from
    // game.ts broadcastSnapshots in a follow-on integration.  For now
    // workers return nothing and the main thread uses the serial path.
    parentPort!.postMessage({
      id,
      results: bundles.map((b) => ({ pid: b.anchor.pid, json: '', state: b.state } as SessionSnapshot)),
    });
  } catch (err) {
    parentPort!.postMessage({ id, error: String(err) });
  }
});
