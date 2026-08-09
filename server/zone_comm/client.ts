// TCP client: Zone Process → Gateway.
// Used inside a zone process to relay player messages and events to the gateway.

import * as net from 'node:net';
import { encodeFrame, decodeFrame, type ZoneToGw, type GwToZone } from './protocol';

export interface ZoneClientOptions {
  gatewayHost: string;
  gatewayPort: number;
  onMessage: (msg: GwToZone) => void;
  log?: (msg: string) => void;
}

export class ZoneClient {
  private socket: net.Socket | null = null;
  private buffer = '';
  private opts: ZoneClientOptions;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private closed = false;

  constructor(opts: ZoneClientOptions) {
    this.opts = opts;
  }

  connect(): void {
    if (this.closed) return;
    this.opts.log?.('[zone-client] connecting to gateway...');
    this.socket = net.createConnection({ host: this.opts.gatewayHost, port: this.opts.gatewayPort }, () => {
      this.opts.log?.('[zone-client] connected to gateway');
    });
    this.socket.on('data', (data: Buffer) => {
      this.buffer += data.toString('utf-8');
      const lines = this.buffer.split('\n');
      this.buffer = lines.pop() ?? '';
      for (const line of lines) {
        const msg = decodeFrame(line);
        if (msg) this.opts.onMessage(msg as GwToZone);
      }
    });
    this.socket.on('close', () => {
      if (!this.closed) {
        this.opts.log?.('[zone-client] disconnected, reconnecting in 2s...');
        this.reconnectTimer = setTimeout(() => this.connect(), 2000);
      }
    });
    this.socket.on('error', (err: Error) => {
      this.opts.log?.(`[zone-client] error: ${err.message}`);
    });
  }

  send(msg: ZoneToGw): void {
    if (!this.socket || this.socket.destroyed) return;
    try { this.socket.write(encodeFrame(msg)); } catch {}
  }

  close(): void {
    this.closed = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.socket) { this.socket.destroy(); this.socket = null; }
  }
}
