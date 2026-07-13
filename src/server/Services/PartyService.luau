-- PartyService
-- Server-authoritative management of lobby parties.
-- All party state lives exclusively on the server; clients receive read-only
-- snapshots via RemoteEvents.  Clients can never set party data directly.
--
-- Party lifecycle
--   create → Waiting
--   players join → Waiting
--   players toggle ready → Waiting
--   host starts → Countdown → Launching → InGame
--   member leaves / unreadies during Countdown → cancelled back to Waiting
--   party empties → Closed (destroyed)
--   host leaves → host transferred to next member (or party destroyed if alone)
--
-- Player location state
--   PartyService updates PlayerLocationService as the party state machine
--   advances.  LobbyService reads this state on every respawn to decide where
--   to position the character.
--     Waiting / Countdown → no change (players remain Lobby)
--     Launching           → all members set to Launching
--     InGame              → all members set to InGame
--     leave / kick        → affected player reset to Lobby
--     party destroyed     → all former members reset to Lobby
--
-- Remote protocol
--   PartyRequest (RemoteFunction)
--     Client → Server: InvokeServer(operation, arg1?)
--       operation : PartyOperation string
--       arg1      : string  for "join"    (partyId)
--                   number  for "kick"    (target userId)
--                   number  for "setSize" (new max players)
--                   nil     for all other operations
--     Server → Client: returns (success: boolean, code: string, data: any?)
--       data is partyId string only on a successful "create" response
--
--   PartyStateChanged (RemoteEvent)
--     Server → specific client: FireClient(player, partyInfo | nil)
--       nil   → player is no longer in any party
--       table → PartyInfo read-only snapshot of their current party
--
--   PartyListChanged (RemoteEvent)
--     Server → all clients: FireAllClients(list)
--       list → array of PartyListEntry for all currently Waiting parties

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PartyConfig = require(ReplicatedStorage.Shared.Config.PartyConfig)
local PartyState = require(ReplicatedStorage.Shared.Enums.PartyState)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)
local TransitionService = require(script.Parent.TransitionService)
local PlayerLocationService = require(script.Parent.PlayerLocationService)

local service = {
	Name = "PartyService",
}

-- ---------------------------------------------------------------------------
-- Internal types (server-only; never sent to clients)
-- ---------------------------------------------------------------------------

type PartyData = {
	partyId: string,
	host: Player,
	maxPlayers: number,
	players: { Player },
	readySet: { [Player]: boolean },
	state: string,
	countdownThread: thread?,
	countdownRemaining: number?,
	createdTime: number,
}

-- ---------------------------------------------------------------------------
-- Module state (reset on Stop)
-- ---------------------------------------------------------------------------

local initialized = false
local started = false
local serviceJanitor = nil
local serviceLogger = nil

-- Master party table indexed by partyId.
local parties: { [string]: PartyData } = {}
-- Reverse-lookup so we can find a player's party in O(1).
local playerToPartyId: { [Player]: string } = {}

-- Rate-limiting state: per-player timestamps using os.clock() for sub-second
-- precision.  Both tables are cleared on player disconnect and on service Stop.
local globalLastRequest: { [Player]: number } = {}
local operationLastRequest: { [Player]: { [string]: number } } = {}

-- Remote handles cached after Start.
local partyRequestRemote = nil
local partyStateChangedRemote = nil
local partyListChangedRemote = nil

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function logInfo(msg: string, ...)
	if serviceLogger ~= nil then
		serviceLogger.info(msg, ...)
	end
end

local function logWarn(msg: string, ...)
	if serviceLogger ~= nil then
		serviceLogger.warn(msg, ...)
	else
		warn(string.format("[TheosRobloxGame] " .. msg, ...))
	end
end

local function generatePartyId(): string
	local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	local id = ""
	for _ = 1, PartyConfig.Party.PartyIdLength do
		local index = math.random(1, #chars)
		id = id .. string.sub(chars, index, index)
	end
	return id
end

local function buildPlayerInfoList(party: PartyData): { { [string]: any } }
	local list = {}
	for _, player in party.players do
		table.insert(list, {
			name = player.Name,
			displayName = player.DisplayName,
			userId = player.UserId,
			isReady = party.readySet[player] == true,
			isHost = player == party.host,
		})
	end
	return list
end

local function buildPartyInfo(party: PartyData): { [string]: any }
	return {
		partyId = party.partyId,
		hostName = party.host.Name,
		maxPlayers = party.maxPlayers,
		playerCount = #party.players,
		players = buildPlayerInfoList(party),
		state = party.state,
		countdownRemaining = party.countdownRemaining,
	}
end

local function broadcastPartyState(party: PartyData)
	if partyStateChangedRemote == nil then
		return
	end
	local info = buildPartyInfo(party)
	for _, player in party.players do
		partyStateChangedRemote:FireClient(player, info)
	end
end

local function broadcastNoParty(player: Player)
	if partyStateChangedRemote == nil then
		return
	end
	partyStateChangedRemote:FireClient(player, nil)
end

local function broadcastPartyList()
	if partyListChangedRemote == nil then
		return
	end
	local list = {}
	for _, party in parties do
		if party.state == PartyState.Waiting then
			table.insert(list, {
				partyId = party.partyId,
				hostName = party.host.Name,
				playerCount = #party.players,
				maxPlayers = party.maxPlayers,
			})
		end
	end
	partyListChangedRemote:FireAllClients(list)
end

-- Cancels a running countdown, restoring the party to Waiting state.
-- Safe to call when no countdown is active (no-op).
local function cancelCountdown(party: PartyData)
	if party.countdownThread ~= nil then
		task.cancel(party.countdownThread)
		party.countdownThread = nil
	end

	if party.state == PartyState.Countdown then
		party.state = PartyState.Waiting
		party.countdownRemaining = nil
		logInfo("%s: countdown cancelled for party %s", service.Name, party.partyId)
		broadcastPartyState(party)
		broadcastPartyList()
	end
end

-- Tears down a party completely, notifying all former members.
-- Party must not be used after this call.
local function destroyParty(party: PartyData)
	local partyId = party.partyId

	if party.countdownThread ~= nil then
		task.cancel(party.countdownThread)
		party.countdownThread = nil
	end

	party.state = PartyState.Closed

	for _, player in party.players do
		playerToPartyId[player] = nil
		PlayerLocationService.setLocation(player, PlayerLocationService.LocationState.Lobby)
		broadcastNoParty(player)
	end

	parties[partyId] = nil
	logInfo("%s: party %s destroyed", service.Name, partyId)
	broadcastPartyList()
end

-- Removes a single player from their current party, handling host transfer,
-- countdown cancellation, and party destruction when the last member leaves.
local function removePlayerFromParty(player: Player)
	local partyId = playerToPartyId[player]
	if partyId == nil then
		return
	end

	local party = parties[partyId]
	if party == nil then
		playerToPartyId[player] = nil
		return
	end

	if party.state == PartyState.Countdown then
		cancelCountdown(party)
	end

	party.readySet[player] = nil

	local remaining = {}
	for _, p in party.players do
		if p ~= player then
			table.insert(remaining, p)
		end
	end
	party.players = remaining
	playerToPartyId[player] = nil
	-- Reset the leaving player's location to Lobby regardless of their prior
	-- location.  If they were InGame, their next respawn will go to the lobby.
	PlayerLocationService.setLocation(player, PlayerLocationService.LocationState.Lobby)
	broadcastNoParty(player)

	if #remaining == 0 then
		destroyParty(party)
		return
	end

	if party.host == player then
		party.host = remaining[1]
		logInfo("%s: host transferred to %s in party %s", service.Name, party.host.Name, partyId)
	end

	broadcastPartyState(party)
	broadcastPartyList()
end

-- ---------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------

-- Returns true if the request is allowed, false if it must be rejected.
-- Does NOT record the timestamp; call recordRequest separately on acceptance.
local function checkRateLimit(player: Player, operation: string, now: number): boolean
	-- Global minimum interval between any two requests from this player.
	local gLast = globalLastRequest[player]
	if gLast ~= nil and (now - gLast) < PartyConfig.RateLimiting.GlobalMinInterval then
		return false
	end

	-- Per-operation interval (if configured).
	local opInterval = PartyConfig.RateLimiting.OperationIntervals[operation]
	if opInterval ~= nil then
		local opMap = operationLastRequest[player]
		if opMap ~= nil then
			local opLast = opMap[operation]
			if opLast ~= nil and (now - opLast) < opInterval then
				return false
			end
		end
	end

	return true
end

-- Records a timestamp for an accepted request so future calls can be measured
-- against it.
local function recordRequest(player: Player, operation: string, now: number)
	globalLastRequest[player] = now

	if operationLastRequest[player] == nil then
		operationLastRequest[player] = {}
	end
	operationLastRequest[player][operation] = now
end

-- Removes all rate-limit records for a player (called on disconnect and Stop).
local function cleanRateLimitRecords(player: Player)
	globalLastRequest[player] = nil
	operationLastRequest[player] = nil
end

-- ---------------------------------------------------------------------------
-- Operation handlers — each returns (success, code, data?)
-- ---------------------------------------------------------------------------

local function handleCreate(player: Player): (boolean, string, any)
	if playerToPartyId[player] ~= nil then
		return false, "already_in_party", nil
	end

	local partyId = generatePartyId()
	local attempts = 0
	while parties[partyId] ~= nil and attempts < 10 do
		partyId = generatePartyId()
		attempts += 1
	end
	if parties[partyId] ~= nil then
		return false, "internal_error", nil
	end

	local party: PartyData = {
		partyId = partyId,
		host = player,
		maxPlayers = PartyConfig.Party.DefaultMaxPlayers,
		players = { player },
		readySet = {},
		state = PartyState.Waiting,
		countdownThread = nil,
		countdownRemaining = nil,
		createdTime = os.time(),
	}

	parties[partyId] = party
	playerToPartyId[player] = partyId

	logInfo("%s: %s created party %s", service.Name, player.Name, partyId)
	broadcastPartyState(party)
	broadcastPartyList()

	return true, "ok", partyId
end

local function handleJoin(player: Player, partyId: any): (boolean, string, any)
	if type(partyId) ~= "string" or partyId == "" then
		return false, "invalid_args", nil
	end
	if playerToPartyId[player] ~= nil then
		return false, "already_in_party", nil
	end

	local party = parties[partyId]
	if party == nil then
		return false, "party_not_found", nil
	end
	if party.state ~= PartyState.Waiting then
		return false, "party_locked", nil
	end
	if #party.players >= party.maxPlayers then
		return false, "party_full", nil
	end

	table.insert(party.players, player)
	playerToPartyId[player] = partyId

	logInfo("%s: %s joined party %s", service.Name, player.Name, partyId)
	broadcastPartyState(party)
	broadcastPartyList()

	return true, "ok", nil
end

local function handleLeave(player: Player): (boolean, string, any)
	if playerToPartyId[player] == nil then
		return false, "no_party", nil
	end
	removePlayerFromParty(player)
	return true, "ok", nil
end

local function handleReady(player: Player): (boolean, string, any)
	local partyId = playerToPartyId[player]
	if partyId == nil then
		return false, "no_party", nil
	end
	local party = parties[partyId]
	if party == nil then
		playerToPartyId[player] = nil
		return false, "party_not_found", nil
	end
	if party.state ~= PartyState.Waiting then
		return false, "wrong_state", nil
	end

	party.readySet[player] = true
	logInfo("%s: %s is ready in party %s", service.Name, player.Name, partyId)
	broadcastPartyState(party)
	return true, "ok", nil
end

local function handleUnready(player: Player): (boolean, string, any)
	local partyId = playerToPartyId[player]
	if partyId == nil then
		return false, "no_party", nil
	end
	local party = parties[partyId]
	if party == nil then
		playerToPartyId[player] = nil
		return false, "party_not_found", nil
	end

	-- Unreadying during countdown cancels it.
	if party.state == PartyState.Countdown then
		cancelCountdown(party)
	end

	if party.state ~= PartyState.Waiting then
		return false, "wrong_state", nil
	end

	party.readySet[player] = nil
	logInfo("%s: %s unreadied in party %s", service.Name, player.Name, partyId)
	broadcastPartyState(party)
	return true, "ok", nil
end

local function handleStart(player: Player): (boolean, string, any)
	local partyId = playerToPartyId[player]
	if partyId == nil then
		return false, "no_party", nil
	end
	local party = parties[partyId]
	if party == nil then
		playerToPartyId[player] = nil
		return false, "party_not_found", nil
	end
	if party.host ~= player then
		return false, "not_host", nil
	end
	if party.state ~= PartyState.Waiting then
		return false, "wrong_state", nil
	end
	if #party.players < PartyConfig.Party.MinPlayers then
		return false, "not_enough_players", nil
	end
	for _, p in party.players do
		if not party.readySet[p] then
			return false, "not_all_ready", nil
		end
	end

	party.state = PartyState.Countdown
	party.countdownRemaining = PartyConfig.Party.CountdownSeconds
	broadcastPartyState(party)
	broadcastPartyList()

	local capturedId = partyId
	party.countdownThread = task.spawn(function()
		for second = 1, PartyConfig.Party.CountdownSeconds do
			task.wait(1)

			local p = parties[capturedId]
			if p == nil or p.state ~= PartyState.Countdown then
				return
			end

			if second < PartyConfig.Party.CountdownSeconds then
				p.countdownRemaining = PartyConfig.Party.CountdownSeconds - second
				broadcastPartyState(p)
			else
				-- Final tick: transition to Launching and update location state
				-- for all members before calling TransitionService.
				p.state = PartyState.Launching
				p.countdownThread = nil
				p.countdownRemaining = nil
				logInfo("%s: launching party %s", service.Name, capturedId)

				for _, member in ipairs(p.players) do
					PlayerLocationService.setLocation(member, PlayerLocationService.LocationState.Launching)
				end
				broadcastPartyState(p)

				-- TransitionService returns (success: boolean, resultCode: string?)
				local callOk, launchSuccess, launchCode = pcall(TransitionService.LaunchParty, p)

				-- Normalise pcall errors into the same result shape.
				if not callOk then
					logWarn("%s: LaunchParty threw for party %s: %s", service.Name, capturedId, tostring(launchSuccess))
					launchSuccess = false
					launchCode = "internal_error"
				end

				local current = parties[capturedId]

				if not launchSuccess then
					logWarn(
						"%s: LaunchParty failed for party %s (code: %s); recovering to Waiting",
						service.Name,
						capturedId,
						tostring(launchCode)
					)
					if current ~= nil then
						current.state = PartyState.Waiting
						current.countdownThread = nil
						current.countdownRemaining = nil
						-- Reset all members to Lobby so their next respawn is safe.
						for _, member in ipairs(current.players) do
							PlayerLocationService.setLocation(member, PlayerLocationService.LocationState.Lobby)
						end
						broadcastPartyState(current)
						broadcastPartyList()
					end
					return
				end

				-- Successful launch: enter InGame.
				if current ~= nil then
					current.state = PartyState.InGame
					for _, member in ipairs(current.players) do
						PlayerLocationService.setLocation(member, PlayerLocationService.LocationState.InGame)
					end
					broadcastPartyState(current)
				end
			end
		end
	end)

	logInfo("%s: %s started countdown for party %s", service.Name, player.Name, partyId)
	return true, "ok", nil
end

local function handleCancel(player: Player): (boolean, string, any)
	local partyId = playerToPartyId[player]
	if partyId == nil then
		return false, "no_party", nil
	end
	local party = parties[partyId]
	if party == nil then
		playerToPartyId[player] = nil
		return false, "party_not_found", nil
	end
	if party.host ~= player then
		return false, "not_host", nil
	end
	if party.state ~= PartyState.Countdown then
		return false, "wrong_state", nil
	end

	cancelCountdown(party)
	return true, "ok", nil
end

local function handleKick(player: Player, targetUserId: any): (boolean, string, any)
	if type(targetUserId) ~= "number" then
		return false, "invalid_args", nil
	end

	local partyId = playerToPartyId[player]
	if partyId == nil then
		return false, "no_party", nil
	end
	local party = parties[partyId]
	if party == nil then
		playerToPartyId[player] = nil
		return false, "party_not_found", nil
	end
	if party.host ~= player then
		return false, "not_host", nil
	end
	if player.UserId == targetUserId then
		return false, "invalid_args", nil
	end

	local targetPlayer: Player? = nil
	for _, p in party.players do
		if p.UserId == targetUserId then
			targetPlayer = p
			break
		end
	end
	if targetPlayer == nil then
		return false, "player_not_found", nil
	end

	if party.state == PartyState.Countdown then
		cancelCountdown(party)
	end

	party.readySet[targetPlayer] = nil
	local remaining = {}
	for _, p in party.players do
		if p ~= targetPlayer then
			table.insert(remaining, p)
		end
	end
	party.players = remaining
	playerToPartyId[targetPlayer] = nil
	PlayerLocationService.setLocation(targetPlayer, PlayerLocationService.LocationState.Lobby)
	broadcastNoParty(targetPlayer)

	logInfo("%s: %s kicked %s from party %s", service.Name, player.Name, (targetPlayer :: Player).Name, partyId)
	broadcastPartyState(party)
	broadcastPartyList()

	return true, "ok", nil
end

local function handleSetSize(player: Player, newSize: any): (boolean, string, any)
	if type(newSize) ~= "number" then
		return false, "invalid_args", nil
	end

	local partyId = playerToPartyId[player]
	if partyId == nil then
		return false, "no_party", nil
	end
	local party = parties[partyId]
	if party == nil then
		playerToPartyId[player] = nil
		return false, "party_not_found", nil
	end
	if party.host ~= player then
		return false, "not_host", nil
	end
	if party.state ~= PartyState.Waiting then
		return false, "wrong_state", nil
	end

	local clamped = math.clamp(math.floor(newSize), PartyConfig.Party.MinPlayers, PartyConfig.Party.MaxPlayers)
	if clamped < #party.players then
		-- Cannot reduce below the current membership count.
		return false, "invalid_size", nil
	end

	party.maxPlayers = clamped
	logInfo("%s: %s set max players to %d in party %s", service.Name, player.Name, clamped, partyId)
	broadcastPartyState(party)
	broadcastPartyList()

	return true, "ok", nil
end

-- ---------------------------------------------------------------------------
-- Remote request router
-- ---------------------------------------------------------------------------

local VALID_OPERATIONS: { [string]: boolean } = {
	create = true,
	join = true,
	leave = true,
	ready = true,
	unready = true,
	start = true,
	cancel = true,
	kick = true,
	setSize = true,
}

local function handleRequest(player: Player, operation: any, arg1: any): (boolean, string, any)
	-- Validate operation type before any rate-limit check so malformed requests
	-- are cheap to reject without recording a timestamp.
	if type(operation) ~= "string" or not VALID_OPERATIONS[operation] then
		return false, "invalid_args", nil
	end

	-- Per-player rate limiting.  Rejected requests must not mutate party state
	-- or trigger any broadcasts.
	local now = os.clock()
	if not checkRateLimit(player, operation, now) then
		logInfo("%s: rate_limited %s for operation '%s'", service.Name, player.Name, operation)
		return false, "rate_limited", nil
	end
	-- Record timestamp before dispatching so the interval is measured from the
	-- moment the request was accepted, not from when it finished.
	recordRequest(player, operation, now)

	local ok, success, code, data = pcall(function(): (boolean, string, any)
		if operation == "create" then
			return handleCreate(player)
		elseif operation == "join" then
			return handleJoin(player, arg1)
		elseif operation == "leave" then
			return handleLeave(player)
		elseif operation == "ready" then
			return handleReady(player)
		elseif operation == "unready" then
			return handleUnready(player)
		elseif operation == "start" then
			return handleStart(player)
		elseif operation == "cancel" then
			return handleCancel(player)
		elseif operation == "kick" then
			return handleKick(player, arg1)
		elseif operation == "setSize" then
			return handleSetSize(player, arg1)
		end
		return false, "invalid_args", nil
	end)

	if not ok then
		logWarn(
			"%s: uncaught error in operation '%s' for %s: %s",
			service.Name,
			tostring(operation),
			player.Name,
			tostring(success)
		)
		return false, "internal_error", nil
	end

	return success, code, data
end

-- ---------------------------------------------------------------------------
-- Public API (callable by other server modules)
-- ---------------------------------------------------------------------------

-- Returns the PartyData for the given player, or nil if they have no party.
-- The returned table is the live internal record; callers must not modify it.
function service.getPartyForPlayer(player: Player): PartyData?
	local partyId = playerToPartyId[player]
	if partyId == nil then
		return nil
	end
	return parties[partyId]
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

	partyRequestRemote = Remotes.get(Remotes.Names.PartyRequest)
	partyStateChangedRemote = Remotes.get(Remotes.Names.PartyStateChanged)
	partyListChangedRemote = Remotes.get(Remotes.Names.PartyListChanged)

	partyRequestRemote.OnServerInvoke = function(player: Player, operation: any, arg1: any)
		return handleRequest(player, operation, arg1)
	end
	serviceJanitor:Add(function()
		if partyRequestRemote ~= nil then
			partyRequestRemote.OnServerInvoke = nil
		end
	end)

	-- Clean up party memberships and rate-limit records when a player disconnects.
	serviceJanitor:Add(Players.PlayerRemoving:Connect(function(player: Player)
		removePlayerFromParty(player)
		cleanRateLimitRecords(player)
	end))

	-- Broadcast the initial empty party list so connecting clients start correctly.
	broadcastPartyList()

	started = true
	context.Logger.info("%s started", service.Name)
end

function service.Stop(context)
	-- Tear down all parties so countdown threads are cancelled and members notified.
	local partyIds = {}
	for partyId in parties do
		table.insert(partyIds, partyId)
	end
	for _, partyId in partyIds do
		local party = parties[partyId]
		if party ~= nil then
			destroyParty(party)
		end
	end

	-- Clear rate-limit records for all players.
	for player in globalLastRequest do
		globalLastRequest[player] = nil
	end
	for player in operationLastRequest do
		operationLastRequest[player] = nil
	end

	if serviceJanitor ~= nil then
		serviceJanitor:Cleanup()
		serviceJanitor = nil
	end

	partyRequestRemote = nil
	partyStateChangedRemote = nil
	partyListChangedRemote = nil
	serviceLogger = nil
	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
