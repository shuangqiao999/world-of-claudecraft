// Gateway process main entry — sharding coordinator.
// Starts WebSocket + HTTP server, routes clients to zone processes.
//
//   GATEWAY_PORT=8787 INTERNAL_PORT=9000 node dist-server/gateway.cjs

import * as http from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { Gateway } from './gateway';

const gatewayPort = parseInt(process.env.GATEWAY_PORT ?? '8787', 10);
const internalPort = parseInt(process.env.INTERNAL_PORT ?? '9000', 10);

const gw = new Gateway({ internalPort, log: console.log });

// ── HTTP + WS server ──
const httpServer = http.createServer((req, res) => {
  const url = req.url ?? '/';
  if (url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, gateway: true, players_online: gw.clientCount }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true }));
});

const wss = new WebSocketServer({ noServer: true, maxPayload: 65536 });
const log = (msg: string) => console.log(msg);

httpServer.on('upgrade', (request, socket, head) => {
  wss.handleUpgrade(request, socket, head, (ws) => {
    let buffer = '';
    let authDone = false;

    const authTimer = setTimeout(() => {
      ws.send(JSON.stringify({ t: 'error', error: 'authentication timed out' }));
      ws.close();
    }, 10000);

    ws.on('message', (raw: Buffer) => {
      buffer += raw.toString('utf8');
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!authDone) {
          // First frame must be auth-world-5
          let msg: any;
          try { msg = JSON.parse(line); } catch { return; }
          if (msg.t !== 'auth-world-5' || !msg.token || !msg.character) {
            ws.send(JSON.stringify({ t: 'error', error: 'bad auth message' }));
            ws.close();
            return;
          }
          clearTimeout(authTimer);
          authDone = true;

          const characterId = msg.character as number;
          const playerId = characterId + 100000;
          const zoneId = 'eastbrook_vale';

          gw.registerClient(ws, playerId, characterId, zoneId);
          log(`gateway: player ${playerId} (char ${characterId}) -> zone ${zoneId}`);
          ws.send(JSON.stringify({ t: 'hello', id: playerId }));

          // Notify zone
          gw.sendToZone(zoneId, { type: 'client_msg', playerId, data: { t: 'join', characterId, token: msg.token } });
        } else {
          // Forward to zone
          try {
            const parsed = JSON.parse(line);
            gw.routeToZone(parsed);
          } catch {}
        }
      }
    });

    ws.on('close', () => {
      gw.unregisterClient(ws);
    });
  });
});

httpServer.listen(gatewayPort, () => {
  log(`gateway: http://localhost:${gatewayPort}`);
});

gw.start().then(() => {
  log('gateway: ready');
});

process.on('SIGINT', () => { gw.shutdown(); httpServer.close(); });
process.on('SIGTERM', () => { gw.shutdown(); httpServer.close(); });
