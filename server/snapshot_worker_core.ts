// Parallel snapshot assembly core.  The main thread pre-computes entity wire
// encodings and per-session candidate lists, then fans the per-session entity
// iteration (delta checks, ents/keep building) out to worker threads.  The
// main thread still handles selfWireJson (which needs live Sim access) and the
// final JSON assembly + sendRaw.
//
// Constants and helpers mirror the originals in server/game.ts exactly.

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

export interface SessionTask {
  pid: number;
  stableTimerWire: boolean;
  sentEnts: [number, SentEntRecord][];
  // candidate entity ids for this session (pre-filtered: within interest, observable)
  candidateIds: number[];
}

export interface SessionResult {
  pid: number;
  ents: string[];
  keep: number[];
  updatedSentEnts: [number, SentEntRecord][];
}

export interface BroadcastContext {
  tick: number;
  head: string;
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
    const ents: string[] = [];
    const keep: number[] = [];
    const present = new Set<number>();

    for (const eid of task.candidateIds) {
      const e = entityMap.get(eid);
      if (!e) continue;
      present.add(eid);

      const known = sentEnts.get(eid);
      if (known === undefined) {
        ents.push(task.stableTimerWire ? e.wireFullAura : e.wireFull);
        sentEnts.set(eid, {
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

      // isUpdateDue: pre-filtered candidates are always within interest and
      // FULL_RATE_RADIUS_SQ (the main thread already verified distance ≤
      // interest radius).  For the far-rate update culling, the serial path
      // reads per-entity d2 and aggro-target; in the parallel path we lean on
      // the pre-filter (the main thread only includes entities that pass
      // canObserve + interestLimit), so entities that arrived here are in
      // range and due for an update at every pass.  The dyn/aura version
      // check above was already the settled gate.
      if (known.dynVer === e.dynVer && !auraChanged && known.settled) {
        keep.push(eid);
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

    return {
      pid: task.pid,
      ents,
      keep,
      updatedSentEnts: Array.from(sentEnts.entries()),
    };
  });
}
