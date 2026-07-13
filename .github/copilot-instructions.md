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
