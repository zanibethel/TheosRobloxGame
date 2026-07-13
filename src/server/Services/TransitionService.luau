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

-- Tracks which party currently occupies the test room.
-- nil when the room is free; set to the partyId during LaunchParty and
-- cleared by releaseRoom.  Only one party may occupy the room at a time.
local activeRoomPartyId: string? = nil

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
-- Returns (success: boolean, resultCode: string?) so PartyService can react
-- to launch failures without relying on pcall error semantics.
--
-- The `party` argument must expose a `players` array and a `partyId` string.
-- When PartyConfig.FutureTeleportEnabled is true, replace the character-move
-- block below with TeleportService.TeleportAsync without touching the signature.
--
-- One active test-room party is enforced at a time.  A second party attempting
-- to launch while the room is occupied receives the "room_in_use" result code.
-- Call releaseRoom(partyId) when the party is done to free the room.
function service.LaunchParty(party: { players: { Player }, partyId: string }): (boolean, string?)
	if PartyConfig.FutureTeleportEnabled then
		-- TeleportService integration is not yet implemented.
		-- Return an explicit failure so PartyService can recover gracefully
		-- instead of silently leaving the party stuck in Launching state.
		if serviceLogger ~= nil then
			serviceLogger.warn(
				"%s: FutureTeleportEnabled is true but TeleportService is not yet implemented; aborting launch",
				service.Name
			)
		end
		return false, "not_implemented"
	end

	-- Enforce single-room occupancy: reject a second party while one is active.
	if activeRoomPartyId ~= nil then
		if serviceLogger ~= nil then
			serviceLogger.warn(
				"%s: room is occupied by party %s; rejecting launch for party %s",
				service.Name,
				tostring(activeRoomPartyId),
				tostring(party.partyId)
			)
		end
		return false, "room_in_use"
	end

	-- Reset room state so the new party starts with a clean drawer, door, keys,
	-- and RoomState attribute.  Lazy-require to avoid circular dependency issues
	-- at module-load time and to keep TransitionService startup order-agnostic.
	local RoomService = require(script.Parent.RoomService)
	local KeyService = require(script.Parent.KeyService)
	RoomService.reset(KeyService)

	-- Mark the room as occupied before pivoting characters so that a concurrent
	-- launch attempt (highly unlikely but possible) is rejected immediately.
	activeRoomPartyId = party.partyId

	local origin = getTestRoomSpawnCFrame()
	for index, player in ipairs(party.players) do
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
	return true, nil
end

-- Releases the test-room occupancy lock held by `partyId`.
-- No-op when called with a partyId that does not match the current occupant.
-- Call this from PartyService when the active party is destroyed or completes.
function service.releaseRoom(partyId: string)
	if activeRoomPartyId == partyId then
		activeRoomPartyId = nil
		if serviceLogger ~= nil then
			serviceLogger.info("%s: room released by party %s", service.Name, partyId)
		end
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
	activeRoomPartyId = nil
	serviceLogger = nil
	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
