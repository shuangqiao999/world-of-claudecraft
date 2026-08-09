// Gateway process main entry — sharding coordinator.
// WebSocket acceptor + auth + zone routing.
//
//   GATEWAY_PORT=8787 INTERNAL_PORT=9000 DATABASE_URL=... node dist-server/gateway.cjs

import * as http from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { Gateway } from './gateway';
import { accountAndScopeForToken, getCharacter } from './db';
import { zoneAt } from '../src/sim/data';
import { ONLINE_WORLD_AUTH_TYPE } from '../src/world_api';

const gatewayPort = parseInt(process.env.GATEWAY_PORT ?? '8787', 10);
const internalPort = parseInt(process.env.INTERNAL_PORT ?? '9000', 10);

const log = (msg: string) => console.log(`[gateway] ${msg}`);
const gw = new Gateway({ internalPort, log });

// ── HTTP server ──
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
        if (authDone) {
          try { gw.routeToClient(ws, JSON.parse(line)); } catch {}
          return;
        }
        // ── Auth frame ──
        let msg: any;
        try { msg = JSON.parse(line); } catch { return; }
        if (msg.t !== ONLINE_WORLD_AUTH_TYPE || !msg.token || !msg.character) {
          ws.send(JSON.stringify({ t: 'error', error: 'bad auth message' }));
          ws.close();
          return;
        }
        clearTimeout(authTimer);

        const characterId = msg.character as number;
        const token = msg.token as string;

        // Async auth — must not block the WS read loop
        (async () => {
          try {
            // 1. Verify token → account
            const account = await accountAndScopeForToken(token, 'online');
            if (!account) {
              ws.send(JSON.stringify({ t: 'error', error: 'not authenticated' }));
              ws.close();
              return;
            }

            // 2. Look up character
            const row = await getCharacter(account.id, characterId);
            if (!row) {
              ws.send(JSON.stringify({ t: 'error', error: 'no such character' }));
              ws.close();
              return;
            }

            // 3. Determine zone from saved position
            let state: any = {};
            try { state = typeof row.state === 'string' ? JSON.parse(row.state) : (row.state ?? {}); } catch {}
            const pos = state?.pos ?? { x: 0, z: 0 };
            const zone = zoneAt(pos.x ?? 0, pos.z ?? 0);
            const zoneId = zone?.id ?? 'eastbrook_vale';

            // 4. Generate stable playerId (characterId is unique, use as session key)
            // The zone process will map gateway playerId → sim entity pid via game.join()
            const playerId = characterId;

            authDone = true;
            gw.registerClient(ws, playerId, characterId, zoneId);
            log(`player ${playerId} (${row.name}, Lv${row.level} ${row.class}) → zone ${zoneId}`);
            ws.send(JSON.stringify({
              t: 'hello',
              id: playerId,
              name: row.name,
              class: row.class,
              level: row.level,
            }));

            // 5. Forward join to zone process
            gw.sendToZone(zoneId, {
              type: 'client_msg',
              playerId,
              data: {
                t: 'join',
                characterId,
                token,
                accountId: account.id,
                name: row.name,
                class: row.class,
                state: row.state,
                level: row.level,
              },
            });
          } catch (err: any) {
            log(`auth error: ${err.message}`);
            ws.send(JSON.stringify({ t: 'error', error: 'authentication failed' }));
            ws.close();
          }
        })();
      }
    });

    ws.on('close', () => gw.unregisterClient(ws));
  });
});

httpServer.listen(gatewayPort, () => {
  log(`http://localhost:${gatewayPort}`);
  log(`internal TCP on port ${internalPort}`);
});

gw.start().then(() => log('ready'));

process.on('SIGINT', () => { gw.shutdown(); httpServer.close(); process.exit(0); });
process.on('SIGTERM', () => { gw.shutdown(); httpServer.close(); process.exit(0); });
