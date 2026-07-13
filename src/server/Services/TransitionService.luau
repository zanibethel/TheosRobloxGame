-- TransitionService
-- Interface for moving a party from the lobby into a game session.
--
-- Current behaviour (PartyConfig.FutureTeleportEnabled = false):
--   Pivots every party member's character to the configured test-room spawn
--   point inside the same server.  No TeleportService call is made.
--   Destination resolves in this order:
--     1. workspace[TestRoom.SpawnFolderName][TestRoom.SpawnPartName]
--     2. TestRoom.FallbackSpawnPosition from PartyConfig
--
-- Future behaviour (PartyConfig.FutureTeleportEnabled = true):
--   Replace the character-move body of LaunchParty with
--   TeleportService.TeleportAsync.  The function signature must remain identical
--   so PartyService needs no changes when the teleport path is activated.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PartyConfig = require(ReplicatedStorage.Shared.Config.PartyConfig)

local service = {
	Name = "TransitionService",
}

local initialized = false
local started = false
local serviceLogger = nil

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function getTestRoomSpawnCFrame(): CFrame
	local roomFolder = Workspace:FindFirstChild(PartyConfig.TestRoom.SpawnFolderName)
	if roomFolder ~= nil then
		local spawnPart = roomFolder:FindFirstChild(PartyConfig.TestRoom.SpawnPartName)
		if spawnPart ~= nil and spawnPart:IsA("BasePart") then
			return (spawnPart :: BasePart).CFrame + Vector3.new(0, 3, 0)
		end
	end
	return CFrame.new(PartyConfig.TestRoom.FallbackSpawnPosition)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Moves all players in the party to the test room.
-- The `party` argument must expose a `players` array and a `partyId` string.
-- When PartyConfig.FutureTeleportEnabled is true, replace the character-move
-- block below with TeleportService.TeleportAsync without touching the signature.
function service.LaunchParty(party: { players: { Player }, partyId: string })
	if PartyConfig.FutureTeleportEnabled then
		-- Reserved: TeleportService integration goes here.
		if serviceLogger ~= nil then
			serviceLogger.warn(
				"%s: FutureTeleportEnabled is true but TeleportService is not yet implemented; skipping launch",
				service.Name
			)
		end
		return
	end

	local origin = getTestRoomSpawnCFrame()
	for index, player in party.players do
		local character = player.Character
		if character ~= nil then
			-- Spread players out so they do not overlap on arrival.
			local offset = Vector3.new((index - 1) * 3, 0, 0)
			character:PivotTo(origin + offset)
		end
	end

	if serviceLogger ~= nil then
		serviceLogger.info(
			"%s: launched party %s (%d players) to test room",
			service.Name,
			tostring(party.partyId),
			#party.players
		)
	end
end

-- ---------------------------------------------------------------------------
-- Service lifecycle
-- ---------------------------------------------------------------------------

function service.Init(context)
	if initialized then
		context.Logger.warn("%s already initialized", service.Name)
		return
	end

	initialized = true
	serviceLogger = context.Logger
end

function service.Start(context)
	if started then
		context.Logger.warn("%s already started", service.Name)
		return
	end

	started = true
	context.Logger.info("%s started", service.Name)
end

function service.Stop(context)
	serviceLogger = nil
	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
