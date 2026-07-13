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
  - Shared config (`GameConfig.luau`), shared types (`Types/init.luau`), Janitor, Logger, ModuleBootstrap utilities.
  - Shared remotes accessor (`Remotes/init.luau`) with `InteractionRequest` RemoteFunction and `InteractionStateChanged` RemoteEvent.
  - Shared types for the full interaction framework (`InteractionDefinition`, `SessionRecord`, result codes).
  - Server bootstrap (`init.server.luau`) and client bootstrap (`init.client.luau`) with idempotent initialization and safe failure handling.
  - `RuntimeStateService` and `RuntimeController` skeleton.
  - Full server-authoritative `InteractionService` with 18-check validation pipeline, Hold/Instant/exclusive modes, heartbeat-driven completion, replay protection, rate limiting, session limits, and reset API.
  - `DemoInteractions` service registering two in-engine fixtures (instant button, exclusive hold lever).
  - Client `InteractionController` managing ProximityPrompts via CollectionService tags.
  - Pure-logic `InteractionTests` suite (18 tests; no Roblox Studio required).
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
- No automated test runner currently executes these tests outside Roblox Studio.
- Tests must be run manually from a Roblox Studio server Script or the command bar; their results have not been recorded in this repository.
- Do not treat the 18 tests as verified until a Studio run is completed and the pass/fail output is documented.

### Implemented: awaiting Roblox Studio verification
- **Milestone 1 — Roblox Foundation:** `In progress` (Studio lifecycle, replication, and bootstrap behavior are unverified).
- **Milestone 2 — Interaction Framework:** `In progress` (Studio ProximityPrompt rendering, hold timing, exclusive locking, death/disconnect cleanup, and state propagation are unverified).
- Code inspection confirms the interaction framework design satisfies: server-authoritative validation, server-generated session IDs, server-owned hold timing, cancellation, replay protection, exclusive/shared locking, cooldowns, enabled-state checks, death/reset/disconnect cleanup, target-removal cleanup, room/round reset API, and pcall-wrapped handler execution.
- These properties are not considered verified until the manual Studio test checklist in `TESTING.md` has been completed and results recorded.

## Missing foundation
- No Roblox Studio place file has been synced with the migrated source tree yet.
- No searchable objects, inventory, keys, doors, puzzles, entities, hiding, flashlight, stun, UI, audio, or save data.
- No automated test framework such as TestEZ yet (InteractionTests uses a minimal custom harness).
- Studio verification of bootstrap lifecycle, replication, and ProximityPrompt behavior is still pending.

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
- **Next milestone:** Complete Studio verification of Milestones 1 and 2 (bootstrap lifecycle + interaction framework).
- After Studio verification: begin Milestone 3 (searchable-object system).

## Assumptions
- TheosRobloxGame is the permanent home for all Roblox game development; Throw-Some-Stuff is retired.
- Rojo will be the source-of-truth sync workflow for future Roblox development.
- `ReplicatedStorage.GameRuntime` is acceptable as a temporary shared runtime state surface for early development.
- Future place-building and validation will happen in Roblox Studio once access is available.
