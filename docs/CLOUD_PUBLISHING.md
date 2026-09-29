# Roblox cloud publishing

This repository can build the current Rojo source tree and publish it directly to a Roblox test place from GitHub Actions. A Mac and Roblox Studio are not required for this deployment loop.

## One-time Roblox setup

1. Create or choose a Roblox **test experience/place**. Do not point the dev workflow at a production place unless that is intentional.
2. Copy the experience's **Universe ID** from Creator Dashboard.
3. Copy the target **Place ID** from the place configuration URL.
4. Create a Roblox Open Cloud API key with:
   - API system: `universe-places`
   - Operation: `Write`
   - Resource: the selected test experience
5. In GitHub repository settings, add an Actions secret named:
   - `ROBLOX_OPEN_CLOUD_API_KEY`

Never commit the API key to this repository.

## Publish a dev build

1. Open **Actions** in GitHub.
2. Select **Publish Roblox dev build**.
3. Choose **Run workflow**.
4. Enter the test Universe ID and Place ID.
5. Enable the publish confirmation checkbox.
6. Run the workflow.

The workflow:

- checks out the current branch,
- installs the pinned Rojo tool through Aftman,
- builds `default.project.json` to `build/TheosRobloxGame.rbxlx`,
- stores that build as a short-lived GitHub artifact,
- publishes the XML place file to Roblox Open Cloud,
- records the returned Roblox place version in the workflow summary.

## Safety

Publishing is manual-only for now. A push to `main` does **not** publish to Roblox.

The workflow also requires an explicit confirmation checkbox and numeric Universe/Place IDs on each run. This keeps early testing separate from production deployment until the test target is proven stable.

## Source of truth

The Rojo `src/` tree is the source of truth. Do not publish the checked-in `TheosRobloxGame.rbxl` directly; that older Studio file does not contain all newer repository systems.
