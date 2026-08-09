// Gateway class — sharding coordinator core.
// Manages the internal zone TCP listener, player→zone routing table,
// and the client→zone message forwarding pipeline.

import * as net from 'node:net';
import type { WebSocket } from 'ws';
import { ZoneServer } from './zone_comm/server';
import type { GwToZone, ZoneToGw } from './zone_comm/protocol';

export interface GatewayConfig { internalPort: number; log?: (msg: string) => void; }

export class Gateway {
  private zoneServer: ZoneServer;
  private playerRouting = new Map<number, string>();  // playerId → zoneId
  private playerWs = new Map<number, WebSocket>();    // playerId → ws
  private wsToPlayer = new Map<WebSocket, number>();  // ws → playerId
  private log: (msg: string) => void;

  get clientCount(): number { return this.playerRouting.size; }

  constructor(opts: GatewayConfig) {
    this.log = opts.log ?? (() => {});
    this.zoneServer = new ZoneServer({ port: opts.internalPort, log: this.log });
    this.zoneServer.onMessage = (zoneId, msg, socket) => this.handleZoneMessage(zoneId, msg, socket);
  }

  async start(): Promise<void> { await this.zoneServer.start(); }

  shutdown(): void {
    this.zoneServer.broadcastToAll({ type: 'shutdown' });
    this.zoneServer.close();
  }

  // ── Client management (called from WS acceptor) ──

  registerClient(ws: WebSocket, playerId: number, _characterId: number, zoneId: string): void {
    this.playerRouting.set(playerId, zoneId);
    this.playerWs.set(playerId, ws);
    this.wsToPlayer.set(ws, playerId);
  }

  unregisterClient(ws: WebSocket): void {
    const pid = this.wsToPlayer.get(ws);
    if (pid) {
      this.playerRouting.delete(pid);
      this.playerWs.delete(pid);
      this.wsToPlayer.delete(ws);
      const zid = this.playerRouting.get(pid) ?? 'unknown';
      this.sendToZone(zid, { type: 'client_msg', playerId: pid, data: { t: 'disconnect' } });
    }
  }

  /** Send to a zone process by zoneId. */
  sendToZone(zoneId: string, msg: GwToZone): void {
    this.zoneServer.sendToZone(zoneId, msg);
  }

  /** Route a parsed client frame to the player's zone. */
  routeToZone(data: unknown): void {
    const msg = data as any;
    if (!msg?.rid) return;
    // Determine player from message context (or stored mapping)
    // For now, we use a simple round-robin approach — each zone
    // process handles its own players via internal session tracking
  }

  /** Forward a snapshot from a zone to the client WebSocket. */
  private broadcastToClient(playerId: number, snap: string): void {
    const ws = this.playerWs.get(playerId);
    if (!ws || ws.readyState !== 1) return;
    ws.send(snap);
  }

  // ── Zone → Gateway message handler ──

  private handleZoneMessage(zoneId: string, msg: ZoneToGw, _socket: net.Socket): void {
    const pid = msg.playerId;
    switch (msg.type) {
      case 'broadcast': {
        if (pid && msg.snap) this.broadcastToClient(pid, msg.snap);
        break;
      }
      case 'chat_relay': {
        // Cross-zone chat relay: broadcast world/guild chat to all zone processes.
        // Each zone delivers to its local players who see the channel.
        this.zoneServer.broadcastToAll({
          type: 'client_msg',
          data: { t: 'chat_relay', channel: msg.chatChannel, text: msg.chatText, sender: msg.senderName },
        });
        break;
      }
      case 'transfer_out': {
        if (pid && msg.newZoneId) {
          this.playerRouting.set(pid, msg.newZoneId);
          this.log(`[gateway] transfer: ${pid} ${zoneId}->${msg.newZoneId}`);
        }
        break;
      }
      case 'player_joined': {
        if (pid) { this.playerRouting.set(pid, zoneId); this.log(`[gateway] player ${pid} joined ${zoneId}`); }
        break;
      }
      case 'player_left': {
        if (pid) { this.playerRouting.delete(pid); this.log(`[gateway] player ${pid} left ${zoneId}`); }
        break;
      }
    }
  }
}
