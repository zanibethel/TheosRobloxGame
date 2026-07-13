-- LobbyService
-- Positions players at the correct spawn point each time their character loads.
--
-- Spawn destination is determined by PlayerLocationService:
--
--   Lobby     → workspace[Lobby.SpawnFolderName][Lobby.SpawnPartName]
--               (or FallbackSpawnPosition if the part is absent)
--   InGame    → workspace[TestRoom.SpawnFolderName][TestRoom.SpawnPartName]
--               (or TestRoom.FallbackSpawnPosition if absent)
--   Launching → character movement skipped; TransitionService will position
--               the player when the launch completes
--
-- PlayerLocationService is the authoritative source for location state.
-- LobbyService never writes that state; it only reads it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PartyConfig = require(ReplicatedStorage.Shared.Config.PartyConfig)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)
local PlayerLocationService = require(script.Parent.PlayerLocationService)

local service = {
	Name = "LobbyService",
}

local initialized = false
local started = false
local serviceJanitor = nil

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function getLobbySpawnCFrame(): CFrame
	local lobbyFolder = Workspace:FindFirstChild(PartyConfig.Lobby.SpawnFolderName)
	if lobbyFolder ~= nil then
		local spawnPart = lobbyFolder:FindFirstChild(PartyConfig.Lobby.SpawnPartName)
		if spawnPart ~= nil and spawnPart:IsA("BasePart") then
			-- Offset slightly above the surface to avoid floor-clipping on spawn.
			return (spawnPart :: BasePart).CFrame + Vector3.new(0, 3, 0)
		end
	end
	return CFrame.new(PartyConfig.Lobby.FallbackSpawnPosition)
end

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

local function moveCharacterTo(player: Player, target: CFrame)
	local character = player.Character
	if character == nil then
		return
	end
	if character:FindFirstChild("HumanoidRootPart") == nil then
		return
	end
	character:PivotTo(target)
end

local function handleRespawn(player: Player)
	local location = PlayerLocationService.getLocation(player)

	if location == PlayerLocationService.LocationState.InGame then
		-- Respawn the character at the test-room spawn so players who die
		-- in-game are returned to the game world, not the lobby.
		moveCharacterTo(player, getTestRoomSpawnCFrame())
	elseif location == PlayerLocationService.LocationState.Launching then
		-- The party is mid-launch; TransitionService will position the player
		-- when the launch completes.  Do not interfere.
		return
	else
		-- Default: Lobby (also covers new/unassigned players).
		moveCharacterTo(player, getLobbySpawnCFrame())
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
	serviceJanitor = Janitor.new()
	context.Janitor:Add(serviceJanitor)
end

function service.Start(context)
	if started then
		context.Logger.warn("%s already started", service.Name)
		return
	end

	if serviceJanitor == nil then
		error(string.format("%s cannot start: janitor is missing", service.Name))
	end

	-- Per-player janitors track CharacterAdded connections; they are cleaned
	-- up when the player leaves, preventing stale listeners.
	local playerJanitors: { [Player]: any } = {}

	local function teardownPlayer(player: Player)
		local pj = playerJanitors[player]
		if pj ~= nil then
			pj:Cleanup()
			playerJanitors[player] = nil
		end
	end

	local function setupPlayer(player: Player)
		if playerJanitors[player] ~= nil then
			return
		end

		local pj = Janitor.new()
		playerJanitors[player] = pj
		serviceJanitor:Add(pj)

		pj:Add(player.CharacterAdded:Connect(function(_character: Model)
			-- Defer so the character hierarchy has fully loaded before pivoting.
			task.defer(handleRespawn, player)
		end))

		-- Handle players who already have a character when Start runs.
		if player.Character ~= nil then
			task.defer(handleRespawn, player)
		end
	end

	serviceJanitor:Add(Players.PlayerAdded:Connect(setupPlayer))
	serviceJanitor:Add(Players.PlayerRemoving:Connect(teardownPlayer))
	serviceJanitor:Add(function()
		for player in playerJanitors do
			teardownPlayer(player)
		end
	end)

	for _, player in Players:GetPlayers() do
		setupPlayer(player)
	end

	started = true
	context.Logger.info("%s started", service.Name)
end

function service.Stop(context)
	if serviceJanitor ~= nil then
		serviceJanitor:Cleanup()
		serviceJanitor = nil
	end

	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
