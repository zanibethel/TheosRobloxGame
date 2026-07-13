# Copilot Instructions

## Required reading order
1. Read `/GAME_BIBLE.md`.
2. Read `/ROADMAP.md`.
3. Read `/PROJECT_STATUS.md`.
4. Read `/TESTING.md`.
5. Inspect the existing code in `/src` and configuration files before changing anything.

## Working rules
- Keep trusted gameplay logic on the server.
- Validate every `RemoteEvent` and `RemoteFunction` argument on the server.
- Never trust client-provided inventory, rewards, keys, puzzle completion, damage, door access, or progression.
- Use modular Roblox Luau.
- Use type annotations where practical.
- Keep configuration separate from logic.
- Design systems to support additional rooms, entities, items, and puzzles.
- Support up to six players.
- Handle respawns, deaths, disconnections, room resets, and round resets.
- Clean up connections, tasks, temporary instances, and player state.
- Prevent duplicate initialization.
- Avoid uncontrolled loops and deprecated `wait`.
- Avoid paid assets, secrets, external services, and unrelated refactors.
- Work through focused branches and reviewable pull requests.
- Clearly distinguish static checks, automated checks, and manual Roblox Studio testing.
- Continue independently for low-risk reversible decisions.
- Stop only for destructive, architectural, credential, publishing, or financial decisions.

## Implementation guidance
- Prefer small services/controllers/modules over monolithic scripts.
- Keep room data, item tuning, puzzle parameters, entity tuning, and UI text configurable.
- Fail safely when required instances or modules are missing.
- Treat any networking layer as hostile input until validated on the server.
- Preserve clear client/server boundaries.
- Avoid adding new tooling or dependencies unless directly useful to the Roblox workflow.

## Validation expectations
- Static checks: formatting, linting, type checks, and project validation that can run from the repository.
- Automated checks: repository commands and CLI validations that do not require Roblox Studio.
- Manual Studio testing: local server playtests, device input checks, lighting/audio/jumpscare review, and replication verification.
- Do not claim Studio-only behavior is verified unless it was explicitly tested in Roblox Studio.

## Post-Commit Review

After each meaningful commit or milestone, review only the changed files and their direct consumers. Do not reread unrelated files or narrate every tool call.

**Check each of the following for changed code:**
1. Client/server authority — no trusted logic on the client; no server accepting untrusted client values.
2. Remote validation — every RemoteEvent and RemoteFunction argument validated on the server before use.
3. Cleanup and lifecycle — connections, tasks, and player state are cleaned up on reset, disconnect, and death.
4. Duplicate initialization — guards prevent a module or service from initializing more than once per session.
5. Multiplayer race conditions — concurrent requests are handled safely; exclusive locks are released on failure paths.
6. Reset behavior — room reset and round reset paths are covered and leave no stale state.
7. Configuration and hard-coded values — tuning values belong in config modules, not inline in logic.
8. Documentation accuracy — comments, status docs, and PR descriptions match actual behavior.

**Validation scope:**
- During development: run the narrowest relevant check (e.g. `stylua --check` on changed files, `selene` on changed files).
- Before finalizing the PR: run the full repository validation suite (JSON, TOML, StyLua, Selene, Rojo build).

**Findings outside the current scope:**
- Record unrelated bugs or improvements as follow-up items in the PR description or a tracking note.
- Do not expand the current branch to fix unrelated issues.

**Commit summary:**
Each meaningful commit or PR must summarize:
- What changed and why.
- Known risks or edge cases.
- Validation performed (which checks ran and whether they passed).
- Studio tests still required before the milestone is complete.
- Next recommended task.

## Definition of done
A task is done only when:
- Relevant docs were reviewed first.
- Existing code and config were inspected before editing.
- Changes stay within the requested scope.
- Server-authoritative boundaries remain intact.
- Initialization is idempotent and cleanup paths are covered.
- Config is separated from logic.
- Static and automated repository checks were run when available.
- Manual Roblox Studio test steps are documented for anything not verifiable in the repository.
- Risks, assumptions, and known limitations are recorded in the PR or status docs.
