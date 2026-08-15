import type { MessagePort } from 'node:worker_threads';
import { parentPort } from 'node:worker_threads';
import { computeZoneBatch, type ZoneBatch, type ZoneResult } from './zone_worker_core';

if (!parentPort) throw new Error('zone_worker_thread must run as a worker');

let replyPort: MessagePort | null = null;

parentPort.on('message', (msg: ZoneWorkerMessage) => {
  if ('type' in msg) {
    if (msg.port) replyPort = msg.port;
    return;
  }

  const { batch } = msg;
  try {
    const result = computeZoneBatch(batch);
    if (replyPort) {
      replyPort.postMessage({ result });
    }
  } catch (err) {
    if (replyPort) {
      replyPort.postMessage({ error: String(err) });
    }
  }
});

type ZoneWorkerMessage = { type: 'init'; port: MessagePort } | { batch: ZoneBatch };
