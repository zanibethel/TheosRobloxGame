# Party System

Milestone 3 technical reference for the Theo's Roblox Game lobby and party system.

---

## Architecture

| Layer | File | Responsibility |
|---|---|---|
| Shared | `src/shared/Config/PartyConfig.luau` | Tuning constants (min/max players, countdown, spawn names, teleport flag) |
| Shared | `src/shared/Enums/PartyState.luau` | Frozen enum table for party state machine values |
| Shared | `src/shared/Remotes/init.luau` | Adds `PartyRequest`, `PartyStateChanged`, and `PartyListChanged` remotes |
| Shared | `src/shared/Types/init.luau` | Exported types: `PartyState`, `PartyOperation`, `PartyResultCode`, `PartyInfo`, `PartyListEntry` |
| Server | `src/server/Services/LobbyService.luau` | Spawns characters at the lobby position on join and respawn |
| Server | `src/server/Services/PartyService.luau` | All party state: create, join, leave, ready, countdown, launch, cleanup |
| Server | `src/server/Services/TransitionService.luau` | `LaunchParty()` interface — local character move now, TeleportService later |
| Client | `src/client/Controllers/LobbyController.luau` | Status bar showing game phase from `ReplicatedStorage.GameRuntime` |
| Client | `src/client/Controllers/PartyController.luau` | Full party UI: MainPanel, JoinPanel, PartyPanel with all controls |

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
 Launching
    │  TransitionService.LaunchParty() succeeds
    ▼
 InGame
    │  (future: round end)
    ▼
 Closed (party destroyed)
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
| Launching | `LaunchParty()` succeeds | InGame |
| Launching | `LaunchParty()` fails | Waiting (recovered) |
| Any | all members leave | Closed |
| Any | host leaves | host transferred; Waiting |

---

## Countdown

The server drives the countdown in a `task.spawn` thread.

1. Host calls `start` — all conditions validated server-side.
2. `party.state` set to `Countdown`, `countdownRemaining = CountdownSeconds` (default 5).
3. `PartyStateChanged` fired to all members so clients show "5".
4. Server waits 1 second per tick, decrementing `countdownRemaining` and re-firing.
5. On the final tick the state changes to `Launching` and `TransitionService.LaunchParty` is called.
6. On success the state becomes `InGame`.
7. On failure the state recovers to `Waiting` and `PartyListChanged` is re-broadcast.

**Cancellation:**  
Any of the following cancels the countdown immediately:
- A member calls `unready`.
- A member or the host leaves (or disconnects).
- The host calls `cancel`.
- The party is destroyed.

`task.cancel` is called on the thread, then `party.state` is reset to `Waiting` and both remotes are re-broadcast.

---

## Lobby Spawn

`LobbyService` connects to `Players.PlayerAdded` and each player's `CharacterAdded`.  
On each spawn it resolves the lobby spawn point:

1. Look for `workspace[PartyConfig.Lobby.SpawnFolderName][PartyConfig.Lobby.SpawnPartName]`.
2. If found, pivot the character to that part's `CFrame + Vector3.new(0, 3, 0)`.
3. If not found, use `PartyConfig.Lobby.FallbackSpawnPosition`.

---

## TransitionService Interface

```lua
TransitionService.LaunchParty(party: { players: { Player }, partyId: string })
```

Current behaviour (`FutureTeleportEnabled = false`):
- Resolves `workspace[TestRoom.SpawnFolderName][TestRoom.SpawnPartName]` or the fallback position.
- Pivots each player's character to a slightly offset CFrame to avoid stacking.

Future behaviour (`FutureTeleportEnabled = true`):
- Replace the character-pivot block with `TeleportService:TeleportAsync`.
- The function signature must remain identical; `PartyService` requires no changes.

---

## Future TeleportService Integration

1. Set `PartyConfig.FutureTeleportEnabled = true`.
2. Inside `TransitionService.LaunchParty`, replace the character-pivot block with:
   ```lua
   local TeleportService = game:GetService("TeleportService")
   TeleportService:TeleportAsync(placeId, party.players, teleportOptions)
   ```
3. Add a `placeId` field to `PartyConfig.TestRoom` (or introduce a separate config table).
4. Handle `TeleportService` errors and broadcast failure back through `PartyService`.

No other files require changes.

---

## Testing

### Repository checks (automated)
- JSON syntax — `python` validation script
- TOML syntax — `python` validation script
- StyLua formatting — `stylua --check src`
- Selene linting — `selene src`
- Rojo build — `rojo build default.project.json --output /tmp/TheosRobloxGame.rbxlx`

### Roblox Studio manual test checklist

#### Lobby spawn
- [ ] Player joins → character appears near lobby spawn (or fallback position if Lobby folder absent)
- [ ] Player dies and respawns → character appears at lobby spawn again
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

#### Solo play (1 player)
- [ ] Create party, ready up, start → countdown begins, launch succeeds
- [ ] PartyConfig.Party.MinPlayers = 1 required for solo start

#### Two-player play
- [ ] Full ready → start → both pivot to test room correctly

#### Six-player play
- [ ] Six players join same party → all listed in member list, all ready, launch moves all

#### Cleanup
- [ ] Stop and restart play session → no duplicate listeners, no stale party state
- [ ] Multiple rapid party create/destroy cycles → no orphaned instances or log spam
