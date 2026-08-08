import { parentPort } from 'node:worker_threads';
import type { MessagePort } from 'node:worker_threads';
import {
  computeSessionResults,
  type BroadcastContext,
  type EncodedEntity,
  type SessionResult,
  type SessionTask,
} from './snapshot_worker_core';

if (!parentPort) throw new Error('This file must be run as a worker');

// MessagePort the main thread transferred to us at init
let replyPort: MessagePort | null = null;

parentPort.on('message', (msg: { type?: string; port?: MessagePort } | WorkerMessage) => {
  // Init message: receive the port for sync reply
  if ('type' in msg && msg.type === 'init' && msg.port) {
    replyPort = msg.port;
    return;
  }

  const { ctx, entityMap: entries, tasks } = msg as WorkerMessage;
  try {
    const entityMap = new Map(entries);
    const results: SessionResult[] = computeSessionResults(ctx, entityMap, tasks);
    if (replyPort) {
      replyPort.postMessage({ results });
    }
  } catch (err) {
    if (replyPort) {
      replyPort.postMessage({ error: String(err) });
    }
  }
});

interface WorkerMessage {
  ctx: BroadcastContext;
  entityMap: [number, EncodedEntity][];
  tasks: SessionTask[];
}
