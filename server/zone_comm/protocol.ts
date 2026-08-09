// Internal protocol for Gateway ↔ Zone Process communication.
// Uses JSON-over-TCP with newline-delimited frames.

export const INTERNAL_PROTOCOL_VERSION = 1;

// ── Gateway → Zone Process messages ──

export interface GwToZone {
  type: 'client_msg' | 'transfer_in' | 'shutdown' | 'ping';
  playerId?: number;
  data?: unknown;         // client message payload for 'client_msg'
  state?: unknown;        // CharacterState for 'transfer_in'
}

// ── Zone Process → Gateway messages ──

export interface ZoneToGw {
  type: 'broadcast' | 'transfer_out' | 'player_joined' | 'player_left' | 'pong' | 'error' | 'chat_relay';
  playerId?: number;
  snap?: string;
  newZoneId?: string;
  reason?: string;
  chatText?: string;
  chatChannel?: string;
  senderName?: string;
}

// ── Frame helpers ──

const DELIMITER = '\n';

export function encodeFrame(msg: GwToZone | ZoneToGw): string {
  return JSON.stringify(msg) + DELIMITER;
}

export function decodeFrame(data: string): (GwToZone | ZoneToGw) | null {
  const trimmed = data.trim();
  if (!trimmed) return null;
  try { return JSON.parse(trimmed); } catch { return null; }
}
