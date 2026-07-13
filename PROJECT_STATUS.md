# PROJECT_STATUS

## Current repository snapshot
- **TheosRobloxGame is the active long-term home** for Theo's Roblox game. All Roblox framework work is now tracked here.
- `TheosRobloxGame.rbxl` — the live Roblox Studio place file — is present and untouched.
- The full Roblox foundation (Milestone 1) and interaction framework (Milestone 2) have been migrated from `zanibethel/Throw-Some-Stuff` into this repository.
- `IDEAS.md` — raw game concept brainstorm — is preserved alongside `GAME_BIBLE.md`.

## Existing systems
- **Godot artifact:** Not present in this repository (was left in Throw-Some-Stuff; unrelated to the Roblox game).
- **Roblox systems now present:**
  - Rojo project layout (`default.project.json`) with three-way `src/shared`, `src/server`, `src/client` layout.
  - Shared config (`GameConfig.luau`, `PartyConfig.luau`, `RoomConfig.luau`), shared types (`Types/init.luau`), Janitor, Logger, ModuleBootstrap utilities.
  - Shared enums (`Enums/PartyState.luau`).
  - Shared remotes accessor (`Remotes/init.luau`) with `InteractionRequest`, `InteractionStateChanged`, `PartyRequest`, `PartyStateChanged`, `PartyListChanged`, `KeyStateChanged`, `RoomStateChanged`, and `RoomFeedback` remotes.
  - Shared types for the full interaction framework (`InteractionDefinition`, `SessionRecord`, result codes) and party system (`PartyState`, `PartyOperation`, `PartyResultCode`, `PartyInfo`, `PartyListEntry`).
  - Server bootstrap (`init.server.luau`) and client bootstrap (`init.client.luau`) with idempotent initialization and safe failure handling.
  - `RuntimeStateService` and `RuntimeController` skeleton.
  - Full server-authoritative `InteractionService` with 18-check validation pipeline, Hold/Instant/exclusive modes, heartbeat-driven completion, replay protection, rate limiting, session limits, and reset API.
  - `DemoInteractions` service registering two in-engine fixtures (instant button, exclusive hold lever).
  - Client `InteractionController` managing ProximityPrompts via CollectionService tags.
  - Pure-logic `InteractionTests` suite (18 tests; no Roblox Studio required).
  - **Milestone 3 — Lobby and party system:**
  - `LobbyService`: positions player characters at the correct spawn point on every join and respawn, routing to lobby or test-room based on session location state.
    - `PartyService`: server-authoritative party management — create, join, leave, ready/unready, kick, size control, server-driven countdown (5 → 1), host transfer, disconnect cleanup, party destruction, per-player rate limiting, and location state updates.
    - `TransitionService`: `LaunchParty()` returns explicit `(success: boolean, resultCode: string?)` — pivots party members to the test-room spawn; designed for a future one-line swap to `TeleportService`.
    - `PlayerLocationService`: server-only service that owns the authoritative player session/location state (Lobby / Launching / InGame). LobbyService reads this state to route respawns; PartyService writes it as the party state machine advances.
    - `LobbyController`: client status bar reflecting `ReplicatedStorage.GameRuntime.Phase`.
    - `PartyController`: full placeholder UI (MainPanel, JoinPanel, PartyPanel) wired to party remotes.
    - `docs/PARTY_SYSTEM.md`: architecture, networking protocol, lifecycle, rate limiting, location-state ownership, state diagram, and testing checklist.
  - **Milestone 4 — First playable search room (in progress):**
    - `TestRoomBuilder`: server service that builds a temporary test room under `workspace.TestRoom` at runtime — floor, walls, ceiling, light, spawn point, searchable drawer, exit door.  Idempotent; cleaned up on service stop.
    - `KeyService`: minimal server-authoritative key ownership for the exit key.  Awards, consumes, and cleans key state.  Fires `KeyStateChanged` to client for display-only.
    - `RoomService`: registers `room_search_drawer` (Hold, exclusive, once-per-session) and `room_exit_door` (Instant, exclusive, once) with `InteractionService`.  Manages drawer/door state, fires `RoomFeedback` and `RoomStateChanged`.
    - `RoomController`: client HUD with "Exit Key: Yes/No" status, "Key found!" / "The door is locked." feedback messages, and "Room Complete" overlay.  Watches `workspace.TestRoom` attribute for respawn persistence.
    - `RoomConfig`: focused config for room dimensions, spawn, drawer, door, hold/tween durations, and key consumption flag.
    - Pure-logic `RoomTests` suite (8 tests; no Roblox Studio required).
    - `docs/FIRST_PLAYABLE_ROOM.md`: architecture, flows, multiplayer rules, and Studio test checklist.
  - GitHub Actions workflow validating JSON, TOML, StyLua formatting, Selene linting, and Rojo buildability.
- **Post-merge repair status:** Bootstrap lifecycle failure handling was repaired after the initial foundation PR so failed startup no longer leaves server/client/module guards locked.

## Current workflow
- Work is done on focused branches, not `main`, with pull requests for review.
- Repository-first validation is separated from manual Roblox Studio testing.
- New work should start by reviewing the docs and then inspecting `/src` and project config.
- Repository automation runs JSON parsing, TOML parsing, StyLua, Selene, and a Rojo build on pull requests and pushes to `main`.
- Repository automation does not replace Roblox Studio testing for lifecycle, replication, lighting, audio, or device input behavior.

## Verification status

### Verified: repository structure
- All source files, configuration files, and documentation are present and correctly laid out in the repository.

### Verified: static validation
- GitHub Actions validates repository-visible JSON/TOML syntax, StyLua formatting, Selene linting, and Rojo buildability on every push and pull request.
- These checks have been confirmed to pass via the Actions workflow on the current branch.

### Written but not yet executed: automated tests
- `InteractionTests.luau` contains 18 pure-logic tests written against a minimal custom harness.
- `PartyTests.luau` contains 10 pure-logic tests for the party system state machine: host transfer, countdown cancellation (leave / unready), size constraint enforcement, launch failure recovery, successful launch, respawn routing (InGame → game spawn; Launching → skip; Lobby → lobby spawn), and rate-limit isolation.
- `RoomTests.luau` contains 8 pure-logic tests for the room state machine: first search awards key, second search rejected, no-key door rejection, key-holder unlocks door with key consumption, single-unlock guarantee, simultaneous-search single-winner, session reset, and disconnect cleanup.
- No automated test runner currently executes these tests outside Roblox Studio.
- Tests must be run manually from a Roblox Studio server Script or the command bar; their results have not been recorded in this repository.
- Do not treat the tests as verified until a Studio run is completed and the pass/fail output is documented.

### Implemented: awaiting Roblox Studio verification
- **Milestone 1 — Roblox Foundation:** `In progress` (Studio lifecycle, replication, and bootstrap behavior are unverified).
- **Milestone 2 — Interaction Framework:** `In progress` (Studio ProximityPrompt rendering, hold timing, exclusive locking, death/disconnect cleanup, and state propagation are unverified).
- **Milestone 3 — Lobby and Party System:** `In progress` — all code present and repository checks pass; Roblox Studio verification still pending (lobby spawn positioning, party UI rendering, countdown behavior, character pivot to test room, InGame respawn routing, and multi-player replication are unverified without a Studio playtest).
- **Milestone 4 — First Playable Search Room:** `In progress` — all code present and repository checks pass; Roblox Studio verification pending (room geometry rendering, ProximityPrompt appearing on Drawer and ExitDoor, Hold search interaction, key HUD, door unlock and tween, "Room Complete" overlay, multiplayer replication, and respawn persistence are unverified without a Studio playtest).

## Missing foundation
- No Roblox Studio place file has been synced with the migrated source tree yet.
- No searchable objects, inventory, keys, doors, puzzles, entities, hiding, flashlight, stun, or save data.
- No automated test framework such as TestEZ yet (InteractionTests uses a minimal custom harness).
- Studio verification of bootstrap lifecycle, replication, ProximityPrompt behavior, lobby spawn, party UI, and test-room transition is still pending.

## Risks
- Because Roblox Studio was unavailable during migration, playability, instance placement, replicated runtime behavior, and lifecycle behavior in live Studio sessions remain unverified.
- Future remote-based systems can introduce trust-boundary bugs if server validation rules are not enforced consistently.
- Reset logic will become a major source of bugs unless every new system adopts the cleanup/lifecycle pattern from the start.

## Architecture decisions
- Use a three-way `src/shared`, `src/server`, and `src/client` layout under Rojo.
- Keep config in shared modules and keep behavior in focused services/controllers.
- Use a generic module bootstrap pattern with explicit `Init`, `Start`, and cleanup hooks.
- Track shared runtime state in `ReplicatedStorage.GameRuntime` for early vertical-slice observability.
- Prefer safe logging and graceful degradation over hard crashes when expected instances are absent.
- Use CollectionService tags (`Interactable`) for ProximityPrompt management on the client.

## Testing limitations
- Automated repository validation can only cover file structure and CLI-available checks.
- Roblox character replication, respawn behavior, local server behavior, lighting, audio, and device-specific UX require Roblox Studio.
- `InteractionTests.luau` covers pure logic (18 tests) but lifecycle, replication, and ProximityPrompt rendering require manual Studio playtests.

## Recommended next milestone
- **Immediate:** Complete Studio verification of Milestones 1 and 2 (bootstrap lifecycle + interaction framework).
- **After Studio verification of M1/M2:** Verify Milestone 3 in Studio (lobby spawn, party UI, countdown, and test-room transition).
- **After Studio verification of M3:** Verify Milestone 4 in Studio (search room geometry, drawer interaction, key HUD, door unlock, Room Complete, multiplayer replication).
- **After Studio verification of M4:** Polish the first playable slice or begin Milestone 5 (full inventory system).

## Assumptions
- TheosRobloxGame is the permanent home for all Roblox game development; Throw-Some-Stuff is retired.
- Rojo will be the source-of-truth sync workflow for future Roblox development.
- `ReplicatedStorage.GameRuntime` is acceptable as a temporary shared runtime state surface for early development.
- Future place-building and validation will happen in Roblox Studio once access is available.
