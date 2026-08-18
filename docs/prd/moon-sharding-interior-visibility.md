# Moon spatial sharding: region-interior visibility for pid-shard players

Status: **Open / unbuilt** — a follow-up spec produced during the 5000-bot load
campaign (see `docs/moon-server-load-test-retrospective.md`). Read the linked
retrospective for the measurements that motivated this.

## Problem

With smart player migration (players stay on their `pid % shardCount` shard
unless they genuinely travel into a new region), a player who stands inside a
region owned by a **different** shard cannot see or interact with that region's
*interior* entities — NPCs, mobs, gather nodes, lootable objects.

Cause chain:

1. Each world shard spawns/owns only the static content (NPCs via
   `npc_spawn.lua`, camp mobs, nodes) in the regions it owns
   (`regionToShard(regionOf(pos)) == shardId`, `moon-server/woc/world/npc_spawn.lua:56-59`).
2. Cross-shard visibility relies on `ghostSync`, which only serialises entities
   **within 135 yd of their region boundary** and only to the shards owning the
   *adjacent* regions. Entities in a region interior are never synced.
3. A player on pid-shard Y standing in the middle of a region owned by shard X
   therefore sees an empty world there (probe: a level-1 character at the spawn
   saw zero entities — `scripts/_probe2.mjs` reproduction).
4. `interact` already forwards ghost NPCs to their owner shard
   (`command_dispatch.lua` `H.interact` -> `forwardInteract` ->
   `interactForward`), but that only helps NPCs that are *near a boundary and
   synced*; interior NPCs are not ghosts at all.

This is a **spatial-model limitation**, not a regression of the migration change:
it exists for every foreign-region player whenever migration keeps them on their
pid shard. The old behaviour (migration ON, unconditional) "worked" only because
it consolidated everyone onto the region's shard — which was the performance
bomb the smart-migration fix removed.

## Requirements

Pick a coherent fix (below) so that a player can see and interact with the world
of the region they stand in, while the 5000-bot load distribution (48/48 shards,
~6 Hz) is preserved.

### Fix A — region-wide ghost sync (recommended direction)

Extend ghost sync so that, for a player's current region, the *content* entities
of that region (and its 8 neighbours) are delivered as ghosts even when they are
interior.

- Scope: broadcast interior content entities to the shard owning the region
  (or to every shard with players in that region), not just boundary-neighbours.
- Cost control: interior ghosts are static NPCs/mobs/nodes — they change rarely,
  so sync them at a low cadence (e.g. every `GHOST_SYNC_INTERVAL_TICKS` x N), and
  keep them out of the hot per-tick snapshot path once delivered (the existing
  ghost FULL/LITE/keep path already applies).
- Interactions (talk/vendor/quest/harvest/loot) then resolve through the
  existing ghost forward path (`interactForward`, `nodeForward`, `lootForward`).
- Player-to-player visibility is already covered by the existing boundary ghost
  sync + combat forwarding; only *content* needs the region-wide extension.

### Fix B — distributed spawn

Give new characters a spread of starter spawn points across regions owned by
different shards, so migration re-homes them across shards naturally.

- Cheaper than Fix A and removes the single-region hot spot entirely, but it is
  a content/gameplay change (multiple starter towns) and does not fix the
  underlying interior-invisibility for a player who *travels* into a foreign
  region interior.

### Fix C — per-region shard ownership for players (migration at spawn)

Migrate a player to their region's shard immediately on join (the old
behaviour), but keep the smart-detection gates for *subsequent* travel so the
spawn hot spot stays bounded. Only viable if the spawn population per region is
bounded; it reintroduces the consolidation for a crowded single spawn.

## Acceptance criteria

1. A level-1 character at the starter town can see the town NPCs and
   `interact` (talk/quest/merchant) successfully — no "Nothing to interact
   with." for interior NPCs.
2. A player who walks into a foreign region interior sees that region's mobs /
   NPCs / nodes and can harvest / loot / fight them (server-side cross-shard
   resolution).
3. The 5000-bot clustered load test keeps >= 48/48 shards populated and snapshot
   Hz >= 5 (i.e. the fix does not reintroduce the migration consolidation).
4. No snapshot frame regression: interior ghosts stay on the FULL/LITE/keep
   delta path and off the hot per-tick build.

## Reference points (re-verify against code before starting)

- Player spawn: `moon-server/woc/world/init.lua` `createPlayerEntity` (pos = 0,0)
  and `joinPlayer`.
- NPC ownership by region: `moon-server/woc/world/npc_spawn.lua` spawnAll.
- Ghost sync boundary rule + cadence: `moon-server/woc/world/init.lua`
  `ghostSync`; `config.GHOST_SYNC_INTERVAL_TICKS`.
- Ghost budget + LITE path: `moon-server/woc/world/snapshot.lua` (P2a ghost loop).
- Interact forwarding: `moon-server/woc/world/command_dispatch.lua` `H.interact`,
  `M.npcLines`; `moon-server/woc/world/init.lua` `forwardInteract` /
  `interactForward`.
- Migration gates: `moon-server/woc/world/init.lua` migration check +
  `migratePlayerOut`; `config.MIGRATE_*`.
