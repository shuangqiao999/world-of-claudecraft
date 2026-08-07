// Sim readout: a serializable snapshot of all per-player Sim data that the
// broadcast's selfWireJson and entity-wire functions need.  Built once per
// broadcast pass on the main thread (from the live Sim) and sent to snapshot
// workers so they can build per-session snapshots without accessing the Sim
// themselves.
//
// Every field mirrors a `this.sim.<method>(pid)` call in selfWireJson or
// entity-wire helpers.  When a worker receives this readout it performs the
// same `maybe(key, value)` / `maybeRaw(key, serialized)` delta-diff logic
// the serial broadcast does, so byte-identical output is maintained.

export interface SimReadout {
  // Entity self-wire fields (from wireEntity + extras)
  partyWire: unknown;
  duelWire: unknown;
  tradeWire: unknown;
  arenaInfo: unknown;
  cupInfo: string; // pre-serialized (maybeRaw)
  bgInfo: unknown;
  bgLadder: string; // pre-serialized (maybeRaw, shared realm-wide)
  marketInfo: unknown;
  marketBrowseRev: unknown;
  marketCollectPending: unknown;
  mailInfo: unknown;
  mailUnread: unknown;
  bankInfo: unknown;
  guildBankInfo: unknown;
  delveWire: unknown;
  delveMarks: unknown;
  delveCompanionWire: unknown;
  delveDailyWire: unknown;
  delveClearsWire: unknown;
  companionUpgradesWire: unknown;
  professionsWire: unknown;
  craftingWire: unknown;
  commissionWire: string; // pre-serialized (maybeRaw)
  lootRolls: unknown;
  masterLootRolls: unknown;
  lootRollGroupStatus: unknown;
  dungeonFinderWire: string; // pre-serialized (maybeRaw)
  enchantsWire: unknown;
  disinfectResultWire: unknown;
  enchantResultWire: unknown;
  salvageResultWire: unknown;
  toolEffectsWire: unknown;
  gatheringWire: unknown;
  mountLessonWire: unknown;
  mountRaceWire: string; // pre-serialized (maybeRaw)
  mountWire: unknown;
  ownedMounts: unknown;
  markersWire: unknown;
  cardMinigame: string; // pre-serialized (maybeRaw)
  townFocus: unknown;
  warfareQuartermasterWire: unknown;
  battlegroundWire: unknown;
  mountRidesWire: unknown;
}

// Empty readout used when a session has no relevant sim data (offline, dead, etc.)
export const EMPTY_READOUT: SimReadout = {
  partyWire: null,
  duelWire: null,
  tradeWire: null,
  arenaInfo: null,
  cupInfo: 'null',
  bgInfo: null,
  bgLadder: 'null',
  marketInfo: null,
  marketBrowseRev: null,
  marketCollectPending: null,
  mailInfo: null,
  mailUnread: null,
  bankInfo: null,
  guildBankInfo: null,
  delveWire: null,
  delveMarks: null,
  delveCompanionWire: null,
  delveDailyWire: null,
  delveClearsWire: null,
  companionUpgradesWire: null,
  professionsWire: null,
  craftingWire: null,
  commissionWire: 'null',
  lootRolls: null,
  masterLootRolls: null,
  lootRollGroupStatus: null,
  dungeonFinderWire: 'null',
  enchantsWire: null,
  disinfectResultWire: null,
  enchantResultWire: null,
  salvageResultWire: null,
  toolEffectsWire: null,
  gatheringWire: null,
  mountLessonWire: null,
  mountRaceWire: 'null',
  mountWire: null,
  ownedMounts: null,
  markersWire: null,
  cardMinigame: 'null',
  townFocus: null,
  warfareQuartermasterWire: null,
  battlegroundWire: null,
  mountRidesWire: null,
};
