# FIRST_PLAYABLE_ROOM

This document covers the first playable search-room vertical slice introduced in Milestone 4.

---

## Overview

After a party launches from the lobby, players arrive in a small dark room that contains:

- A visible floor, four walls, and a ceiling
- A searchable drawer that can yield the exit key
- A locked exit door
- A clear success state when the door is opened

All geometry and interactable state are generated and managed at runtime from server code.  No manually placed Studio objects are required for a fresh Rojo build to be testable.

---

## Architecture

### Runtime-generated room — `TestRoomBuilder`

`src/server/Services/TestRoomBuilder.luau`

Creates a `Folder` named `TestRoom` under `workspace` during `Start()`, using only basic `Part` instances.  The folder name matches `PartyConfig.TestRoom.SpawnFolderName` ("TestRoom") so `LobbyService` and `TransitionService` can resolve spawn points immediately.

**Idempotency:** If `workspace.TestRoom` already exists when `Start()` runs (e.g. a Studio-placed version), the builder logs a warning and skips construction.

**Cleanup:** The folder and all its children are registered with the service janitor and destroyed when `Stop()` is called.

**Parts created:**

| Name | Purpose |
|---|---|
| Floor | Solid walkable surface; top surface at Y = 2 |
| WallNorthLeft | Left section of the north (exit) wall, beside the doorway |
| WallNorthRight | Right section of the north (exit) wall, beside the doorway |
| WallNorthTop | Top section of the north wall, above the doorway opening |
| WallSouth/East/West | Solid enclosing walls (south, east, west are single slabs) |
| Ceiling | Overhead slab |
| RoomLight | Anchored part with a PointLight for basic illumination |
| SpawnPoint | Invisible, no-collision part at `RoomConfig.SpawnPosition` |
| Drawer (Model) | Searchable prop; Body part is tagged "Interactable" |
| ExitDoor (Model) | Door frame + DoorPanel; panel is tagged "Interactable" |

**Interactable tagging:** The Drawer Body and DoorPanel are tagged with the CollectionService tag `"Interactable"` and include the attributes `InteractionController` reads (`InteractableId`, `InteractableMode`, `InteractableAction`, `InteractableDisplay`, `InteractableHoldDuration` where applicable).  ProximityPrompts are therefore built automatically on all clients without any additional server-to-client RPC.

**Replacing with a Studio map:** Delete `TestRoomBuilder.luau` and build the room in Studio with parts named and tagged identically.  `RoomService` does not depend on TestRoomBuilder; it only reads from `workspace.TestRoom` at interaction time.

---

### Key ownership — `KeyService`

`src/server/Services/KeyService.luau`

Tracks a single `boolean` per player indicating whether they hold the exit key.  This is the narrowest possible scope needed for this slice; a full inventory system replaces it in Milestone 5.

**Public API:**

| Function | Description |
|---|---|
| `KeyService.awardKey(player)` | Give the key; no-op if already held |
| `KeyService.hasKey(player)` | Returns `true` when the player holds the key |
| `KeyService.consumeKey(player)` | Remove the key (called after door opens) |
| `KeyService.cleanPlayer(player)` | Remove key record on disconnect |
| `KeyService.reset()` | Clear all keys for a session/room reset |

**Security:** Key state lives entirely on the server.  Clients receive only a display-safe `boolean` via the `KeyStateChanged` RemoteEvent.  A client cannot forge key ownership.

**Cleanup:** `Players.PlayerRemoving` fires `cleanPlayer`.  The service janitor clears the table on `Stop()`.

---

### Room interaction and state — `RoomService`

`src/server/Services/RoomService.luau`

Registers the two room interactions with `InteractionService` and owns the per-session room state flags (`drawerSearched`, `doorUnlocked`).

#### Searchable drawer — `room_search_drawer`

- **Mode:** Hold (`RoomConfig.SearchHoldDuration` seconds, default 2 s)
- **Exclusive:** Yes (only one player can hold at a time)
- **Enabled resolver:** Returns `false` once `drawerSearched = true`, disabling the prompt globally
- **CanInteract:** Returns `false` if already searched
- **OnCompleted:**
  1. Sets `drawerSearched = true`
  2. Changes the drawer colour (replicated automatically)
  3. Calls `KeyService.awardKey(player)`
  4. Fires `RoomFeedback("Key found!")` to the searching player
- **Duplicate/simultaneous safety:** `exclusive = true` prevents two simultaneous Hold sessions.  The double-check in `OnCompleted` guards against a theoretical race where two requests complete before the first sets `drawerSearched`.

#### Exit door — `room_exit_door`

- **Mode:** Instant
- **Exclusive:** Yes
- **Enabled resolver:** Returns `false` once `doorUnlocked = true`
- **CanInteract:**
  - Door already unlocked → return `false`
  - Player has no key → fire `RoomFeedback("The door is locked.")`, return `false`
  - Otherwise → return `true`
- **OnCompleted:**
  1. Double-checks `doorUnlocked` (guard against concurrent request)
  2. Sets `doorUnlocked = true`
  3. Calls `KeyService.consumeKey(player)` if `RoomConfig.ConsumeKeyOnUnlock`
  4. Calls `TweenService:Create` to slide the door panel upward
  5. Sets `workspace.TestRoom:SetAttribute("RoomState", "complete")` and fires `RoomStateChanged("complete")` to all clients

**Reset:** `RoomService.reset(KeyService)` restores `drawerSearched`, `doorUnlocked`, drawer colour, door `CFrame`, door `CanCollide`, and all player keys.

---

### Client HUD — `RoomController`

`src/client/Controllers/RoomController.luau`

Creates a `ScreenGui` named `RoomHUD` (ResetOnSpawn = false) with three elements:

| Element | Location | Purpose |
|---|---|---|
| `KeyStatusLabel` | Bottom-right | "Exit Key: No" / "Exit Key: Yes" |
| `FeedbackLabel` | Centre-screen | Temporary messages (3-second auto-hide) |
| `RoomCompleteFrame` | Centre-upper | "Room Complete" overlay |

**Remote listeners:**

| Remote | Effect |
|---|---|
| `KeyStateChanged` | Updates `KeyStatusLabel` text and colour |
| `RoomStateChanged` | Shows `RoomCompleteFrame` when `state == "complete"` |
| `RoomFeedback` | Shows `FeedbackLabel` with the message for 3 seconds |

**Persistence across respawn:** The controller watches `workspace.TestRoom:GetAttributeChangedSignal("RoomState")` so players who respawn after the room is complete see the "Room Complete" overlay without a new server broadcast.

---

### Configuration — `RoomConfig`

`src/shared/Config/RoomConfig.luau`

| Key | Default | Description |
|---|---|---|
| `Room.Width` | 40 | Room width in studs (X) |
| `Room.Length` | 40 | Room length in studs (Z) |
| `Room.Height` | 15 | Wall height in studs (Y) |
| `Room.FloorThickness` | 2 | Floor slab thickness |
| `Room.WallThickness` | 1 | Wall slab thickness |
| `Room.CenterX/Y/Z` | 100, 0, 0 | World-space origin |
| `SpawnPosition` | (100, 2, −5) | SpawnPoint part centre |
| `DrawerPosition` | (92, 3.5, −8) | Drawer Body centre |
| `DrawerSize` | (3, 2, 2) | Drawer dimensions |
| `DoorPosition` | (100, 6, 19.5) | Door panel centre |
| `DoorSize` | (4, 8, 1) | Door panel dimensions |
| `DoorClearance` | 0.2 | Gap in studs between door edge and wall opening |
| `SearchHoldDuration` | 2 | Hold seconds to search |
| `DoorOpenDuration` | 0.6 | Tween duration for door open |
| `ConsumeKeyOnUnlock` | true | Remove key after door opens |

---

### Remotes added

| Name | Type | Direction | Payload |
|---|---|---|---|
| `KeyStateChanged` | RemoteEvent | Server → one client | `(hasKey: boolean)` |
| `RoomStateChanged` | RemoteEvent | Server → all clients | `(state: string)` |
| `RoomFeedback` | RemoteEvent | Server → one client | `(message: string)` |

---

## Search flow

```
Player approaches drawer
  → ProximityPrompt appears (Hold mode, 2 s)
  → Player holds prompt
    → InteractionService: Begin accepted (exclusive lock acquired)
    → 2 s elapses server-side
    → InteractionService: OnCompleted fires
      → drawerSearched = true
      → Drawer colour changes (replicated)
      → KeyService.awardKey(player)
      → KeyStateChanged fires to player ("Exit Key: Yes")
      → RoomFeedback fires to player ("Key found!")
  → Prompt disabled globally (enabled resolver returns false)
```

---

## Key ownership flow

```
KeyService.awardKey(player)
  → playerKeys[player] = true
  → KeyStateChanged:FireClient(player, true)

KeyService.consumeKey(player)          [called after door opens]
  → playerKeys[player] = nil
  → KeyStateChanged:FireClient(player, false)

KeyService.cleanPlayer(player)         [called on PlayerRemoving]
  → playerKeys[player] = nil
  (no remote fire — player has disconnected)

KeyService.reset()                     [called on session reset]
  → clears all entries
  → fires KeyStateChanged(false) to each player still in game
```

---

## Door flow

```
Player with key approaches exit door
  → ProximityPrompt appears (Instant mode)
  → Player triggers prompt
    → InteractionService: handleInstant
      → CanInteract: player has key → passes
      → OnCompleted:
          doorUnlocked = true
          KeyService.consumeKey(player)
          TweenService slides door panel upward (DoorOpenDuration seconds)
          task.delay → doorPart.CanCollide = false
          workspace.TestRoom:SetAttribute("RoomState", "complete")
          RoomStateChanged:FireAllClients("complete")
  → Prompt disabled globally (enabled resolver returns false)
  → Door opening is passable: DoorPanel is above the WallNorthLeft/Right/Top
    opening, CanCollide disabled — players can walk through the gap

Player without key approaches exit door
  → Player triggers prompt
    → CanInteract: no key → RoomFeedback:FireClient("The door is locked.")
    → Returns false → "not_enabled" code returned to client
```

---

## Multiplayer rules

- **One player finds the key, others see state replicate:** The drawer colour change is a server-side property mutation; it replicates automatically to all clients.  The key HUD update fires only to the player who searched.
- **Two players search simultaneously:** `exclusive = true` and the server-side `drawerSearched` double-check ensure exactly one `OnCompleted` awards a key.  The losing player's session is rejected with `"locked"`.
- **Two players attempt the door simultaneously:** `exclusive = true` prevents both Instant interactions from completing concurrently.  The `doorUnlocked` double-check in `OnCompleted` is an additional safety net.
- **Late respawn:** `LobbyService` routes InGame players to the test-room spawn.  `RoomController` reads `workspace.TestRoom:GetAttribute("RoomState")` on character load to restore the "Room Complete" overlay.

---

## Room session lifecycle

`TransitionService` enforces one active test-room party at a time.

| Event | Behaviour |
|---|---|
| Party countdown completes → launch | `TransitionService.LaunchParty` checks occupancy; if free, resets room state (drawer, door, keys, `RoomState` attribute) and marks the room occupied |
| Second party tries to launch while room is occupied | Returns `(false, "room_in_use")` → PartyService restores the party to `Waiting` |
| Active party is destroyed (all players leave or disconnect) | `PartyService.destroyParty` calls `TransitionService.releaseRoom(partyId)` → occupancy cleared |
| Service stop | `activeRoomPartyId` is cleared unconditionally |

**One-session constraint:** This milestone enforces a single active test-room session.  Multi-room support or a queue system is a future concern.

---

## What is temporary and will be replaced

| Temporary component | Replacement |
|---|---|
| `TestRoomBuilder` service | Hand-crafted Studio room |
| `KeyService` (single-key tracking) | Full inventory system (Milestone 5) |
| `RoomService` (session flags) | Generalised searchable + door system |
| `RoomConfig` geometry | Room data sourced from Studio map |
| "Room Complete" stays in room | Transition to next room (later milestone) |

---

## Studio test checklist

These tests must be performed manually in Roblox Studio because they depend on replication, character physics, and ProximityPrompt rendering.

### Setup
- [ ] Rojo sync (or build) populates the place file from source
- [ ] Play session starts without bootstrap errors in the output window
- [ ] `workspace.TestRoom` folder exists with floor, WallNorthLeft/Right/Top, other walls, ceiling, and a point light
- [ ] Drawer and exit door are visible inside the room
- [ ] SpawnPoint is present (even if invisible)
- [ ] North wall shows a clear rectangular opening around the exit door (no solid wall behind the door panel)

### Party launch to room
- [ ] Create a party, ready up, start → countdown completes → character pivots into the room
- [ ] Character lands on the floor (not below it)
- [ ] "Exit Key: No" label is visible in the bottom-right corner

### Search the drawer
- [ ] Walk near the drawer → ProximityPrompt "Search Drawer" appears
- [ ] Hold the prompt for the full 2 s → drawer changes colour
- [ ] "Key found!" message appears briefly in the centre of the screen
- [ ] "Exit Key: Yes" label replaces "Exit Key: No" in bottom-right
- [ ] Second player walking to the drawer sees no prompt (already searched)

### Exit door — no key
- [ ] Walk near the exit door (without a key) → ProximityPrompt "Use Key" appears
- [ ] Trigger the prompt → "The door is locked." appears briefly
- [ ] Door does not move

### Exit door — with key
- [ ] With the key, trigger the door prompt → door panel slides upward
- [ ] "Room Complete" overlay appears in the upper-centre of the screen
- [ ] Door prompt is gone (disabled)
- [ ] Door CanCollide is false after the tween completes
- [ ] Player can physically walk through the doorway opening (no invisible wall blocking the passage)

### Room session and reset
- [ ] A second party launching while room is occupied sees launch fail and party returns to Waiting
- [ ] After all players from the active party disconnect, a new party can launch and receives a clean room
- [ ] On a fresh session: drawer colour is original, door is in closed position and CanCollide is true, RoomState attribute is "searching"

### Multiplayer
- [ ] Two players: one searches, other sees drawer colour change replicated
- [ ] Two players attempt to hold the drawer simultaneously → only one search completes
- [ ] Two players attempt the door at the same moment → only one unlock occurs
- [ ] "Room Complete" appears on all clients when door opens

### Respawn
- [ ] Die after the room is complete → respawn at room spawn → "Room Complete" overlay shows

### Reset / disconnect
- [ ] (Server console) Call `RoomService.reset(KeyService)` → drawer resets, door resets
- [ ] Disconnect with the key → key record is cleaned (no orphan state)

### Known limitations (as of this milestone)
- No transition out of the room after completion; players remain for inspection
- No entity, puzzle, or hazard
- Room geometry is procedural and placeholder; Studio map comes later
- All Studio tests are pending until a Studio playtest is performed
