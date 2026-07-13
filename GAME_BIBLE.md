# GAME_BIBLE

## Game vision
Theo's game is a cooperative Roblox horror escape-room experience for one to six players. Each room should reward curiosity, create uncertainty, escalate pressure, force split-second reactions, and then release tension through progress.

## Gameplay pillars
- **Search with intent:** Players should inspect believable hiding spots and cluttered spaces for useful items or clues.
- **Tension through uncertainty:** Threats, lighting, sound, and partial information should make every choice feel risky.
- **Cooperation matters:** Some puzzles, doors, rescues, and distractions should be easier or only possible with teammates.
- **Readable progress:** Each successful search, solved puzzle, or unlocked passage should clearly move the team forward.
- **Short-term relief, long-term dread:** Safety should feel temporary so the next room restores suspense.

## Core room loop
1. Enter a new room with incomplete information.
2. Search furniture, props, and environmental clues.
3. Build understanding of the room's locks, rules, and hazards.
4. Trigger tension through noise, darkness, limited tools, or entity pressure.
5. Coordinate on a puzzle, escape route, or defensive action.
6. Unlock the exit and gain a short relief beat.
7. Transition into the next room with higher stakes.

## One-to-six-player design
- Solo players must be able to finish core progression with slower pacing and fewer simultaneous requirements.
- Additional players should increase speed, coverage, and survivability without trivializing fear.
- Cooperative mechanics should scale by adding optional parallel tasks, faster searches, shared rescue potential, and multi-step puzzles.
- Entity behavior should adapt to player count through configurable tuning, not hard-coded assumptions.
- Progress blockers should never require more than the active player count.

## System concepts

### Search
- Searchables include closets, drawers, shelves, beds, door backs, crates, and containers.
- Search outcomes can include keys, code fragments, batteries, stun items, force-field consumables, notes, and decoys.
- Each searchable should support reusable configuration for loot tables, cooldowns, single-use state, and audiovisual feedback.

### Inventory
- Players should carry a limited set of tools with clear quick-use behavior.
- Shared progression items should stay authoritative on the server.
- Consumables should support stack limits, use cooldowns, and interruption-safe cleanup.

### Keys and doors
- Doors should support keyed locks, numeric codes, power states, and cooperative interactions.
- Door states should be data-driven so later rooms can reuse the same framework.
- Progress doors should support fail-safe reset behavior if a round resets mid-interaction.

### Puzzles
- Puzzles should combine environmental clues, sequencing, observation, timing, and occasional cooperation.
- Puzzle state should reset cleanly on room or round reset.
- Puzzle modules should expose completion state, reset behavior, and validation hooks.

### Entities
- Entities should create threat through patrols, reactions to noise, scripted appearances, and pursuit.
- Behavior should be driven by a state machine with configurable tuning.
- Capture, stun windows, line-of-sight rules, and retreat logic should all be server-authoritative.

### Hiding
- Hiding spots should provide temporary safety with trade-offs such as reduced awareness, limited duration, or noise risk.
- Hiding availability should remain readable even under stress.
- Exit and interruption rules should be predictable and secure.

### Flashlight
- Flashlights should improve navigation but increase tension through limited power, reveal windows, or threat attraction risk.
- Light behavior should support low-vision accessibility settings where possible.

### Stun and temporary force fields
- Stun items should buy time, not trivialize encounters.
- Temporary force fields should create short relief windows for regrouping or revives.
- Both systems need strict server validation and clear expiration handling.

### Reset and progression
- Room reset should restore temporary objects, puzzle states, searchable availability, and threat state.
- Round reset should restore every player, room chain, and shared progression state without duplicate listeners or orphaned objects.
- Progression should unlock rooms in a readable sequence and support future branching.

### UI
- UI should emphasize objective clarity, teammate state, held item state, and danger feedback.
- Interaction prompts must stay readable on mobile, controller, and keyboard/mouse.
- Panic moments should preserve usability and not bury mission-critical information.

### Audio
- Audio should guide attention, telegraph danger, reward discovery, and punctuate relief.
- Important cues should remain distinguishable from ambient noise.
- Volume spikes should be configurable and accessibility-aware.

### Save data
- Save data should come after the core loop is stable.
- Initial save scope should focus on durable unlocks or meta progression, not active run state.
- Saving should never be required to validate the core room loop.

## Input support
- **Keyboard and mouse:** precise camera control, interaction prompts, quick item use, crouch/hide actions.
- **Controller:** radial or bumper-based item use, large prompts, forgiving focus targets.
- **Mobile:** tap-friendly interactions, larger UI, simplified item switching, readable low-light overlays.

## Accessibility guidance
- Provide options to reduce flashes, jumpscare intensity, loud transient audio, and camera shake.
- Avoid puzzle solutions that depend only on tiny text, subtle color shifts, or rapid audio parsing.
- Keep threat telegraphs readable through multiple channels when possible: sound, animation, lighting, and UI.
- Ensure core progression can be understood without requiring voice chat.

## Definition of fun
The game is fun when players:
- discover useful clues through active searching,
- feel rising tension before danger arrives,
- react quickly under pressure,
- rely on teammates without becoming useless alone,
- and experience clear relief and progress after surviving each room.
