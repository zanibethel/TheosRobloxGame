# Interaction Framework

Milestone 2 technical reference for the Theo's Roblox Game interaction system.

---

## Architecture

The framework is split across three layers:

| Layer | File | Responsibility |
|---|---|---|
| Shared | `src/shared/Types/init.luau` | Exported types: `InteractionDefinition`, `SessionRecord`, result codes |
| Shared | `src/shared/Config/GameConfig.luau` | Tunable constants (distance, rate limit, session limits, expiry buffer) |
| Shared | `src/shared/Remotes/init.luau` | Remote accessor; server calls `setup()`, clients call `get(name)` |
| Server | `src/server/Services/InteractionService.luau` | Session lifecycle, validation, completion, reset API |
| Client | `src/client/Controllers/InteractionController.luau` | ProximityPrompt management, Begin/Cancel/Instant dispatch |
| Server | `src/server/Services/DemoInteractions.luau` | Demonstration registrations (instant button + exclusive hold lever) |
| Shared | `src/shared/Tests/InteractionTests.luau` | Pure-logic test suite (no Roblox Studio required) |

---

## Client / Server Sequence

### Instant interaction

```
Client                              Server
  |                                   |
  |  Triggered (ProximityPrompt)      |
  |---------------------------------->|
  |  InvokeServer("instant", id)      |
  |  <validate all checks>            |
  |  <call OnCompleted>               |
  |  <apply cooldown>                 |
  |<-- (success, "ok", nil) ----------|
  |                                   |
  |  (optional) FireAllClients        |
  |<-- InteractionStateChanged -------|
  |     (id, "cooldown")              |
```

### Hold interaction

```
Client                              Server
  |                                   |
  |  PromptButtonHoldBegan            |
  |---------------------------------->|
  |  InvokeServer("begin", id)        |
  |  <validate all checks>            |
  |  <create SessionRecord>           |
  |  <acquire exclusive lock if set>  |
  |  <call OnStarted>                 |
  |<-- (true, "ok", sessionId) -------|
  |                                   |
  |  [client shows progress bar]      |
  |                                   |
  |          [server Heartbeat ticks] |
  |          when startTime+duration  |
  |          elapsed:                 |
  |          <revalidate session>     |
  |          <call OnCompleted>       |
  |          <release lock>           |
  |          <apply cooldown>         |
  |<-- InteractionStateChanged -------|
  |     (id, "available"/"cooldown")  |
  |                                   |
  |  [if player releases early]       |
  |  PromptButtonHoldEnded            |
  |  InvokeServer("cancel", id, sid) >|
  |  <call OnCancelled>               |
  |  <release lock>                   |
  |<-- (true, "ok", nil) -------------|
```

### Race: two near-simultaneous Begin requests (exclusive target)

```
Player A                            Server                          Player B
  |                                   |                                |
  |  InvokeServer("begin", id) ------>|                                |
  |                                   |  lock = nil → acquire("s1")   |
  |<-- (true, "ok", "s1") -----------|                                |
  |                                   |<----- InvokeServer("begin", id)
  |                                   |  lock = "s1" → reject         |
  |                                   |-----> (false, "locked", nil) ->|
```

---

## Session Lifecycle

```
 [Begin request received]
        │
        ▼
 Validate all pre-conditions
        │
        ├── rejected ──────────────► return (false, code, nil)
        │
        ▼
 Create SessionRecord
 Register in activeSessions / sessionsByPlayer / sessionsByTarget
 Acquire exclusive lock (if exclusive=true)
 Broadcast "locked" to clients (if exclusive)
 Call OnStarted
        │
        ▼
 ┌─────────────────────────────────────────────────────────┐
 │               Heartbeat polling (every frame)           │
 │                                                         │
 │  ┌─ target removed ─────────────► cancelSession()       │
 │  ├─ session.expiresAt reached ──► cancelSession()       │
 │  ├─ cancelOnMovement + too far ─► cancelSession()       │
 │  ├─ cancelOnDamage + health ↓ ──► cancelSession()       │
 │  └─ startTime + duration reached ► completeSession()    │
 └─────────────────────────────────────────────────────────┘
        │                   │
 cancelSession()      completeSession()
        │                   │
 OnCancelled()         revalidateForCompletion()
 cleanupSession()           │
 release lock          ─── fail ──► cancelSession(reason)
                            │
                         mark completed
                         OnCompleted()
                         cleanupSession()
                         release lock
                         apply cooldown
                         broadcast "cooldown"
```

---

## Definition Schema

All fields accepted by `InteractionService.register(id, definition)`:

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | `string` | Yes | Unique stable identifier. Must match `InteractableId` attribute. |
| `actionName` | `string` | Yes | Logical action name (e.g. `"Press"`, `"Pull"`). |
| `displayName` | `string` | Yes | Human-readable label for logging and future UI. |
| `mode` | `"Instant" \| "Hold"` | Yes | Interaction behaviour mode. |
| `getPrimaryPart` | `() -> BasePart?` | Yes | Returns the part used for distance checks. Return `nil` = target removed. |
| `holdDuration` | `number` | Hold only | Server-owned hold duration in seconds. |
| `maxDistance` | `number?` | No | Overrides `GameConfig.Interaction.MaxDistance`. |
| `cooldown` | `number?` | No | Per-target cooldown seconds after completion. |
| `enabled` | `boolean \| () -> boolean \| nil` | No | `false` or resolver returning `false` rejects all requests. |
| `exclusive` | `boolean?` | No | `true` = at most one active Hold session per target. |
| `requiresLineOfSight` | `boolean?` | No | Reserved; not yet enforced by server. |
| `cancelOnMovement` | `boolean?` | No | Cancel Hold if player drifts beyond `maxDistance` mid-session. |
| `cancelOnDamage` | `boolean?` | No | Cancel Hold if player takes any damage mid-session. |
| `CanInteract` | `(Player) -> (boolean, string?)` | No | Custom pre-validation. String reason is server-logged only. |
| `OnStarted` | `(Player, sessionId)` | No | Fires when a Hold session is created successfully. |
| `OnCancelled` | `(Player, sessionId, reason)` | No | Fires on any cancellation path. |
| `OnCompleted` | `(Player, sessionId) -> (boolean, string?)` | No | Fires on Instant dispatch and server-side Hold completion. |
| `Reset` | `() -> ()` | No | Called by `service.resetDefinitions()` on room/round reset. |
| `Cleanup` | `() -> ()` | No | Called during `service.Stop()`. |

All callbacks are wrapped in `pcall`. A faulty callback logs a server warning and never breaks the remote or leaves a stale lock.

---

## Interaction Modes

### Instant

Validates and calls `OnCompleted` in a single request. No session is created. Cooldown applies after successful completion.

Use for: button presses, item pickups, door inspections, one-shot triggers.

### Hold (shared)

Creates a server-owned session. The server's `Heartbeat` drives completion after `holdDuration` seconds. The client displays the `ProximityPrompt` progress bar but does not decide completion.

`exclusive = false` (default) — multiple players may have concurrent sessions on the same target. This is the foundation for cooperative interactions where each player contributes independently.

Use for: lock-picking, reading notices, pulling shared levers that accept parallel inputs.

### Hold (exclusive)

`exclusive = true` — at most one session may hold the lock per target. A second `Begin` request while the lock is held returns `"locked"`. The lock is released on completion, cancellation, expiry, or player disconnect.

Two near-simultaneous `Begin` requests are handled atomically in the `OnServerInvoke` handler: whichever invocation checks `exclusiveLocks[id]` first wins; the other receives `"locked"` immediately.

Use for: control panels, single-use levers, puzzle inputs that must not be doubled.

### Cooperative interactions (future)

Shared Hold sessions give each cooperative puzzle the following primitives:

- `sessionsByTarget[id]` contains all current session IDs for the target
- `OnStarted` fires per player — each player's arrival can be counted
- `OnCancelled` fires per player — a dropout can be detected
- `OnCompleted` fires per player — per-player contribution is acknowledged

A cooperative puzzle module can track "how many players are currently holding" by counting `sessionsByTarget[id]` and fire a separate event when the required count is reached. No changes to `InteractionService` are needed.

---

## Security Model

- The client sends only three operation types: `"instant"`, `"begin"`, `"cancel"`.  
- The server **never** accepts client-provided elapsed time, completion time, distance, session ownership claim, health, success, or reward.
- Session IDs are opaque server-generated strings (`sid_<counter>_<random>`). Clients receive them only to send back on `"cancel"`, where ownership is re-verified.
- All handler callbacks (`getPrimaryPart`, `CanInteract`, `OnStarted`, `OnCancelled`, `OnCompleted`, `Reset`, `Cleanup`) are executed inside `pcall`. Errors are logged server-side and the client receives only a non-sensitive result code.
- Non-sensitive result codes never include internal reasons, stack traces, or handler output.

---

## Result Codes

Codes returned from `InteractionRequest:InvokeServer(...)` to the client:

| Code | Meaning |
|---|---|
| `"ok"` | Operation accepted |
| `"rate_limited"` | Too many requests per second |
| `"invalid_args"` | Malformed, missing, or wrong-type arguments |
| `"not_registered"` | ID not in registry |
| `"no_character"` | Character, Humanoid, or HumanoidRootPart missing |
| `"dead"` | `Humanoid.Health <= 0` |
| `"too_far"` | Distance to target exceeds `maxDistance` |
| `"not_enabled"` | Target disabled or `CanInteract` returned false |
| `"cooldown"` | Per-target cooldown has not expired |
| `"locked"` | Target exclusively locked by another session |
| `"session_limit"` | Player has reached `MaxActiveSessions` |
| `"session_not_found"` | Unknown or already-cleaned-up session ID |
| `"session_expired"` | Session expiry exceeded safety buffer |
| `"not_owner"` | Session ID belongs to a different player |
| `"already_resolved"` | Session already cancelled or completed |
| `"wrong_operation"` | Mode mismatch (e.g. `"begin"` on an Instant target) |
| `"handler_error"` | A callback raised an error; check server logs |

---

## Rate Limits and Cooldowns

### Per-player request rate limit

`GameConfig.Interaction.RateLimitSeconds` (default `0.3` s).  
Applies to `"begin"` and `"instant"` operations. Resets on respawn.  
`"cancel"` is exempt — players must always be able to cancel freely.

### Per-player session limit

`GameConfig.Interaction.MaxActiveSessions` (default `3`).  
A player with this many active Hold sessions cannot begin another.

### Per-target cooldown

Set via `definition.cooldown` (seconds). Applies after any successful completion.  
Clients receive `"cooldown"` state change; prompts are disabled until the server broadcasts `"available"`.

### Session expiry (safety net)

`expiresAt = startTime + holdDuration + GameConfig.Interaction.SessionExpiryBuffer` (default buffer `2` s).  
If a session is not completed or cancelled before `expiresAt`, the Heartbeat force-cancels it with reason `"expired"`. This handles network delays, stalls, and edge cases in the completion path.

---

## Handler Interface

```lua
InteractionService.register("my_door", {
    id           = "my_door",
    actionName   = "Open",
    displayName  = "Door",
    mode         = "Hold",
    holdDuration = 2,
    exclusive    = true,
    cooldown     = 1,
    maxDistance  = 8,
    cancelOnMovement = true,

    getPrimaryPart = function(): BasePart?
        local door = workspace:FindFirstChild("RoomADoor")
        return door and door:IsA("BasePart") and door or nil
    end,

    CanInteract = function(player: Player): (boolean, string?)
        -- Return false to silently block; reason is server-logged only.
        if not hasKey(player) then
            return false, "player does not have the key"
        end
        return true, nil
    end,

    OnStarted = function(player: Player, sessionId: string)
        -- Animate door handle, play sound, etc.
    end,

    OnCancelled = function(player: Player, sessionId: string, reason: string)
        -- Reverse animation, stop sound, etc.
    end,

    OnCompleted = function(player: Player, sessionId: string): (boolean, string?)
        openDoor()
        consumeKey(player)
        return true, nil
    end,

    Reset = function()
        closeDoor()
    end,
})
```

---

## Cancellation and Reset Behaviour

| Trigger | Server action |
|---|---|
| Client sends `"cancel"` | `cancelSession(sid, "player_cancelled")` |
| Player character removed | `cancelPlayerInteractions(player, "player_died")` |
| Player respawns | Rate-limit timestamp cleared; stale sessions already cancelled |
| Player disconnects | `cancelPlayerInteractions(player, "player_disconnected")` |
| Target unregistered | `cancelTargetInteractions(id, "target_removed")` |
| Target becomes disabled | Heartbeat revalidation → `cancelSession(sid, "not_enabled")` |
| Session expiry buffer exceeded | Heartbeat → `cancelSession(sid, "expired")` |
| Player moves too far (if set) | Heartbeat → `cancelSession(sid, "player_moved")` |
| Player takes damage (if set) | Heartbeat → `cancelSession(sid, "player_damaged")` |
| Service stops | `resetAll("service_reset")` then `Cleanup()` per definition |

### Reset API

```lua
-- Cancel all sessions for one player (call on character death, respawn, round reset)
InteractionService.cancelPlayerInteractions(player, "room_reset")

-- Cancel all sessions targeting one interactable (call when disabling a puzzle)
InteractionService.cancelTargetInteractions("lever_01", "puzzle_disabled")

-- Cancel all active sessions and clear all cooldowns (room / round reset)
InteractionService.resetAll("round_reset")

-- Call Reset() on every definition (restore puzzle/prop state)
InteractionService.resetDefinitions()
```

---

## How to Add a Tagged Interactable

### 1. Register on the server

In a Service module (e.g. a future `RoomService`):

```lua
InteractionService.register("chest_01", {
    id           = "chest_01",
    actionName   = "Search",
    displayName  = "Chest",
    mode         = "Instant",
    cooldown     = 5,
    getPrimaryPart = function() return workspace.Room01.Chest end,
    OnCompleted  = function(player, _sessionId)
        -- award loot (server-side only)
        return true, nil
    end,
})
```

### 2. Tag the workspace instance

In Roblox Studio, open the **Tag Editor** (Plugins → Tag Editor) and add the `Interactable` tag to the part or model.

### 3. Set required attributes

| Attribute | Type | Value |
|---|---|---|
| `InteractableId` | string | `"chest_01"` |
| `InteractableMode` | string | `"Instant"` or `"Hold"` |
| `InteractableAction` | string | Prompt ActionText (e.g. `"Search"`) |
| `InteractableDisplay` | string | Prompt ObjectText (optional; defaults to instance Name) |
| `InteractableHoldDuration` | number | Hold duration in seconds (Hold mode only) |

The `InteractionController` creates the `ProximityPrompt` automatically.

---

## Demonstration Setup

`DemoInteractions.luau` registers two interactables that require no gameplay systems.

| ID | Mode | Exclusive | Cooldown | What it does |
|---|---|---|---|---|
| `demo_instant_button` | Instant | No | 2 s | Increments `ButtonPressCount` attribute on `ReplicatedStorage.DemoInteractionState` |
| `demo_hold_lever` | Hold (3 s) | Yes | 5 s | Toggles `LeverState` attribute between `"on"` and `"off"` |

**Studio setup**

1. Create a `BasePart` named `DemoButton` anywhere in `Workspace`.  
   Tag it `Interactable`. Set attributes:  
   `InteractableId = "demo_instant_button"`, `InteractableMode = "Instant"`, `InteractableAction = "Press"`.

2. Create a `BasePart` named `DemoLever` anywhere in `Workspace`.  
   Tag it `Interactable`. Set attributes:  
   `InteractableId = "demo_hold_lever"`, `InteractableMode = "Hold"`, `InteractableAction = "Pull"`, `InteractableHoldDuration = 3`.

3. Play the game. Observe `ReplicatedStorage.DemoInteractionState` attributes in the Explorer.

**Verifying reset**: run `game.ServerScriptService.Server.Services.InteractionService.resetAll("test")` in the server console. The in-flight lever hold should be cancelled and `LeverState` reset to `"off"` by `demo.Stop` teardown.

**Verifying exclusive lock**: have two clients simultaneously hold `DemoLever`. Only the first accepted Begin shows a progress bar; the second client's prompt is disabled immediately via `InteractionStateChanged`.

---

## Running the Pure-Logic Test Suite

The test module does not require Roblox Studio. Run it from the server command bar or a test harness Script:

```lua
local Tests = require(game.ReplicatedStorage.Shared.Tests.InteractionTests)
local passed, total = Tests.run()
-- Prints per-test PASS/FAIL lines and a summary.
-- passed == total means all tests passed.
```

Tests cover: session ID uniqueness, exclusive locking, cooldown timing, expiry logic, replay rejection, session ownership, session limits, rate limiting, state transition safety, concurrent cancellation, and shared mode.

---

## Known Limitations

- `requiresLineOfSight` is declared in the definition schema but not enforced by the server. Line-of-sight checks require ray-casting and will be added when the level geometry is stable.
- The Heartbeat-based completion has up to ~1/60 s timing imprecision relative to `holdDuration`. This is imperceptible to players and acceptable for all current use cases.
- `InteractionService.broadcastState` silently no-ops before `Start` has been called. Callers should register interactables only after `Start`.
- The per-target cooldown key is the `interactableId` only. Per-player-per-target cooldowns are not yet implemented but the `cooldowns` table key can be changed to `userId .. ":" .. id` without breaking the API.
- No automated in-Studio test harness exists yet. The `InteractionTests` module covers pure logic only; lifecycle behavior, replication, and ProximityPrompt rendering require manual Studio playtests.
- `DemoInteractions` calls `require(script.Parent.InteractionService)` in `Stop`. If `InteractionService` is already cleaned up at that point, the unregister calls are silently skipped via `pcall`. This is safe but means definitions may remain in the registry until the server shuts down if Stop order reverses unexpectedly.
