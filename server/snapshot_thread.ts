import { parentPort } from 'node:worker_threads';
import {
  computeSessionResults,
  type BroadcastContext,
  type EncodedEntity,
  type SessionResult,
  type SessionTask,
} from './snapshot_worker_core';

if (!parentPort) throw new Error('This file must be run as a worker');

interface WorkerMessage {
  ctx: BroadcastContext;
  entityMap: [number, EncodedEntity][];
  tasks: SessionTask[];
}

parentPort.on('message', (msg: WorkerMessage) => {
  const { ctx, entityMap: entries, tasks } = msg;
  try {
    const entityMap = new Map(entries);
    const results: SessionResult[] = computeSessionResults(ctx, entityMap, tasks);
    parentPort!.postMessage({ results });
  } catch (err) {
    parentPort!.postMessage({ error: String(err) });
  }
});
