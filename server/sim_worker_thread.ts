import { parentPort } from 'node:worker_threads';
import type { MessagePort } from 'node:worker_threads';
import {
  computePlayerSelfOnly,
  computeMobSelfOnly,
  type MobBatch,
  type MobMutation,
  type PlayerBatch,
  type PlayerMutation,
} from './sim_worker_core';

if (!parentPort) throw new Error('sim_worker_thread must run as a worker');

let replyPort: MessagePort | null = null;

parentPort.on('message', (msg: SimWorkerMessage) => {
  if ('type' in msg && msg.type === 'init' && msg.port) {
    replyPort = msg.port;
    return;
  }

  const { batch } = msg;
  try {
    let results: { playerMuts?: PlayerMutation[]; mobMuts?: MobMutation[] } = {};
    if (batch?.kind === 'players' && batch.data) {
      results.playerMuts = computePlayerSelfOnly(batch.data);
    } else if (batch?.kind === 'mobs' && batch.data) {
      results.mobMuts = computeMobSelfOnly(batch.data);
    }
    if (replyPort) {
      replyPort.postMessage({ results });
    }
  } catch (err) {
    if (replyPort) {
      replyPort.postMessage({ error: String(err) });
    }
  }
});

type SimWorkerMessage =
  | { type: 'init'; port: MessagePort }
  | { batch: SimTask };

interface SimTask {
  kind: 'players' | 'mobs';
  data: PlayerBatch | MobBatch;
  chunkIndex: number;
}
