// Client-side Sproto binary decoder — hardcoded for our 7 message types.
// Reads the exact binary format produced by the Lua sproto.core:encode().
// Produces objects identical to the JSON.parse output of old text frames.
// Injected at src/net/online.ts onMessage() — detects binary ArrayBuffer vs text string.

type WireValue = number | string | boolean | WireObj | WireArr;
type WireObj = Record<string, WireValue>;
type WireArr = WireValue[];

// ---- varint helpers ----
function readVarint(buf: Uint8Array, off: number): [number, number] {
  let result = 0, shift = 0;
  while (true) {
    const b = buf[off++];
    result |= (b & 0x7f) << shift;
    if ((b & 0x80) === 0) break;
    shift += 7;
  }
  return [result >>> 0, off];
}

function readDouble(buf: Uint8Array, off: number): [number, number] {
  // Sproto doubles may be encoded as integers * 100 (for our snap frame)
  const [val, next] = readVarint(buf, off);
  // Try as integer first (server sends scaled ints), fall back to raw bytes
  if (next - off <= 8) return [val, next];
  const dv = new DataView(buf.buffer, buf.byteOffset + off, 8);
  return [dv.getFloat64(0, true), off + 8];
}

function readString(buf: Uint8Array, off: number): [string, number] {
  const [len, p1] = readVarint(buf, off);
  let s = '';
  for (let i = 0; i < len; i++) s += String.fromCharCode(buf[p1 + i]);
  return [s, p1 + len];
}

function readBool(buf: Uint8Array, off: number): [boolean, number] {
  const [v, next] = readVarint(buf, off);
  return [v !== 0, next];
}

// ---- field-level decode ----
interface FieldDef { num: number; name: string; type: 'int' | 'double' | 'string' | 'bool' | 'arr' | 'obj'; child?: string; }  // eslint-disable-line

// We know the exact schema from proto/schema.sproto:
const SCHEMA: Record<string, FieldDef[]> = {
  SnapFrame: [
    { num: 0, name: 'tick', type: 'int' }, { num: 2, name: 'time', type: 'double' },
    { num: 4, name: 'tw', type: 'int' }, { num: 6, name: 'self', type: 'string' },
    { num: 8, name: 'ents', type: 'arr', child: 'string' }, { num: 10, name: 'keep', type: 'arr', child: 'int' },
  ],
  EventsFrame: [{ num: 0, name: 'list', type: 'arr', child: 'Event' }],
  Event: [
    { num: 0, name: 'type', type: 'string' }, { num: 2, name: 'pid', type: 'int' },
    { num: 4, name: 'dmg', type: 'double' }, { num: 6, name: 'crit', type: 'bool' },
    { num: 8, name: 'x', type: 'double' }, { num: 10, name: 'z', type: 'double' },
    { num: 12, name: 'y', type: 'double' }, { num: 14, name: 'targetId', type: 'int' },
    { num: 16, name: 'text', type: 'string' }, { num: 18, name: 'name', type: 'string' },
    { num: 20, name: 'abilityId', type: 'string' }, { num: 22, name: 'amount', type: 'double' },
    { num: 24, name: 'overkill', type: 'bool' }, { num: 26, name: 'offhand', type: 'bool' },
    { num: 28, name: 'blocked', type: 'bool' }, { num: 30, name: 'dodged', type: 'bool' },
    { num: 32, name: 'missed', type: 'bool' },
  ],
  HelloFrame: [
    { num: 0, name: 'pid', type: 'int' }, { num: 2, name: 'seed', type: 'int' },
    { num: 4, name: 'name', type: 'string' }, { num: 6, name: 'cls', type: 'string' },
    { num: 8, name: 'realm', type: 'string' }, { num: 10, name: 'level', type: 'int' },
    { num: 12, name: 'skin', type: 'int' },
  ],
  SocialFrame: [
    { num: 0, name: 'friends', type: 'arr', child: 'FriendEntry' },
    { num: 2, name: 'blocks', type: 'arr', child: 'int' },
    { num: 4, name: 'ignores', type: 'arr', child: 'int' },
    { num: 6, name: 'guild', type: 'obj', child: 'GuildEntry' },
    { num: 8, name: 'pendingInvites', type: 'arr', child: 'int' },
  ],
  FriendEntry: [
    { num: 0, name: 'id', type: 'int' }, { num: 2, name: 'name', type: 'string' },
    { num: 4, name: 'class', type: 'string' }, { num: 6, name: 'online', type: 'bool' },
  ],
  GuildEntry: [
    { num: 0, name: 'id', type: 'int' }, { num: 2, name: 'name', type: 'string' },
    { num: 4, name: 'rank', type: 'int' }, { num: 6, name: 'members', type: 'arr', child: 'GuildMember' },
  ],
  GuildMember: [
    { num: 0, name: 'id', type: 'int' }, { num: 2, name: 'name', type: 'string' },
    { num: 4, name: 'class', type: 'string' }, { num: 6, name: 'level', type: 'int' },
    { num: 8, name: 'online', type: 'bool' },
  ],
  ErrorFrame: [{ num: 0, name: 'error', type: 'string' }],
  CommandOutcomeFrame: [
    { num: 0, name: 'rid', type: 'string' }, { num: 2, name: 'ok', type: 'bool' },
  ],
  GbankLogFrame: [
    { num: 0, name: 'ok', type: 'bool' }, { num: 2, name: 'entries', type: 'arr', child: 'GbankLogEntry' },
  ],
  GbankLogEntry: [
    { num: 0, name: 'op', type: 'string' }, { num: 2, name: 'pid', type: 'int' },
    { num: 4, name: 'amount', type: 'int' }, { num: 6, name: 'itemId', type: 'string' },
    { num: 8, name: 'itemName', type: 'string' }, { num: 10, name: 'timestamp', type: 'int' },
  ],
};

const TYPE_TAGS: Record<number, string> = {
  1: 'SnapFrame', 2: 'EventsFrame', 3: 'HelloFrame', 4: 'SocialFrame',
  5: 'ErrorFrame', 6: 'CommandOutcomeFrame', 7: 'GbankLogFrame',
};

// ---- core decoder ----
function decodeFields(buf: Uint8Array, off: number, fields: FieldDef[]): [WireObj, number] {
  const result: WireObj = {};
  while (off < buf.length) {
    const [tag, p1] = readVarint(buf, off); off = p1;
    if (tag === 0) break;
    const field = fields.find(f => f.num === tag) as FieldDef | undefined;
    if (!field) {
      // skip unknown field: read wire_type from next byte
      const [wt, p2] = readVarint(buf, off); off = p2;
      if (wt === 0) { /* single varint already consumed */ }
      else if (wt === 2) { off += wt; }
      continue;
    }
    switch (field.type) {
      case 'int': { const [v, p2] = readVarint(buf, off); off = p2; result[field.name] = v; break; }
      case 'double': { const [v, p2] = readVarint(buf, off); off = p2; result[field.name] = v; break; }
      case 'string': { const [v, p2] = readString(buf, off); off = p2; result[field.name] = v; break; }
      case 'bool': { const [v, p2] = readBool(buf, off); off = p2; result[field.name] = v; break; }
      case 'arr': {
        const [count, p2] = readVarint(buf, off); off = p2;
        const arr: WireArr = [];
        if (field.child === 'int') {
          for (let i = 0; i < count; i++) { const [v, p3] = readVarint(buf, off); off = p3; arr.push(v); }
        } else if (field.child === 'string') {
          for (let i = 0; i < count; i++) { const [v, p3] = readString(buf, off); off = p3; arr.push(v); }
        } else if (field.child) {
          const childFields = SCHEMA[field.child];
          if (childFields) {
            for (let i = 0; i < count; i++) { const [v, p3] = decodeFields(buf, off, childFields); arr.push(v); off = p3; }
          }
        }
        result[field.name] = arr;
        break;
      }
      case 'obj': {
        if (field.child) {
          const childFields = SCHEMA[field.child];
          if (childFields) { const [v, p2] = decodeFields(buf, off, childFields); result[field.name] = v; off = p2; }
        }
        break;
      }
    }
  }
  return [result, off];
}

// ---- public API ----
export function decodeFrame(buf: ArrayBuffer): { type: string; data: WireObj } | null {
  const u8 = new Uint8Array(buf);
  if (u8.length < 1) return null;
  const typeTag = u8[0];
  const typeName = TYPE_TAGS[typeTag];
  if (!typeName) return null;
  const fields = SCHEMA[typeName];
  if (!fields) return null;
  try {
    const [data] = decodeFields(u8, 1, fields);
    // Add the `t` field that the existing JSON.parse path expects
    const tmap: Record<string, string> = {
      SnapFrame: 'snap', EventsFrame: 'events', HelloFrame: 'hello',
      SocialFrame: 'social', ErrorFrame: 'error', CommandOutcomeFrame: 'commandOutcome',
      GbankLogFrame: 'gbanklog',
    };
    (data as WireObj).t = tmap[typeName] || typeName;
    return { type: typeName, data };
  } catch (e) {
    console.warn('[sproto] decode error:', e);
    return null;
  }
}
