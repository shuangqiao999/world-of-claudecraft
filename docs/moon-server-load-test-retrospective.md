# Moon self-host load-test retrospective (2000/5000-bot battles)

One-off report covering the 2026-08-18 load-test campaign against the installed
self-host Moon server (`World of ClaudeCraft-Moon.exe`), the gate scaling work it
drove, and the layered root-cause analysis. Historical record, not source of truth.

## TL;DR verdict

| Question | Answer |
|---|---|
| Does the server carry **2000** concurrent battle players? | **Yes** — 2000/2000 joined, 0 failures, held the full 2 h, gates at ~40 % load |
| Does the server carry **5000** concurrent battle players? | **Connectivity yes, gameplay no** — 5000/5000 joined and stayed connected, but snapshot delivery collapses to ~0.2 Hz/player when everyone is clustered (bottleneck = world shard snapshot build) |
| What was the real bottleneck behind every ~950-1000 "join wall"? | The **same-machine load-test client** (one Node process), not the server |

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
4. **World shard snapshot build** — the true ceiling at **5000 clustered**. All
   5000 bots spawn in one area, so every player's AOI holds ~156 moving
   entities; with combat, every entity changes every tick, so delta encoding
   cannot shrink frames. Frames balloon to ~750 KB-1.38 MB and the per-shard
   per-tick build cost becomes O(players x visible) -> snapshot delivery drops
   to ~0.2 Hz/player while connectivity stays perfect.

## Verdicts

- The server **accepts and holds 5000 concurrent players** with the full scaling
  stack (dual gate, WS direct, frame cap, keepalive reaping) healthy.
- **5000 players in one geographic cluster is not playable**: snapshot feedback
  latency reaches seconds. Real-world players spread across the map would not
  create the same AOI density.
- The next bottleneck is the **world snapshot builder** (P2): entity-level
  distance-tiered refresh already exists but cannot help when every entity
  moves/attacks every tick. Candidate levers: visible-entity cap per frame with
  the tail coalesced into "keep", coarser tick cadence for distant entities, or
  binary payload compression.

## Open items

- [ ] P2 snapshot build optimization (frame byte budget, distance-tiered refresh
      under mass movement, binary framing).
- [ ] A distributed-spawn (realistic) 5000-bot run to separate "clustered AOI
      density" from absolute world capacity.
- [ ] Split-machine load testing (bots on a second host) to eliminate the
      same-machine client measurement ceiling entirely.
