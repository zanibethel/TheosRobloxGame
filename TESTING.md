# TESTING

## Validation categories
- **Static checks:** formatting, linting, project-file validation, and similar repository-only checks.
- **Automated checks:** CLI commands that run outside Roblox Studio.
- **Manual Roblox Studio testing:** playtests, local server sessions, replication checks, UX checks, and exploit-resistance checks.

## Automated validation run for this task
- JSON syntax:

  ```sh
  python - <<'PY'
import json
from pathlib import Path

for path in sorted(Path(".").glob("*.json")):
    with path.open("r", encoding="utf-8") as handle:
        json.load(handle)
    print(f"validated JSON: {path}")
  PY
  ```

- TOML syntax:

  ```sh
  python - <<'PY'
import tomllib
from pathlib import Path

for path in (Path("aftman.toml"), Path("stylua.toml"), Path("selene.toml")):
    with path.open("rb") as handle:
        tomllib.load(handle)
    print(f"validated TOML: {path}")
  PY
  ```

- `stylua --check src`
- `selene src`
- `rojo build default.project.json --output /tmp/TheosRobloxGame.rbxlx`
### Interaction framework pure-logic tests
Run from a server Script or command bar:
```lua
local Tests = require(game.ReplicatedStorage.Shared.Tests.InteractionTests)
local passed, total = Tests.run()
print(passed .. "/" .. total .. " tests passed")
```
Expected: all 18 tests pass.

Repository automation can only validate repository-visible files and CLI checks. It does not replace Roblox Studio playtests, replication checks, or device/input verification.

## Manual Roblox Studio test checklists

### Solo play
- Start a one-player play session.
- Confirm server bootstrap logs once.
- Confirm client bootstrap logs once.
- Confirm `ReplicatedStorage.GameRuntime` exists.
- Confirm `GameTitle`, `MaxPlayers`, `CurrentRoomId`, `PlayerCount`, and `Phase` attributes populate.
- Stop and restart play to confirm no duplicate initialization warnings appear unless intentionally duplicated.

### Two-player local server
- Start a two-player local server session.
- Confirm each client runs the client bootstrap once.
- Confirm `PlayerCount` updates to 2.
- Confirm both clients observe the same `Phase` and room attributes.
- Confirm reconnecting a test player updates runtime state safely.

### Six-player local server
- Start a six-player local server session.
- Confirm runtime state remains stable as all six clients join.
- Confirm `PlayerCount` updates correctly during join and leave events.
- Confirm logs remain readable and no runaway loops appear.

### Interaction framework
- [ ] Instant interaction — successful completion and cooldown
- [ ] Hold interaction — successful completion
- [ ] Hold interaction — player cancels mid-hold
- [ ] Hold interaction — player moves away mid-hold
- [ ] Exclusive locking — two simultaneous begins
- [ ] Death during hold
- [ ] Disconnect during hold
- [ ] Replay/stale session rejection
- [ ] Remote spam / rate limiting
- [ ] Invalid remote arguments
- [ ] Room reset API
- [ ] State change propagation- Have multiple players attempt the same interaction at the same time.
- Verify only valid outcomes are accepted.
- Verify server state stays authoritative.
- Verify no duplicate rewards or state changes occur.

### Instant interaction
- Walk within range of `DemoButton` and press the ProximityPrompt.
- Confirm `ReplicatedStorage.DemoInteractionState.ButtonPressCount` increments by exactly 1.
- Press again immediately and confirm the 2-second cooldown prevents a second increment.
- After the cooldown expires, confirm a second press increments again.
- Confirm the prompt re-enables after cooldown.

### Hold interaction — successful completion
- Walk within range of `DemoLever` and hold the ProximityPrompt for the full 3-second duration.
- Confirm `ReplicatedStorage.DemoInteractionState.LeverState` toggles between `"on"` and `"off"`.
- Confirm the 5-second cooldown disables the prompt.
- Confirm the prompt re-enables after cooldown.

### Hold interaction — player cancels mid-hold
- Begin holding `DemoLever` and release before 3 seconds elapse.
- Confirm `LeverState` does not change.
- Confirm no cooldown is applied (the prompt re-enables immediately).
- Confirm the server does not retain an active session (server console should show cancel log).

### Hold interaction — player moves away mid-hold
- Begin holding `DemoLever` then walk beyond max distance before completion.
- Confirm the hold is cancelled server-side.
- Confirm `LeverState` does not change.

### Exclusive locking
- Have two players simultaneously begin holding `DemoLever` (start holds within the same second).
- Confirm only one player's hold is accepted; the other receives a prompt disable immediately.
- Confirm only one `LeverState` toggle occurs per round-trip.
- After the winning hold completes and the cooldown expires, confirm the second player can now interact.

### Death during hold interaction
- Begin holding a Hold-mode interactable.
- Kill the character (use `/kill [username]` in the server console) before the hold completes.
- Confirm the session is cancelled server-side.
- Confirm `LeverState` does not change.
- Confirm the exclusive lock is released (another player can begin after respawn).

### Disconnect during hold interaction
- Begin holding a Hold-mode interactable.
- Disconnect the client before the hold completes.
- Confirm the server cancels the session on `Players.PlayerRemoving`.
- Confirm the exclusive lock is released.
- Confirm remaining players are unaffected.

### Replay / stale session rejection
- Complete a Hold interaction and note the session ID in server logs.
- Attempt to send a `cancel` request with the old session ID via a custom LocalScript.
- Confirm the server returns `"already_resolved"` or `"session_not_found"` and does not mutate state.

### Remote spam
- Spam `InteractionRequest:InvokeServer("begin", "demo_hold_lever")` at maximum frequency from a LocalScript.
- Confirm the rate limiter returns `"rate_limited"` for excess requests.
- Confirm server performance is unaffected and no duplicate sessions are created.

### Invalid remote arguments
- Send `InteractionRequest:InvokeServer(nil, nil)`, wrong types (numbers, tables), and unknown operation strings.
- Confirm each returns `"invalid_args"` and no server error.
- Confirm no partial state mutation occurs.

### Room reset API
- Start a Hold interaction on `DemoLever`.
- From the server console, call `game.ServerScriptService.Server.Services.InteractionService.resetAll("test")`.
- Confirm the active session is cancelled, the exclusive lock is released, and cooldowns are cleared.
- Confirm the prompt re-enables without a Studio restart.

### State change propagation
- Walk toward a `demo_hold_lever` that is currently in cooldown state.
- Confirm the prompt appears disabled.
- Wait for cooldown to expire.
- Confirm the prompt re-enables without any additional client action.

### Character death
- Kill a player during play.
- Confirm the server does not retain invalid references to the dead character.
- Confirm any player-specific listeners are either rebound safely or cleaned up.

### Respawn
- Respawn a player after death.
- Confirm bootstrap systems do not duplicate.
- Confirm character-related listeners reconnect exactly once.
- Confirm the player can resume normal interaction flow.

### Player disconnection
- Disconnect a player during an active local server session.
- Confirm runtime state updates cleanly.
- Confirm no orphaned player state or errors remain.
- Confirm the remaining players can continue.

### Room reset
- Trigger a room reset once a room system exists.
- Confirm temporary instances, puzzle states, searchables, and entity state are restored.
- Confirm players are not left locked in invalid spots.

### Round reset
- Trigger a full round reset.
- Confirm player state, room state, progression, and temporary objects all reset.
- Confirm repeat reset cycles do not create duplicate connections or stale state.

### Missing instances
- Temporarily remove an expected folder or module in Studio.
- Confirm the relevant bootstrap path fails safely with a readable warning.
- Confirm the rest of the game does not enter an uncontrolled error loop.

### Duplicate event connections
- Start and stop play several times.
- Exercise respawn and reset flows.
- Confirm repeated actions produce one response, not multiple stacked responses.

### Invalid remote arguments
- Send `InteractionRequest:InvokeServer(nil, nil)`, wrong types (numbers, tables), and unknown operation strings.
- Confirm each returns `"invalid_args"` and no server error.
- Confirm no partial state mutation occurs.
- Once other remotes exist, also send malformed, extra, and out-of-range arguments to each.

### Remote spam
- Spam `InteractionRequest:InvokeServer("begin", "demo_hold_lever")` at maximum frequency from a LocalScript.
- Confirm the rate limiter returns `"rate_limited"` for excess requests.
- Confirm server performance is unaffected and no duplicate sessions are created.
- Once remotes exist for other systems, verify those are also rate-guarded.

### Attempts to fake inventory, keys, doors, rewards, or progression
- Once those systems exist, use the client console or exploit simulation tools to fake ownership or completion.
- Confirm the server rejects every unauthorized state change.
- Confirm no client-authored progression is accepted.

### Mobile
- Test on the mobile emulator or device.
- Confirm prompts are readable and touch targets are large enough.
- Confirm low-light visuals remain usable.

### Controller
- Test with a controller.
- Confirm focus movement, interaction prompts, and item use remain clear.
- Confirm no critical action depends on mouse-only input.

### Keyboard and mouse
- Test movement, camera, interaction flow, and item use.
- Confirm core actions are discoverable and responsive.

## Pull request test-results template

```md
## Test Results

### Static checks
- [ ] Formatting
- [ ] Linting
- [ ] Type checks
- [ ] Rojo project validation/build
- Notes:

### Automated checks
- [ ] Repository commands completed
- Notes:

### Manual Roblox Studio testing
- [ ] Solo play
- [ ] Two-player local server
- [ ] Six-player local server
- [ ] Interaction framework: instant completion and cooldown
- [ ] Interaction framework: hold completion
- [ ] Interaction framework: cancel mid-hold
- [ ] Interaction framework: move away mid-hold
- [ ] Interaction framework: exclusive locking
- [ ] Interaction framework: death during hold
- [ ] Interaction framework: disconnect during hold
- [ ] Interaction framework: replay/stale session rejection
- [ ] Interaction framework: remote spam / rate limiting
- [ ] Interaction framework: invalid remote arguments
- [ ] Interaction framework: room reset API
- [ ] Interaction framework: state change propagation
- [ ] Character death
- [ ] Respawn
- [ ] Player disconnection
- [ ] Room reset
- [ ] Round reset
- [ ] Missing instances
- [ ] Duplicate event connections
- [ ] Invalid remote arguments
- [ ] Remote spam
- [ ] Fake inventory / keys / doors / rewards / progression attempts
- [ ] Mobile
- [ ] Controller
- [ ] Keyboard and mouse
- Notes:

### Known limitations
- 
```
