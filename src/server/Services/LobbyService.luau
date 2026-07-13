-- LobbyService
-- Positions players at the lobby spawn point each time their character loads.
--
-- Spawn location resolution (in priority order):
--   1. workspace[PartyConfig.Lobby.SpawnFolderName][PartyConfig.Lobby.SpawnPartName]
--   2. PartyConfig.Lobby.FallbackSpawnPosition
--
-- This service intentionally does not know about party state.
-- Future milestones may add logic to skip the lobby teleport when a player is
-- already InGame; that decision belongs in a higher-level session coordinator.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PartyConfig = require(ReplicatedStorage.Shared.Config.PartyConfig)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

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

local function moveToLobby(player: Player)
	local character = player.Character
	if character == nil then
		return
	end
	if character:FindFirstChild("HumanoidRootPart") == nil then
		return
	end
	character:PivotTo(getLobbySpawnCFrame())
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
			task.defer(moveToLobby, player)
		end))

		-- Handle players who already have a character when Start runs.
		if player.Character ~= nil then
			task.defer(moveToLobby, player)
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
