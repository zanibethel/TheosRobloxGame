# Party System

Milestone 3 technical reference for the Theo's Roblox Game lobby and party system.

---

## Architecture

| Layer | File | Responsibility |
|---|---|---|
| Shared | `src/shared/Config/PartyConfig.luau` | Tuning constants (min/max players, countdown, spawn names, teleport flag, rate-limiting intervals) |
| Shared | `src/shared/Enums/PartyState.luau` | Frozen enum table for party state machine values |
| Shared | `src/shared/Remotes/init.luau` | Adds `PartyRequest`, `PartyStateChanged`, and `PartyListChanged` remotes |
| Shared | `src/shared/Types/init.luau` | Exported types: `PartyState`, `PartyOperation`, `PartyResultCode`, `PartyInfo`, `PartyListEntry` |
| Server | `src/server/Services/PlayerLocationService.luau` | **Owns player session/location state** — single source of truth for Lobby / Launching / InGame |
| Server | `src/server/Services/LobbyService.luau` | Reads PlayerLocationService on every respawn to decide where to send the character |
| Server | `src/server/Services/PartyService.luau` | All party state: create, join, leave, ready, countdown, launch, cleanup, rate limiting |
| Server | `src/server/Services/TransitionService.luau` | `LaunchParty()` interface — returns explicit success/failure result |
| Client | `src/client/Controllers/LobbyController.luau` | Status bar showing game phase from `ReplicatedStorage.GameRuntime` |
| Client | `src/client/Controllers/PartyController.luau` | Full party UI: MainPanel, JoinPanel, PartyPanel with all controls |

---

## Player Session / Location State

**Owner: `PlayerLocationService`.**

`PlayerLocationService` is the single source of truth for where each player belongs.  
No other module holds a copy of this state.

### Location values

| Value | Meaning |
|---|---|
| `Lobby` | Player is in the lobby (default for new and unassigned players) |
| `Launching` | Player's party triggered launch; movement is in progress |
| `InGame` | Player's party completed launch; player is in the game world |

### Who reads and writes it

| Action | Writer | Reader |
|---|---|---|
| Player joins server | implicit default (Lobby) | LobbyService |
| Party countdown expires → Launching | PartyService | LobbyService |
| Successful launch → InGame | PartyService | LobbyService |
| Launch failure → Lobby | PartyService | LobbyService |
| Player leaves / is kicked | PartyService | LobbyService |
| Party destroyed | PartyService | LobbyService |
| Player disconnects | PlayerLocationService (self-clean) | — |
| Service stops | PlayerLocationService (self-clear) | — |

### Respawn routing in `LobbyService`

```
CharacterAdded fires
        │
        ▼
getLocation(player)
        │
        ├─ Lobby     → pivot to lobby spawn (or FallbackSpawnPosition)
        ├─ InGame    → pivot to test-room spawn (or TestRoom.FallbackSpawnPosition)
        └─ Launching → do nothing (TransitionService will position the player)
```

State is **never placed on the client**.

---

## Networking

### PartyRequest (RemoteFunction)

Client → Server on every party action.

```
InvokeServer(operation, arg1?)
  operation : "create" | "join" | "leave" | "ready" | "unready" | "start" | "cancel" | "kick" | "setSize"
  arg1      : string  for "join"    (partyId)
               number  for "kick"    (target userId)
               number  for "setSize" (new max-player count)
               nil     for all other operations

Returns: (success: boolean, code: PartyResultCode, data: any?)
  data is partyId (string) only on a successful "create"
```

The server validates every argument before acting:
- `operation` must be a string in the known set; unknown operations return `invalid_args`.
- `arg1` type is checked per operation; mismatches return `invalid_args`.
- Every request is rate-checked before dispatch; excess requests return `rate_limited` and **do not mutate state or trigger broadcasts**.
- Every handler is wrapped in `pcall`; unhandled errors return `internal_error`.

### PartyStateChanged (RemoteEvent)

Server → specific client whenever that player's party state changes.

```
FireClient(player, partyInfo | nil)
  nil   → player left or has no party
  table → PartyInfo read-only snapshot
```

PartyInfo fields:
```
partyId            string
hostName           string
maxPlayers         number
playerCount        number
players            { PartyPlayerInfo }
state              string  (PartyState value)
countdownRemaining number? (present only during Countdown state)
```

PartyPlayerInfo fields:
```
name          string
displayName   string
userId        number
isReady       boolean
isHost        boolean
```

### PartyListChanged (RemoteEvent)

Server → all clients whenever the set of joinable (Waiting) parties changes.

```
FireAllClients(list)
  list → array of PartyListEntry
```

PartyListEntry fields:
```
partyId      string
hostName     string
playerCount  number
maxPlayers   number
```

---

## Party Lifecycle

```
[No Party]
    │  create
    ▼
 Waiting ◄────────────────────────────────────────────────┐
    │  all ready + host starts                            │
    ▼                                                     │
 Countdown ──── member leaves / unreadies / host cancels ─┘
    │  countdown expires
    ▼
 Launching  (all members set to Launching location)
    │  TransitionService.LaunchParty() returns (true, nil)
    ▼
 InGame     (all members set to InGame location)
    │  (future: round end)
    ▼
 Closed (party destroyed; all members reset to Lobby location)
```

### State transitions

| From | Event | To |
|---|---|---|
| — | `create` | Waiting |
| Waiting | `join` (other player) | Waiting |
| Waiting | `ready` / `unready` | Waiting |
| Waiting | `kick` | Waiting |
| Waiting | `setSize` | Waiting |
| Waiting | all ready + `start` | Countdown |
| Countdown | `unready` | Waiting (countdown cancelled) |
| Countdown | member leaves | Waiting (countdown cancelled) |
| Countdown | host `cancel` | Waiting |
| Countdown | timer expires | Launching |
| Launching | `LaunchParty()` returns `(true, nil)` | InGame |
| Launching | `LaunchParty()` returns `(false, code)` | Waiting (recovered; members reset to Lobby) |
| Any | all members leave | Closed |
| Any | host leaves | host transferred; Waiting |

---

## Countdown

The server drives the countdown in a `task.spawn` thread.

1. Host calls `start` — all conditions validated server-side.
2. `party.state` set to `Countdown`, `countdownRemaining = CountdownSeconds` (default 5).
3. `PartyStateChanged` fired to all members so clients show "5".
4. Server waits 1 second per tick, decrementing `countdownRemaining` and re-firing.
5. On the final tick the state changes to `Launching`, all members are set to `Launching` location, and `TransitionService.LaunchParty` is called.
6. `LaunchParty` returns `(success: boolean, resultCode: string?)`.
7. On success (`true, nil`) the state becomes `InGame` and all members are set to `InGame` location.
8. On failure the state recovers to `Waiting`, all members are reset to `Lobby` location, and both remotes are re-broadcast.

**Cancellation:**  
Any of the following cancels the countdown immediately:
- A member calls `unready`.
- A member or the host leaves (or disconnects).
- The host calls `cancel`.
- The party is destroyed.

`task.cancel` is called on the thread, then `party.state` is reset to `Waiting` and both remotes are re-broadcast.

---

## TransitionService Interface

```lua
TransitionService.LaunchParty(party: { players: { Player }, partyId: string }): (boolean, string?)
```

Returns `(success, resultCode?)`.

- `success = true, resultCode = nil` — all players were moved; party may enter InGame.
- `success = false, resultCode = "not_implemented"` — `FutureTeleportEnabled` is true but TeleportService is not yet implemented; party recovers to Waiting.
- `success = false, resultCode = "internal_error"` — unexpected error; party recovers to Waiting.

PartyService enters `InGame` **only** after a `true` result.  
On any non-`true` result, the party is restored to Waiting and all members are reset to Lobby location.

Current behaviour (`FutureTeleportEnabled = false`):
- Resolves `workspace[TestRoom.SpawnFolderName][TestRoom.SpawnPartName]` or the fallback position.
- Pivots each player's character to a slightly offset CFrame to avoid stacking.
- Returns `true, nil`.

Future behaviour (`FutureTeleportEnabled = true`):
- Replace the character-pivot block with `TeleportService:TeleportAsync`.
- Return `false, "not_implemented"` until fully implemented (causes party to recover to Waiting instead of silently failing).

---

## Rate Limiting

PartyService applies per-player rate limiting before every dispatched operation.  
Rejected requests **do not mutate any party state or trigger any remote broadcasts**.  
Rate-limit records are cleared when a player disconnects and when the service stops.

Tuning values live in `PartyConfig.RateLimiting`:

| Key | Default | Description |
|---|---|---|
| `GlobalMinInterval` | 0.5 s | Minimum elapsed seconds between any two requests |
| `OperationIntervals.create` | 5 s | Per-player minimum between `create` calls |
| `OperationIntervals.join` | 2 s | Per-player minimum between `join` calls |
| `OperationIntervals.start` | 3 s | Per-player minimum between `start` calls |
| `OperationIntervals.kick` | 1 s | Per-player minimum between `kick` calls |
| `OperationIntervals.setSize` | 1 s | Per-player minimum between `setSize` calls |
| `OperationIntervals.ready` | 1 s | Per-player minimum between `ready` calls |
| `OperationIntervals.unready` | 1 s | Per-player minimum between `unready` calls |

---

## Lobby Spawn

`LobbyService` connects to `Players.PlayerAdded` and each player's `CharacterAdded`.  
On each spawn it reads the player's location from `PlayerLocationService` and routes accordingly:

1. **Lobby (default):** pivot to `workspace[Lobby.SpawnFolderName][Lobby.SpawnPartName] + (0,3,0)`, or `Lobby.FallbackSpawnPosition`.
2. **InGame:** pivot to `workspace[TestRoom.SpawnFolderName][TestRoom.SpawnPartName] + (0,3,0)`, or `TestRoom.FallbackSpawnPosition`.
3. **Launching:** no action — TransitionService will position the player when launch completes.

---

## Future TeleportService Integration

1. Set `PartyConfig.FutureTeleportEnabled = true`.
2. Inside `TransitionService.LaunchParty`, replace the character-pivot block with:
   ```lua
   local TeleportService = game:GetService("TeleportService")
   TeleportService:TeleportAsync(placeId, party.players, teleportOptions)
   ```
3. Change the final `return false, "not_implemented"` to `return true, nil` after the teleport succeeds.
4. Add a `placeId` field to `PartyConfig.TestRoom` (or introduce a separate config table).
5. Handle `TeleportService` errors and return `false, "teleport_error"` on failure.

No other files require changes.

---

## Testing

### Repository checks (automated)

- JSON syntax — `python` validation script
- TOML syntax — `python` validation script
- StyLua formatting — `stylua --check src`
- Selene linting — `selene src`
- Rojo build — `rojo build default.project.json --output /tmp/TheosRobloxGame.rbxlx`

### Pure-logic test suites (no Studio required)

Run from a server Script or command bar:

```lua
-- Party system state machine
local PartyTests = require(game.ReplicatedStorage.Shared.Tests.PartyTests)
local passed, total = PartyTests.run()
print(passed .. "/" .. total .. " tests passed")

-- Interaction framework
local InteractionTests = require(game.ReplicatedStorage.Shared.Tests.InteractionTests)
local passed2, total2 = InteractionTests.run()
print(passed2 .. "/" .. total2 .. " tests passed")
```

`PartyTests` covers (10 tests):
- Host transfer on leave
- Countdown cancellation when member leaves
- Countdown cancellation when player unreadies
- Party size cannot be set below current member count
- Launch failure restores Waiting state
- Successful launch enters InGame state
- InGame respawn resolves to game spawn (not lobby)
- Launching respawn is skipped entirely
- New/unassigned players spawn in the lobby
- Rate-limited requests do not mutate state

### Roblox Studio manual test checklist

#### Lobby spawn

- [ ] Player joins → character pivots to lobby spawn (or fallback if Lobby folder absent)
- [ ] Player dies and respawns in Lobby state → character returns to lobby spawn
- [ ] Player dies and respawns while InGame → character appears at test-room spawn, not lobby
- [ ] Player dies during Launching state → character is not moved by LobbyService (TransitionService handles placement)
- [ ] Multiple players join → all appear at or near lobby spawn without overlap

#### Party creation

- [ ] Click "Create Party" → party panel appears with own name as host
- [ ] Creating a second party while already in one → rejected (already_in_party)

#### Party join

- [ ] Second player clicks "Join Party" → party list shows first player's party
- [ ] Clicking "Join" on a party entry → joins successfully, both see updated member list
- [ ] Joining a full party → rejected (party_full)
- [ ] Joining a locked (Countdown / InGame) party → rejected (party_locked)

#### Ready system

- [ ] All members click "Ready" → button text updates
- [ ] Host clicks "Start Game" with all ready → countdown begins
- [ ] Host clicks "Start Game" when not all ready → rejected (not_all_ready)

#### Countdown

- [ ] Countdown shows 5 → 4 → 3 → 2 → 1 on all clients
- [ ] Member clicks "Unready" during countdown → countdown cancels, state → Waiting
- [ ] Member leaves during countdown → countdown cancels
- [ ] Host clicks "Cancel Countdown" → countdown cancels
- [ ] Countdown completes → characters pivot to TestRoom spawn (or fallback position)

#### Host leaving

- [ ] Host leaves → host transferred to next member, party remains Waiting
- [ ] Host leaves as the only member → party destroyed, no party panel shown

#### Player disconnects

- [ ] Player disconnects mid-party → removed cleanly, party continues if others remain
- [ ] Host disconnects → host transferred; if alone, party destroyed

#### Party size control

- [ ] Host adjusts max-player count via +/− buttons → party list updated
- [ ] Setting size below current count → rejected (invalid_size)
- [ ] Non-host cannot see size controls

#### Kick

- [ ] Host clicks "Kick" on a non-host member → member removed from party
- [ ] Kick during countdown → countdown cancels first, then member removed

#### Rate limiting

- [ ] Spam PartyRequest at high frequency → excess requests return rate_limited
- [ ] Verify rate-limited requests do not change any party state
- [ ] Verify no broadcast fires for rate-limited requests

#### Solo play (1 player)

- [ ] Create party, ready up, start → countdown begins, launch succeeds
- [ ] Player is InGame after launch → death respawns at test-room spawn

#### Two-player play

- [ ] Full ready → start → both pivot to test room correctly

#### Six-player play

- [ ] Six players join same party → all listed in member list, all ready, launch moves all

#### Cleanup

- [ ] Stop and restart play session → no duplicate listeners, no stale party state
- [ ] Multiple rapid party create/destroy cycles → no orphaned instances or log spam
