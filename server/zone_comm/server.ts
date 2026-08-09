// TCP server: Gateway → Zone Processes.
// Manages connections from zone processes, routes messages, handles player registry.

import * as net from 'node:net';
import { encodeFrame, decodeFrame, type GwToZone, type ZoneToGw } from './protocol';

export interface ZoneServerOptions {
  port: number;
  log?: (msg: string) => void;
}

export interface ZoneConnection {
  socket: net.Socket;
  zoneIds: string[];
}

export class ZoneServer {
  private server: net.Server;
  private connections = new Map<string, ZoneConnection>(); // zoneId → connection
  private zoneGroups = new Map<net.Socket, string[]>();    // socket → zoneIds
  public onMessage: ((zoneId: string, msg: ZoneToGw, socket: net.Socket) => void) | null = null;
  private opts: ZoneServerOptions;

  constructor(opts: ZoneServerOptions) {
    this.opts = opts;
    this.server = net.createServer((socket) => this.handleConnection(socket));
  }

  private handleConnection(socket: net.Socket): void {
    let buffer = '';
    const remoteAddr = `${socket.remoteAddress}:${socket.remotePort}`;
    this.opts.log?.(`[zone-server] zone connected: ${remoteAddr}`);

    socket.on('data', (data: Buffer) => {
      buffer += data.toString('utf-8');
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';

      for (const line of lines) {
        const msg = decodeFrame(line);
        if (!msg) continue;
        const zm = msg as ZoneToGw;

        // On first message, register the zone(s)
        if (zm.type === 'player_joined' || zm.type === 'broadcast') {
          // Auto-register: the zone is derived from the message later
        }

        if (this.onMessage) {
          // Find which zone ID to use — use the connection's registered zones
          const zoneIds = this.zoneGroups.get(socket) ?? [];
          const zoneId = zoneIds[0] ?? 'unknown';
          this.onMessage(zoneId, zm, socket);
        }
      }
    });

    socket.on('close', () => {
      const zoneIds = this.zoneGroups.get(socket) ?? [];
      for (const zid of zoneIds) this.connections.delete(zid);
      this.zoneGroups.delete(socket);
      this.opts.log?.(`[zone-server] zone disconnected: ${remoteAddr} zones=${zoneIds.join(',') || 'none'}`);
    });

    socket.on('error', (err: Error) => {
      this.opts.log?.(`[zone-server] error ${remoteAddr}: ${err.message}`);
    });
  }

  registerZones(socket: net.Socket, zoneIds: string[]): void {
    this.zoneGroups.set(socket, zoneIds);
    for (const zid of zoneIds) this.connections.set(zid, { socket, zoneIds });
  }

  sendToZone(zoneId: string, msg: GwToZone): void {
    const conn = this.connections.get(zoneId);
    if (!conn || conn.socket.destroyed) return;
    try { conn.socket.write(encodeFrame(msg)); } catch {}
  }

  broadcastToAll(msg: GwToZone): void {
    for (const conn of this.connections.values()) {
      try { conn.socket.write(encodeFrame(msg)); } catch {}
    }
  }

  start(): Promise<void> {
    return new Promise((resolve) => {
      this.server.listen(this.opts.port, () => {
        this.opts.log?.(`[zone-server] listening on port ${this.opts.port}`);
        resolve();
      });
    });
  }

  close(): void {
    this.server.close();
  }
}
