// Zone Bridge — runs inside a zone process, relays messages between
// the Gateway and the local GameServer.  When ZONES is set, replaces
// the browser's WS with an internal TCP channel to the Gateway.
//
// Lifecycle:
//   bridge = new ZoneProcessBridge(getZoneConfig())
//   bridge.onClientFrame = (pid, data) => game.dispatchGatewayMessage(pid, data)
//   bridge.onJoinRequest = (pid, cid, token) => game.handleGatewayJoin(pid, cid, token)
//   bridge.start()

import { ZoneClient } from '../server/zone_comm/client';
import type { GwToZone, ZoneToGw } from '../server/zone_comm/protocol';

export interface ZoneProcessConfig {
  gatewayHost: string;
  gatewayPort: number;
  zones: string[];
}

export class ZoneProcessBridge {
  private client: ZoneClient;
  readonly zones: string[];
  private log: (msg: string) => void;
  private queuedMessages: { playerId: number; data: unknown }[] = [];
  private ready = false;

  onClientFrame: ((playerId: number, data: unknown) => void) | null = null;
  onJoinRequest: ((playerId: number, characterId: number, token: string,
    accountId: number, name: string, cls: string, state: any, level: number) => void) | null = null;
  onChatRelay: ((channel: string, text: string, sender: string) => void) | null = null;

  constructor(config: ZoneProcessConfig, log: (msg: string) => void = console.log) {
    this.log = log;
    this.zones = config.zones;

    this.client = new ZoneClient({
      gatewayHost: config.gatewayHost,
      gatewayPort: config.gatewayPort,
      onMessage: (msg) => this.handleGatewayMessage(msg),
      log,
    });
  }

  private handleGatewayMessage(msg: GwToZone): void {
    switch (msg.type) {
      case 'client_msg': {
        const pid = msg.playerId!;
        const data = msg.data as any;
        if (!this.ready) {
          this.queuedMessages.push({ playerId: pid, data });
          return;
        }
        // Join request: gateway sends { t: 'join', characterId, token }
        if (data?.t === 'join' && data?.characterId) {
          this.onJoinRequest?.(
            pid, data.characterId, data.token ?? '',
            data.accountId ?? 0, data.name ?? '', data.class ?? '',
            data.state ?? {}, data.level ?? 1
          );
        } else if (data?.t === 'chat_relay') {
          // Gateway relayed cross-zone chat: deliver to local players
          this.onChatRelay?.(data.channel ?? 'world', data.text ?? '', data.sender ?? '');
        } else if (data?.t === 'disconnect') {
          this.log(`[bridge] player ${pid} gateway disconnect`);
        } else {
          this.onClientFrame?.(pid, data);
        }
        break;
      }
      case 'transfer_in':
        this.log(`[bridge] transfer_in player ${msg.playerId}`);
        break;
      case 'shutdown':
        this.log('[bridge] shutdown from gateway');
        break;
    }
  }

  notifyReady(): void {
    this.ready = true;
    // Flush queued join messages received before the sim was ready
    for (const q of this.queuedMessages) {
      const data = q.data as any;
      if (data?.t === 'join' && data?.characterId) {
        this.onJoinRequest?.(q.playerId, data.characterId, data.token);
      }
    }
    this.queuedMessages.length = 0;
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

  /** Send a snapshot to the gateway for forwarding to the client. */
  relaySnapshot(playerId: number, snap: string): void {
    this.client.send({ type: 'broadcast', playerId, snap });
  }

  /** Relay cross-zone world/guild chat through the gateway. */
  relayChat(channel: string, text: string, senderName: string): void {
    this.client.send({ type: 'chat_relay', chatChannel: channel, chatText: text, senderName });
  }

  start(): void {
    this.client.connect();
  }

  close(): void {
    this.client.close();
  }
}

/** Read zone-process config from env. Returns null if ZONES is not set. */
export function resolveZoneConfig(): ZoneProcessConfig | null {
  const zones = (process.env.ZONES ?? '').split(',').map(z => z.trim()).filter(Boolean);
  if (zones.length === 0) return null;
  const gatewayHost = process.env.GATEWAY_HOST ?? '127.0.0.1';
  const gatewayPort = parseInt(process.env.GATEWAY_PORT ?? '9000', 10);
  return { gatewayHost, gatewayPort, zones };
}
