// Gateway process entry point: WebSocket acceptor + zone routing.
// Reuses `ws_auth.ts` for auth handshake, then routes players to zone processes
// based on their character's current zone (from the DB-saved position).
//
//   ZONES=eastbrook_vale,mirefen_marsh ZONE_PORT=9001 GATEWAY_PORT=8787 node dist-server/gateway.cjs

import { ZoneServer } from './zone_comm/server';
import type { GwToZone, ZoneToGw } from './zone_comm/protocol';

interface GatewayConfig {
  gatewayPort: number;
  internalPort: number;
  log?: (msg: string) => void;
}

class Gateway {
  private zoneServer: ZoneServer;
  // Maps playerId → zoneId for message routing
  private playerRouting = new Map<number, string>();

  constructor(private config: GatewayConfig) {
    this.zoneServer = new ZoneServer({
      port: config.internalPort,
      log: config.log,
    });

    this.zoneServer.onMessage = (zoneId, msg, socket) => {
      this.handleZoneMessage(zoneId, msg, socket);
    };
  }

  private handleZoneMessage(zoneId: string, msg: ZoneToGw, _socket: unknown): void {
    switch (msg.type) {
      case 'transfer_out': {
        const playerId = msg.playerId!;
        const newZoneId = msg.newZoneId!;
        // Update routing table — player will be re-routed by the zone process
        this.playerRouting.set(playerId, newZoneId);
        this.config.log?.(`[gateway] player ${playerId} transfer: ${zoneId} → ${newZoneId}`);
        break;
      }
      case 'player_joined': {
        const playerId = msg.playerId!;
        this.playerRouting.set(playerId, zoneId);
        break;
      }
      case 'player_left': {
        const playerId = msg.playerId!;
        this.playerRouting.delete(playerId);
        break;
      }
      default:
        // Forward other messages (broadcast, etc.) to the client handler
        break;
    }
  }

  /** Route a client message to the correct zone process. */
  routePlayerMessage(playerId: number, zoneId: string, data: unknown): void {
    const msg: GwToZone = { type: 'client_msg', playerId, data };
    this.zoneServer.sendToZone(zoneId, msg);
  }

  /** Tell a zone process to accept a transferring player. */
  sendTransferIn(zoneId: string, playerId: number, state: unknown): void {
    const msg: GwToZone = { type: 'transfer_in', playerId, state };
    this.zoneServer.sendToZone(zoneId, msg);
  }

  /** Shutdown notification to all zone processes. */
  shutdown(): void {
    this.zoneServer.broadcastToAll({ type: 'shutdown' });
    this.zoneServer.close();
  }

  async start(): Promise<void> {
    await this.zoneServer.start();
    this.config.log?.('[gateway] zone server started');
  }
}

export { Gateway };
export type { GatewayConfig };
