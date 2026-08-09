// Zone process communication integration for GameServer.
// When ZONES env var is set (zone-process mode), the server connects to a
// gateway via the internal TCP protocol for message relay.

import { ZoneClient, type ZoneClientOptions } from '../server/zone_comm/client';
import type { GwToZone } from '../server/zone_comm/protocol';

export interface ZoneProcessConfig {
  gatewayHost: string;
  gatewayPort: number;
  zones: string[];
}

export class ZoneProcessBridge {
  private client: ZoneClient;
  private onClientMsg: ((playerId: number, data: unknown) => void) | null = null;
  private onTransferIn: ((playerId: number, state: unknown) => void) | null = null;
  readonly zones: string[];

  constructor(private config: ZoneProcessConfig) {
    this.zones = config.zones;
    this.client = new ZoneClient({
      gatewayHost: config.gatewayHost,
      gatewayPort: config.gatewayPort,
      onMessage: (msg) => this.handleGatewayMessage(msg),
      log: console.log,
    });
  }

  private handleGatewayMessage(msg: GwToZone): void {
    switch (msg.type) {
      case 'client_msg':
        if (msg.playerId && msg.data) this.onClientMsg?.(msg.playerId, msg.data);
        break;
      case 'transfer_in':
        if (msg.playerId && msg.state) this.onTransferIn?.(msg.playerId, msg.state);
        break;
      case 'shutdown':
        console.log('[zone-bridge] shutdown received');
        break;
    }
  }

  onClientMessage(handler: (playerId: number, data: unknown) => void): void {
    this.onClientMsg = handler;
  }

  onTransferIncoming(handler: (playerId: number, state: unknown) => void): void {
    this.onTransferIn = handler;
  }

  /** Notify gateway that a player joined this zone process. */
  notifyPlayerJoined(playerId: number): void {
    this.client.send({ type: 'player_joined', playerId });
  }

  /** Notify gateway that a player left this zone process. */
  notifyPlayerLeft(playerId: number): void {
    this.client.send({ type: 'player_left', playerId });
  }

  /** Request transfer of a player to another zone. */
  requestTransfer(playerId: number, newZoneId: string): void {
    this.client.send({ type: 'transfer_out', playerId, newZoneId });
  }

  /** Send a broadcast message to the gateway (for player snapshots). */
  sendBroadcast(playerId: number, snap: string): void {
    this.client.send({ type: 'broadcast', playerId, snap });
  }

  start(): void {
    this.client.connect();
  }

  close(): void {
    this.client.close();
  }
}

/** Resolve zone-process config from env vars. */
export function resolveZoneConfig(): ZoneProcessConfig | null {
  const zones = (process.env.ZONES ?? '').split(',').map(z => z.trim()).filter(Boolean);
  if (zones.length === 0) return null;
  const gatewayHost = process.env.GATEWAY_HOST ?? '127.0.0.1';
  const gatewayPort = parseInt(process.env.GATEWAY_PORT ?? '9000', 10);
  return { gatewayHost, gatewayPort, zones };
}
