# Moon self-host load-test retrospective (2000/5000-bot battles)

One-off report covering the 2026-08-18 load-test campaign against the installed
self-host Moon server (`World of ClaudeCraft-Moon.exe`), the gate scaling work it
drove, and the layered root-cause analysis. Historical record, not source of truth.

## TL;DR verdict

| Question | Answer |
|---|---|
| Does the server carry **2000** concurrent battle players? | **Yes** — 2000/2000 joined, 0 failures, held the full 2 h, gates at ~40 % load |
| Does the server carry **5000** concurrent battle players? | **Connectivity yes; data plane yes; sim is the ceiling** — 5000/5000 joined and held, snapshot frames collapsed ~100-300x (750 KB -> ~3 KB) and Hz rose ~0.2 -> ~2.7, with the remaining limit being world simulation CPU at ~3000 simultaneous fighters in one cluster |
| What was the real bottleneck behind every ~950-1000 "join wall"? | The **same-machine load-test client** (one Node process), not the server |
| What caused the 750 KB snapshot frames at 5000 clustered? | **Uncapped cross-shard ghost FULL records** (each ~5 KB), not the local-entity delta path |

## What shipped (commit `f28e9f04e`)

- **Gate hardening (P0)** — `moon-server/woc/gate/init.lua`
  - Snapshot frame-rate cap `SNAP_SEND_HZ` (default 10 Hz) with load-adaptive
    degradation to `SNAP_SEND_HZ_DEGRADED` (5 Hz) driven by keepalive-sweep
    latency (`recoverStreak`, fixes the permanent-degradation bug).
  - Keepalive reaping: 2-round no-pong guard (`noPongStreak`) before reap;
    `skippedSnaps >= GATE_STALLED_SKIP_REAP` only tiers the log label
    (`Stalled reap` / `Keepalive reap`), never controls the socket.
  - Session reaper (`detachSession` + grace-based `sessionsByChar` cleanup) and a
    per-10 s `[GateMetric]` line to `log/gate-metrics.log`.
- **Multi-gate (P1)** — `main.lua`, `gate/init.lua`, `world/init.lua`
  - `GATE_COUNT` gate services (`gate_0..N`), each on its own thread and ports
    (HTTP `port+2k`, WS `wsPort+2k`).
  - pid space = `gateIndex * GATE_PID_STRIDE + seq` (`STRIDE=100_000_000`), which
    keeps `pid % worldShards` round-robin and avoids world entity-id collisions.
  - World routes by `gateOf(pid)`, splits `broadcastSnap` per gate; cross-gate
    resume via an active-lease probe (`getCharacterLease`) + `queryPlayerGate`.
- **WS direct-connect** — `launcher_moon.mjs`, `src/net/online.ts`
  - `/api/status` returns `wsPorts`; the browser connects straight to a gate WS
    port, removing the Node proxy from the ~hundreds-of-MB/s data path. Proxy
    keeps static + `/api` only. Firewall rules added for the gate WS ports.
- **Load harness** — `scripts/big_battle_load.mjs`
  - Progressive ramp, movement + combat simulation, per-observer snapshot
    metrics, `WS_PORTS` for direct gate connections, multi-process capable.

## Snapshot optimization (P2, commit `a72c3fd9f`)

Drove the clustered frame size from ~750 KB down to ~3 KB and snapshot Hz from
~0.2 up to ~2.7 at 5000 players (best-case mean), without any client protocol
change (the wire is still JSON full/lite/keep).

- **Ghost LITE + budget** (`snapshot.lua`, `ghost.lua`, `grid.lua`) — the real
  cause of the 750 KB frames: cross-shard ghosts were FULL records, uncapped,
  re-sent whole on any change. Ghosts now emit FULL on first sight, LITE on
  change, keep otherwise, and are capped inside `MAX_VISIBLE` with per-pid
  rotation (no sort). `queryGhosts` gained a `maxCount` bound so a dense crowd
  stops scanning the whole ghost set (~4845 ghosts) per observer.
- **Frame cadence** (`world/init.lua`) — active players (battle/moving) build a
  frame every `SNAP_ACTIVE_DIVISOR` (2) ticks, idle every `SNAP_IDLE_DIVISOR`
  (4), with an immediate rebuild on idle->active so combat engagement never
  waits on the idle beat. Combat events stay on their own channel.
- **Combat priority** (`snapshot.lua`) — target/attacker entities reserve
  budget slots before the nearest-first fill, so crowd culling never drops the
  current fight.
- `ghost.serialize` ships both `full` and `lite` wire records.

Measured at 5000 clustered (10 x 500, 10 min): frames p50 ~3 KB (was 30-65 KB,
p95 ~760-840 KB), gate traffic ~20 MB/s (was ~240 MB/s), snapshot Hz best-mean
~2.65 (was ~0.2). The remaining ceiling is world simulation CPU — every shard
runs ~156 active players through movement + combat + snapshot build each tick —
not the snapshot data plane.

## Methodology (the important lesson)

The client and server ran on the same machine. **One Node load-test process
cannot sustain more than ~950-1000 concurrent WebSocket connections while also
receiving hundreds of MB/s of snapshot data** — new joins' `hello` frames queue
behind the data flood and time out at 30 s, producing the "join wall" that
repeated across every single-process run regardless of server configuration.

Valid measurements split the bots across Node processes (each process ~500
connections). The 5000-bot runs use 10 x 500.

Reproduce:

```bash
# prerequisites: installed server running; DATABASE_URL to the self-host PG
export SERVER_URL=http://localhost:8787
export WS_PORTS=8789,8791          # direct gate WS ports (bypass proxy)
# 2000 bots, 2h: 4 processes x 500
BOTS=500 DURATION_MS=7200000 OBSERVERS=6 COMBAT_RATIO=0.6 node scripts/big_battle_load.mjs &
# repeat x4
# 5000 bots, 10 min: 10 processes x 500
BOTS=500 DURATION_MS=600000 OBSERVERS=6 COMBAT_RATIO=0.6 node scripts/big_battle_load.mjs &  # x10
```

Server-side ground truth is `[GateMetric]` in
`moon-server/woc/log/gate-metrics.log`:
`[GateMetric] t=.. sessions=.. sends=.. bytes=.. skip=.. reap=.. interval=.. delayStreak=..`

## Results

### 2000-bot battle, 2 h sustained (4 x 500, dual gate, WS direct)

| Metric | Value |
|---|---|
| Join | **2000/2000, 0 failures** |
| Connection retention | **2000/2000 held the full 2 h** (reap=0) |
| Snapshot Hz/player | best 19.3, steady ~6-10 (10 Hz cap) |
| Snapshot size | p50 ~46-53 KB |
| Gate load | ~1000 sessions/gate, ~2500 sends/s, ~120 MB/s, `delayStreak=0` |

### 5000-bot battle, 10 min sustained (10 x 500, dual gate, WS direct)

| Metric | Value |
|---|---|
| Join | **5000/5000, 0 failures** |
| Connection retention | **5000/5000 held 10 min, 0 reaps, health probe fails=0** |
| Gate load | 2500 sessions/gate, `delayStreak=0`, `reap=0`, interval 10 Hz |
| Snapshot Hz/player | **~0.1-0.3** (cap is 10) |
| Snapshot gap | p50 ~2.5 s, p95 8-11 s, max ~22 s |
| Snapshot size | p50 ~30-65 KB, **p95 ~760-840 KB, max ~1.38 MB** |

## Root-cause layering (as proven by experiment)

1. **Node launcher proxy** — NOT the wall. WS direct-connect did not change the
   single-client join wall; proxy `health` fails only reappear when the single
   test client saturates.
2. **Gate Lua thread** — NOT the wall. At 2000-5000 sessions the dual gates run
   at 40-50 % capacity, `delayStreak=0` throughout.
3. **Load-test client (same machine)** — the real source of every ~950-1000 join
   wall. Splitting the bots across processes takes 2000 and 5000 to 0 failures.
4. **World shard snapshot build** — the ceiling at **5000 clustered** was the
   **uncapped cross-shard ghost FULL records**: players spread by pid across 32
   shards but spatially clustered, so every player's AOI held ~155 ghost FULL
   records (~5 KB each) re-sent on any change. The local-entity delta path was
   already capped at `MAX_VISIBLE` and was not the problem. After ghost LITE +
   budget + query bound, the frame data plane is no longer the bottleneck; the
   remaining cost is the per-shard simulation of ~156 active players per tick.

## Verdicts

- The server **accepts and holds 5000 concurrent players** with the full scaling
  stack (dual gate, WS direct, frame cap, keepalive reaping) healthy, and the
  snapshot data plane now delivers ~3 KB frames (100-300x smaller).
- **5000 players all fighting in one geographic cluster** still lands around
  ~2-3 Hz/player because the world shards are CPU-bound simulating ~3000
  simultaneous combatants; real-world players spread across the map would not
  create the same sim load. The plan's realistic acceptance cases (5000 static,
  ~1000 combatants in a battle) are not yet re-measured after this work.
- Remaining levers: validate the realistic scenarios (static 5000 >= 7-8 Hz,
  ~1000-fighter battle >= 5 Hz); binary wire framing for a further constant
  factor; distributed-spawn / split-machine testing.

## Open items

- [ ] Re-validate the acceptance cases post-P2: 5000 static and ~1000-fighter
      battle (COMBAT_RATIO tuned), expecting >= 7-8 Hz and >= 5 Hz.
- [ ] Binary wire framing (JSON string keys are ~40 % of frame bytes) — a
      client+server protocol change, deferred.
- [ ] A distributed-spawn (realistic) 5000-bot run to separate "clustered AOI
      density" from absolute world capacity.
- [ ] Split-machine load testing (bots on a second host) to eliminate the
      same-machine client measurement ceiling entirely.
