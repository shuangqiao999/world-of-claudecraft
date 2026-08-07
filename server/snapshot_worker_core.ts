// Parallel snapshot assembly core.  The main thread pre-computes entity wire
// encodings and per-session candidate lists, then fans the per-session entity
// iteration (delta checks, ents/keep building) out to worker threads.  The
// main thread still handles selfWireJson (which needs live Sim access) and the
// final JSON assembly + sendRaw.
//
// Constants and helpers mirror the originals in server/game.ts exactly.

const FULL_RATE_RADIUS_SQ = 30 * 30;
const HALF_RATE_RADIUS_SQ = 80 * 80;
const HALF_RATE_DIVISOR = 2;
const QUARTER_RATE_DIVISOR = 4;
const VALE_CUP_BALL_TEMPLATE_ID = 'vale_cup_ball';

// ---------- types ----------

export interface EncodedEntity {
  id: number;
  idVer: number;
  dynVer: number;
  auraVer: number;
  wireFull: string;
  wireFullAura: string;
  wireLite: string;
  wireLiteAura: string;
}

export interface SentEntRecord {
  idVer: number;
  dynVer: number;
  auraVer: number;
  sentAtTick: number;
  settled: boolean;
}

// Per-entity context passed from the main thread for isUpdateDue
export interface CandidateEntry {
  id: number;
  d2: number;
  templateId: string;
  aggroTargetId?: number;
}

export interface SessionTask {
  pid: number;
  stableTimerWire: boolean;
  sentEnts: [number, SentEntRecord][];
  // pre-filtered candidates (within interest, observable) with distance context
  candidates: CandidateEntry[];
  // anchor entity ids for isUpdateDue
  anchorId: number;
  anchorTargetId: number | null;
  // pre-computed self-wire heavy fields: key -> serialized JSON string
  selfHeavy: Record<string, string>;
  // session lastSent state for heavy-field delta comparison
  lastSent: Record<string, string>;
}

export interface SessionResult {
  pid: number;
  ents: string[];
  keep: number[];
  updatedSentEnts: [number, SentEntRecord][];
  // updated lastSent after heavy-field delta check
  updatedLastSent: Record<string, string>;
  // pre-assembled self JSON string (base + changed heavy fields)
  selfJson: string;
}

export interface BroadcastContext {
  tick: number;
  head: string;
}

// ---------- helpers (mirrors game.ts) ----------

function isUpdateDue(
  tick: number,
  eTemplateId: string,
  d2: number,
  viewerTargetId: number | null,
  viewerId: number,
  aggroTargetId: number | undefined,
  eId: number,
  sentAtTick: number,
): boolean {
  if (eTemplateId === VALE_CUP_BALL_TEMPLATE_ID) return true;
  if (d2 <= FULL_RATE_RADIUS_SQ) return true;
  if (viewerTargetId === eId || aggroTargetId === viewerId) return true;
  const divisor = d2 <= HALF_RATE_RADIUS_SQ ? HALF_RATE_DIVISOR : QUARTER_RATE_DIVISOR;
  return tick - sentAtTick >= divisor;
}

// ---------- per-session entity iteration (extracted from broadcastSnapshots) ----------

export function computeSessionResults(
  ctx: BroadcastContext,
  entityMap: Map<number, EncodedEntity>,
  tasks: SessionTask[],
): SessionResult[] {
  const { tick } = ctx;
  return tasks.map((task) => {
    const sentEnts = new Map(task.sentEnts);
    const lastSent = { ...task.lastSent };
    const ents: string[] = [];
    const keep: number[] = [];
    const present = new Set<number>();

    for (const c of task.candidates) {
      const e = entityMap.get(c.id);
      if (!e) continue;
      present.add(c.id);

      const known = sentEnts.get(c.id);
      if (known === undefined) {
        ents.push(task.stableTimerWire ? e.wireFullAura : e.wireFull);
        sentEnts.set(c.id, {
          idVer: e.idVer,
          dynVer: e.dynVer,
          auraVer: e.auraVer,
          sentAtTick: tick,
          settled: true,
        });
        continue;
      }

      const auraChanged = task.stableTimerWire && known.auraVer !== e.auraVer;
      if (known.idVer !== e.idVer) {
        ents.push(auraChanged ? e.wireFullAura : e.wireFull);
        known.idVer = e.idVer;
        known.dynVer = e.dynVer;
        known.auraVer = e.auraVer;
        known.sentAtTick = tick;
        known.settled = false;
        continue;
      }

      if (
        !isUpdateDue(tick, c.templateId, c.d2, task.anchorTargetId, task.anchorId, c.aggroTargetId, c.id, known.sentAtTick) ||
        (known.dynVer === e.dynVer && !auraChanged && known.settled)
      ) {
        keep.push(c.id);
        continue;
      }

      known.settled = known.dynVer === e.dynVer;
      known.dynVer = e.dynVer;
      known.auraVer = e.auraVer;
      known.sentAtTick = tick;
      ents.push(auraChanged ? e.wireLiteAura : e.wireLite);
    }

    // forget entities that left interest
    for (const id of sentEnts.keys()) {
      if (!present.has(id)) sentEnts.delete(id);
    }

    // selfWireJson heavy-field delta comparison (pure, no sim access needed)
    let extra = '';
    for (const [key, serialized] of Object.entries(task.selfHeavy)) {
      if (key === '_selfBase') continue; // handled below
      if (lastSent[key] !== serialized) {
        lastSent[key] = serialized;
        extra += `,"${key}":${serialized}`;
      }
    }
    const baseJson = task.selfHeavy['_selfBase'] || '{}';
    const fullSelf = extra.length > 0 ? `${baseJson.slice(0, -1)}${extra}}` : baseJson;

    return {
      pid: task.pid,
      ents,
      keep,
      updatedSentEnts: Array.from(sentEnts.entries()),
      updatedLastSent: lastSent,
      selfJson: fullSelf,
    };
  });
}
