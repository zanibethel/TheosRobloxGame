# Roblox cloud publishing

This repository can build the current Rojo source tree and publish it directly to the Theo Roblox test place from GitHub Actions. A Mac and Roblox Studio are not required for this deployment loop.

## Pinned dev target

- Universe ID: `10436050860`
- Start Place ID: `83099751525380`

The manual dev-publish workflow is intentionally pinned to this target so a tester does not need to enter IDs on every run.

## One-time Roblox setup

Create a Roblox Open Cloud API key with:

- API system: `universe-places`
- Operation: `Write`
- Resource: Universe `10436050860`

Then, in GitHub repository settings, add an Actions secret named:

- `ROBLOX_OPEN_CLOUD_API_KEY`

Never commit the API key to this repository or paste it into chat.

## Publish a dev build

1. Open **Actions** in GitHub.
2. Select **Publish Roblox dev build**.
3. Choose **Run workflow**.
4. Enable the publish confirmation checkbox.
5. Run the workflow.

The workflow:

- checks out the current source,
- installs the pinned Rojo tool through Aftman,
- verifies the pinned Universe and Place IDs,
- builds `default.project.json` to `build/TheosRobloxGame.rbxlx`,
- stores the generated build as a short-lived GitHub artifact,
- publishes the XML place file to Roblox Open Cloud,
- records the returned Roblox place version in the workflow summary.

## Safety

Publishing is manual-only. A push to `main` does **not** publish to Roblox.

The workflow is pinned to the Theo test target and also requires an explicit confirmation checkbox. Production publishing should use a separate workflow/target when needed.

## Source of truth

The Rojo `src/` tree is the source of truth. Do not publish the checked-in `TheosRobloxGame.rbxl` directly; that older Studio file does not contain all newer repository systems.
