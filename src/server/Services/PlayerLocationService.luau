-- PlayerLocationService
-- Single source of truth for server-authoritative player session/location state.
-- Owns the mapping from Player → one of three named locations:
--
--   Lobby     – player is in the lobby (default for new/unassigned players)
--   Launching – player's party has triggered launch but movement is not yet
--               complete; no respawn override should fire during this window
--   InGame    – player's party completed launch and is now in the game world
--
-- Other services update location state by calling the public setters here;
-- they never hold a copy of the raw table.
--
-- LobbyService reads location via getLocation() to decide where to send a
-- respawning character.  PartyService updates location as the party state
-- machine advances.
--
-- Cleanup guarantees:
--   – PlayerRemoving: record removed automatically.
--   – Service Stop:   all records cleared, PlayerRemoving listener disconnected.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

local service = {
	Name = "PlayerLocationService",
}

-- ---------------------------------------------------------------------------
-- Public constants
-- ---------------------------------------------------------------------------

service.LocationState = table.freeze({
	Lobby = "Lobby",
	Launching = "Launching",
	InGame = "InGame",
})

-- ---------------------------------------------------------------------------
-- Module state (reset on Stop)
-- ---------------------------------------------------------------------------

local initialized = false
local started = false
local serviceJanitor = nil

-- Server-only table: never replicated to clients.
local playerLocations: { [Player]: string } = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns the current location of the player.
-- Defaults to "Lobby" for players who have no entry (new joins, etc.).
function service.getLocation(player: Player): string
	return playerLocations[player] or service.LocationState.Lobby
end

-- Sets the authoritative location for the player.
-- location must be one of service.LocationState values.
function service.setLocation(player: Player, location: string)
	playerLocations[player] = location
end

-- Removes the location record for the player (resets to implicit Lobby default).
function service.cleanPlayer(player: Player)
	playerLocations[player] = nil
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

	-- Auto-clean records when a player disconnects so the table never retains
	-- stale Player references.
	serviceJanitor:Add(Players.PlayerRemoving:Connect(function(player: Player)
		service.cleanPlayer(player)
	end))

	-- Guard against players who were already present when Start runs.
	serviceJanitor:Add(function()
		for player in playerLocations do
			playerLocations[player] = nil
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

	-- Explicit clear in case janitor cleanup ran before our lambda registered.
	for player in playerLocations do
		playerLocations[player] = nil
	end

	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
