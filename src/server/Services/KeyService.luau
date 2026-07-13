-- KeyService
-- Minimal server-authoritative key ownership for the first playable room.
-- Tracks only whether each player currently holds the room exit key.
-- A full inventory system (Milestone 5) will supersede this module; it is
-- intentionally narrow in scope so it can be replaced without breaking other
-- systems.
--
-- Public API
--   KeyService.awardKey(player)       Give the exit key; no-op if already held.
--   KeyService.hasKey(player)         Return true when the player holds the key.
--   KeyService.consumeKey(player)     Remove the key (e.g. after door unlocks).
--   KeyService.cleanPlayer(player)    Remove key record; called on disconnect.
--   KeyService.reset()                Clear all keys for a session/room reset.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

local service = {
	Name = "KeyService",
}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local initialized = false
local started = false
local serviceJanitor = nil

-- Server-only: player → true when they hold the key.
-- Never sent to clients directly; display-safe boolean is sent via remote.
local playerKeys: { [Player]: boolean } = {}

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function fireKeyState(player: Player)
	local remote = Remotes.get(Remotes.Names.KeyStateChanged)
	remote:FireClient(player, playerKeys[player] == true)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function service.awardKey(player: Player)
	if playerKeys[player] then
		return
	end
	playerKeys[player] = true
	fireKeyState(player)
end

function service.hasKey(player: Player): boolean
	return playerKeys[player] == true
end

function service.consumeKey(player: Player)
	if playerKeys[player] then
		playerKeys[player] = nil
		fireKeyState(player)
	end
end

-- Remove the key record for a player (implicit Lobby default = no key).
function service.cleanPlayer(player: Player)
	playerKeys[player] = nil
end

-- Clears all keys for a session or room reset.
function service.reset()
	for player in playerKeys do
		playerKeys[player] = nil
		pcall(fireKeyState, player)
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

	-- Auto-clean key records when a player disconnects.
	serviceJanitor:Add(Players.PlayerRemoving:Connect(function(player: Player)
		service.cleanPlayer(player)
	end))

	-- Ensure table is cleared when the service stops.
	serviceJanitor:Add(function()
		for player in playerKeys do
			playerKeys[player] = nil
		end
	end)

	started = true
	context.Logger.info("%s started", service.Name)
end

function service.Stop(context)
	if serviceJanitor ~= nil then
		serviceJanitor:Cleanup()
		serviceJanitor = nil
	end

	-- Explicit clear in case the janitor lambda above ran after other cleanup.
	for player in playerKeys do
		playerKeys[player] = nil
	end

	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
