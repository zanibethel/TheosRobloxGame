# ROADMAP

_Status values: Not started, In progress, Complete. Only mark work Complete after verification._

## 1. Project architecture and room lifecycle
- **Goal:** Establish the reusable client/server/shared foundation and room lifecycle hooks.
- **Deliverable:** Rojo project layout, bootstrap scripts, shared config/types/utilities, runtime state service, and reset-safe lifecycle conventions.
- **Dependencies:** None.
- **Acceptance criteria:** Repository structure exists, bootstraps guard against duplicate initialization, lifecycle cleanup pattern is present, and runtime state can initialize without hard crashes when expected instances are missing.
- **Manual Studio tests:** Start a play session, confirm server and client bootstraps run once, confirm `ReplicatedStorage.GameRuntime` attributes populate, and confirm stopping the session does not leave duplicate connections on restart.
- **Status:** In progress — foundation migrated into TheosRobloxGame (the active repository), post-merge lifecycle repair completed, repository automation added, and Roblox Studio verification is still pending.

## 2. Interaction framework
- **Goal:** Create a reusable interaction layer for prompts, validation, and contextual actions.
- **Deliverable:** Shared interaction contracts, server validation layer, and client prompts for interactable objects.
- **Dependencies:** 1.
- **Acceptance criteria:** Interactions can be registered declaratively, validated on the server, and rejected safely when state or arguments are invalid.
- **Manual Studio tests:** Verify one player and two players can interact, cancel, and retry without desync.
- **Status:** In progress — full server-authoritative interaction framework migrated into TheosRobloxGame; pure-logic tests pass in repository; Roblox Studio verification is still pending.

## 3. Lobby and party system
- **Goal:** Give players a safe multiplayer lobby where they can form parties, ready up, count down, and enter the game together.
- **Deliverable:** `LobbyService`, `PartyService`, `TransitionService`, `LobbyController`, `PartyController`, shared enums and types, placeholder UI, and `docs/PARTY_SYSTEM.md`.
- **Dependencies:** 1.
- **Acceptance criteria:** Players spawn in the lobby, can create or join parties, toggle ready, trigger a server-driven countdown, and move together to a test room via `TransitionService.LaunchParty`. Party state is server-authoritative. Countdown cancels immediately if anyone leaves or unreadies. Disconnection and host-leaving are handled cleanly with no stale state.
- **Manual Studio tests:** Solo launch, two-player launch, six-player launch, host leaving, member disconnecting, unready during countdown, countdown cancellation, size control, kick, multiple parties simultaneously.
- **Status:** In progress — all code merged; Roblox Studio verification pending (no place-file sync, no Studio playtest yet).

## 4. Searchable-object system
- **Goal:** Make containers and props searchable with configurable outcomes.
- **Deliverable:** Searchable component/module, loot table config, search animation hooks, and server-owned state.
- **Dependencies:** 1, 2.
- **Acceptance criteria:** Each searchable can be configured, searched once or by cooldown, and replicated consistently across players.
- **Manual Studio tests:** Verify simultaneous searches, empty results, already-open state, and reset behavior.
- **Status:** Not started.

## 5. Inventory and usable-item system
- **Goal:** Track held items and consumables securely.
- **Deliverable:** Server-authoritative inventory service, item definitions, equip/use flow, and UI hooks.
- **Dependencies:** 1, 2, 3.
- **Acceptance criteria:** Inventory changes are validated on the server, replicated clearly, and survive expected respawn/reset flows.
- **Manual Studio tests:** Verify item pickup, item use, item denial, respawn cleanup, and anti-spoof checks.
- **Status:** Not started.

## 5. Locked-door and key system
- **Goal:** Unlock progression through secure door state handling.
- **Deliverable:** Door config, key/code validation, door state replication, and reset behavior.
- **Dependencies:** 1, 2, 4.
- **Acceptance criteria:** Doors reject invalid access, accept valid progression items, and reset cleanly between rounds.
- **Manual Studio tests:** Verify valid and invalid unlocks, co-op door cases, and reset after interruption.
- **Status:** Not started.

## 6. First complete room vertical slice
- **Goal:** Deliver one fully playable room that exercises the core loop.
- **Deliverable:** Searchables, one puzzle, one threat beat, one progression door, and one relief transition.
- **Dependencies:** 1 through 5.
- **Acceptance criteria:** A single room can be entered, explored, solved, and exited with one to six players.
- **Manual Studio tests:** Full solo, two-player, and six-player playthroughs with intentional failure cases.
- **Status:** Not started.

## 7. Entity state machine
- **Goal:** Define the backbone for hostile behavior.
- **Deliverable:** Entity states, transitions, tuning config, and lifecycle hooks.
- **Dependencies:** 1, 6.
- **Acceptance criteria:** Entities transition predictably among idle, patrol, alert, pursue, recover, and reset states.
- **Manual Studio tests:** Force each state transition and verify reset safety.
- **Status:** Not started.

## 8. Entity pursuit and capture
- **Goal:** Add live threat pressure and consequences.
- **Deliverable:** Pursuit logic, capture flow, recover states, and team-facing feedback.
- **Dependencies:** 7.
- **Acceptance criteria:** Pursuit and capture are readable, fair, and server-authoritative.
- **Manual Studio tests:** Verify chase start/stop, capture, interrupted pursuit, and multi-player target switching.
- **Status:** Not started.

## 9. Hiding system
- **Goal:** Give players temporary escape options.
- **Deliverable:** Hiding spot logic, occupancy rules, entry/exit flow, and threat interaction tuning.
- **Dependencies:** 2, 7, 8.
- **Acceptance criteria:** Hiding works consistently, prevents invalid occupancy states, and interacts correctly with pursuit rules.
- **Manual Studio tests:** Verify simultaneous hide attempts, forced exits, and resets during occupancy.
- **Status:** Not started.

## 10. Flashlight and temporary stun
- **Goal:** Add tactical tools that shape tension.
- **Deliverable:** Flashlight item, battery or cooldown tuning, stun item behavior, and safe server validation.
- **Dependencies:** 4, 7, 8.
- **Acceptance criteria:** Tools function reliably, replicate correctly, and do not let clients fake threat control.
- **Manual Studio tests:** Verify darkness readability, stun timing, exhaustion, and exploit attempts.
- **Status:** Not started.

## 11. Cooperative puzzle
- **Goal:** Require teamwork without excluding solo play.
- **Deliverable:** Puzzle with scalable rules for one to six players.
- **Dependencies:** 2, 6.
- **Acceptance criteria:** Puzzle scales to active player count, exposes clear feedback, and resets safely.
- **Manual Studio tests:** Verify solo fallback, two-player coordination, and six-player contention.
- **Status:** Not started.

## 12. Round reset and progression
- **Goal:** Make repeated play reliable.
- **Deliverable:** Round manager, reset pipeline, progression handoff, and disconnect-safe recovery.
- **Dependencies:** 1 through 11.
- **Acceptance criteria:** Deaths, disconnects, and round ends restore a clean playable state without duplicate listeners or orphaned instances.
- **Manual Studio tests:** Verify full reset after failure, disconnect during progress, and repeated restart cycles.
- **Status:** Not started.

## 13. UI, audio, lighting, atmosphere, and polish
- **Goal:** Strengthen fear, clarity, and usability.
- **Deliverable:** HUD polish, interaction feedback, lighting passes, audio cues, and accessibility options.
- **Dependencies:** 6, 8, 9, 10, 11, 12.
- **Acceptance criteria:** Atmosphere increases tension without sacrificing readability or accessibility.
- **Manual Studio tests:** Verify accessibility options, input readability, and panic-moment clarity.
- **Status:** Not started.

## 14. Save data after the core loop is stable
- **Goal:** Persist durable progress only after the gameplay loop is proven.
- **Deliverable:** Save schema, migration plan, failure handling, and minimal persistent progression.
- **Dependencies:** 12, 13.
- **Acceptance criteria:** Save data is scoped, resilient, and does not compromise core-loop reliability.
- **Manual Studio tests:** Verify load/save behavior, migration safety, and failure fallback.
- **Status:** Not started.
