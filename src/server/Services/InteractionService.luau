-- InteractionService
-- Server-authoritative service for the full interaction session lifecycle.
--
-- Interaction modes
--   Instant      Validate and complete immediately; no session is created.
--   Hold         Create a server-owned timed session.  The server drives
--                completion via RunService.Heartbeat; the client only displays
--                progress.  Elapsed time, completion time, and distance are
--                NEVER trusted from the client.
--
-- Concurrency policies (controlled per definition)
--   exclusive=true   At most one active session may lock the target at a time.
--                    Two near-simultaneous Begin requests result in exactly one
--                    accepted lock.
--   exclusive=false  Multiple players may hold independent sessions on the same
--                    target (shared / cooperative foundation).
--
-- Public API available to other server modules
--   register(id, def)                   Declare an interactable.
--   replaceRegistration(id, def)        Replace an existing registration safely.
--   unregister(id)                      Remove and cancel all sessions for a target.
--   cancelPlayerInteractions(player, reason)
--   cancelTargetInteractions(id, reason)
--   resetAll(reason)                    Cancel all sessions; clear cooldowns.
--   broadcastState(id, state, player?)  Push target-state change to clients.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

type InteractionDefinition = Types.InteractionDefinition
type SessionRecord = Types.SessionRecord
type InteractionMode = Types.InteractionMode

local service = {
	Name = "InteractionService",
}

-- ---------------------------------------------------------------------------
-- Module-level state (reset on Stop)
-- ---------------------------------------------------------------------------

local initialized = false
local started = false
local serviceJanitor = nil
local gameConfig = nil
local serviceLogger = nil

-- All active sessions indexed by sessionId.
local activeSessions: { [string]: SessionRecord } = {}
-- Reverse-index: userId → set of sessionIds
local sessionsByPlayer: { [number]: { [string]: boolean } } = {}
-- Reverse-index: interactableId → set of sessionIds
local sessionsByTarget: { [string]: { [string]: boolean } } = {}
-- Exclusive locks: interactableId → sessionId that holds the lock
local exclusiveLocks: { [string]: string } = {}
-- Per-target cooldowns: interactableId → os.clock() expiry
local cooldowns: { [string]: number } = {}
-- Per-player rate limit: userId → os.clock() of last accepted Begin/Instant
local lastRequestTime: { [number]: number } = {}
-- Registered interactable definitions
local registry: { [string]: InteractionDefinition } = {}
-- Monotonic counter used in session ID generation
local sessionCounter = 0

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function logWarn(msg: string, ...)
	if serviceLogger ~= nil then
		serviceLogger.warn(msg, ...)
	else
		warn(string.format("[TheosRobloxGame] " .. msg, ...))
	end
end

local function logInfo(msg: string, ...)
	if serviceLogger ~= nil then
		serviceLogger.info(msg, ...)
	end
end

local function newSessionId(): string
	sessionCounter += 1
	return string.format("sid_%d_%08x", sessionCounter, math.random(0, 2147483647))
end

-- Fires InteractionStateChanged.  Silently skips if service is not started.
function service.broadcastState(interactableId: string, state: string, player: Player?)
	if not started then
		return
	end
	local remote = Remotes.get(Remotes.Names.InteractionStateChanged)
	if player ~= nil then
		remote:FireClient(player, interactableId, state)
	else
		remote:FireAllClients(interactableId, state)
	end
end

-- Removes a session from all tracking tables and releases its exclusive lock.
-- Does NOT call any callbacks; callers are responsible for that first.
local function cleanupSession(sessionId: string)
	local session = activeSessions[sessionId]
	if session == nil then
		return
	end

	local interactableId = session.interactableId
	local userId = session.userId

	activeSessions[sessionId] = nil

	if sessionsByPlayer[userId] ~= nil then
		sessionsByPlayer[userId][sessionId] = nil
		if next(sessionsByPlayer[userId]) == nil then
			sessionsByPlayer[userId] = nil
		end
	end

	if sessionsByTarget[interactableId] ~= nil then
		sessionsByTarget[interactableId][sessionId] = nil
		if next(sessionsByTarget[interactableId]) == nil then
			sessionsByTarget[interactableId] = nil
		end
	end

	-- Release exclusive lock if this session held it.
	if exclusiveLocks[interactableId] == sessionId then
		exclusiveLocks[interactableId] = nil
		-- Broadcast available only when no cooldown is active.
		local now = os.clock()
		local cooldownExpiry = cooldowns[interactableId]
		if cooldownExpiry == nil or now >= cooldownExpiry then
			service.broadcastState(interactableId, "available")
		end
	end
end

-- Cancels an active session, fires OnCancelled, then cleans up.
local function cancelSession(sessionId: string, reason: string)
	local session = activeSessions[sessionId]
	if session == nil or session.cancelled or session.completed then
		return
	end

	session.cancelled = true

	local def = registry[session.interactableId]
	if def ~= nil and def.OnCancelled ~= nil then
		local ok, err = pcall(def.OnCancelled, session.player, sessionId, reason)
		if not ok then
			logWarn("InteractionService: OnCancelled error for %s: %s", session.interactableId, tostring(err))
		end
	end

	cleanupSession(sessionId)
end

-- Checks player character validity.  Returns (true, "ok") or (false, code).
local function validatePlayer(player: Player): (boolean, string)
	local character = player.Character
	if character == nil then
		return false, "no_character"
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return false, "no_character"
	end
	if humanoid.Health <= 0 then
		return false, "dead"
	end
	if character:FindFirstChild("HumanoidRootPart") == nil then
		return false, "no_character"
	end
	return true, "ok"
end

-- Resolves the target part via getPrimaryPart (pcall-wrapped).
-- Returns (part, nil) on success, (nil, code) on failure.
local function getTargetPart(def: InteractionDefinition): (BasePart?, string?)
	local ok, result = pcall(def.getPrimaryPart)
	if not ok then
		logWarn("InteractionService: getPrimaryPart error for %s: %s", def.id, tostring(result))
		return nil, "handler_error"
	end
	if result == nil then
		return nil, "target_removed"
	end
	return result, nil
end

-- Evaluates the definition's enabled field (boolean or resolver function).
local function isEnabled(def: InteractionDefinition): boolean
	local enabled = def.enabled
	if enabled == nil then
		return true
	end
	if type(enabled) == "boolean" then
		return enabled :: boolean
	end
	if type(enabled) == "function" then
		local ok, result = pcall(enabled :: () -> boolean)
		if not ok then
			logWarn("InteractionService: enabled resolver error for %s", def.id)
			return false
		end
		return result == true
	end
	return true
end

-- Runs common validation before both Begin and Instant operations.
-- Returns (primaryPart, rootPart, code): non-nil part+root means success.
local function validateCommon(player: Player, def: InteractionDefinition, now: number): (BasePart?, BasePart?, string)
	-- Player checks
	local playerOk, playerCode = validatePlayer(player)
	if not playerOk then
		return nil, nil, playerCode
	end

	local character = player.Character :: Model
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart

	-- Target existence and enabled
	if not isEnabled(def) then
		return nil, nil, "not_enabled"
	end
	local primaryPart, partErr = getTargetPart(def)
	if primaryPart == nil then
		return nil, nil, partErr :: string
	end

	-- Distance
	local maxDist = def.maxDistance or (gameConfig and gameConfig.Interaction.MaxDistance or 12)
	local dist = (rootPart.Position - (primaryPart :: BasePart).Position).Magnitude
	if dist > maxDist then
		return nil, nil, "too_far"
	end

	-- Cooldown
	local cooldownExpiry = cooldowns[def.id]
	if cooldownExpiry ~= nil and now < cooldownExpiry then
		return nil, nil, "cooldown"
	end

	return primaryPart, rootPart, "ok"
end

-- Runs CanInteract callback (pcall-wrapped).  Returns (true,"ok") or (false,code).
local function runCanInteract(def: InteractionDefinition, player: Player): (boolean, string)
	if def.CanInteract == nil then
		return true, "ok"
	end
	local ok, canInteract, reason = pcall(def.CanInteract, player)
	if not ok then
		logWarn("InteractionService: CanInteract error for %s: %s", def.id, tostring(canInteract))
		return false, "handler_error"
	end
	if not canInteract then
		logInfo("InteractionService: CanInteract rejected %s for player %s: %s", def.id, player.Name, tostring(reason))
		return false, "not_enabled"
	end
	return true, "ok"
end

-- ---------------------------------------------------------------------------
-- Operation handlers
-- ---------------------------------------------------------------------------

local function handleInstant(player: Player, interactableId: string): (boolean, string, string?)
	local userId = player.UserId
	local now = os.clock()

	-- Rate limit
	local rateLimit = gameConfig and gameConfig.Interaction.RateLimitSeconds or 0.3
	local last = lastRequestTime[userId]
	if last ~= nil and (now - last) < rateLimit then
		return false, "rate_limited", nil
	end
	lastRequestTime[userId] = now

	local def = registry[interactableId]
	if def == nil then
		return false, "not_registered", nil
	end
	if def.mode ~= "Instant" then
		return false, "wrong_operation", nil
	end

	local primaryPart, _, code = validateCommon(player, def, now)
	if primaryPart == nil then
		return false, code, nil
	end

	local canOk, canCode = runCanInteract(def, player)
	if not canOk then
		return false, canCode, nil
	end

	-- Dispatch
	local handlerSuccess = true
	if def.OnCompleted ~= nil then
		local ok, result, _ = pcall(def.OnCompleted, player, "instant")
		if not ok then
			logWarn("InteractionService: OnCompleted error for %s: %s", interactableId, tostring(result))
			return false, "handler_error", nil
		end
		handlerSuccess = result == true
	end

	-- Apply cooldown
	if def.cooldown ~= nil and def.cooldown > 0 then
		cooldowns[interactableId] = now + def.cooldown
		service.broadcastState(interactableId, "cooldown")
	end

	return handlerSuccess, "ok", nil
end

local function handleBegin(player: Player, interactableId: string): (boolean, string, string?)
	local userId = player.UserId
	local now = os.clock()

	-- Rate limit
	local rateLimit = gameConfig and gameConfig.Interaction.RateLimitSeconds or 0.3
	local last = lastRequestTime[userId]
	if last ~= nil and (now - last) < rateLimit then
		return false, "rate_limited", nil
	end
	lastRequestTime[userId] = now

	local def = registry[interactableId]
	if def == nil then
		return false, "not_registered", nil
	end
	if def.mode ~= "Hold" then
		return false, "wrong_operation", nil
	end

	local primaryPart, _, code = validateCommon(player, def, now)
	if primaryPart == nil then
		return false, code, nil
	end

	-- Session limit
	local maxSessions = gameConfig and gameConfig.Interaction.MaxActiveSessions or 3
	local playerSessions = sessionsByPlayer[userId]
	local sessionCount = 0
	if playerSessions ~= nil then
		for _ in pairs(playerSessions) do
			sessionCount += 1
		end
	end
	if sessionCount >= maxSessions then
		return false, "session_limit", nil
	end

	-- Exclusive lock
	if def.exclusive then
		if exclusiveLocks[interactableId] ~= nil then
			return false, "locked", nil
		end
	end

	local canOk, canCode = runCanInteract(def, player)
	if not canOk then
		return false, canCode, nil
	end

	-- Build session
	local sessionId = newSessionId()
	local holdDuration = def.holdDuration or 3
	local expiryBuffer = gameConfig and gameConfig.Interaction.SessionExpiryBuffer or 2

	local character = player.Character :: Model
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local startHealth = 0
	if humanoid ~= nil then
		startHealth = humanoid.Health
	end

	local session: SessionRecord = {
		sessionId = sessionId,
		player = player,
		userId = userId,
		interactableId = interactableId,
		actionName = def.actionName,
		mode = "Hold",
		startTime = now,
		requiredDuration = holdDuration,
		expiresAt = now + holdDuration + expiryBuffer,
		cancelled = false,
		completed = false,
		startHealth = startHealth,
	}

	-- Register in all indexes
	activeSessions[sessionId] = session

	if sessionsByPlayer[userId] == nil then
		sessionsByPlayer[userId] = {}
	end
	sessionsByPlayer[userId][sessionId] = true

	if sessionsByTarget[interactableId] == nil then
		sessionsByTarget[interactableId] = {}
	end
	sessionsByTarget[interactableId][sessionId] = true

	-- Acquire exclusive lock before broadcasting
	if def.exclusive then
		exclusiveLocks[interactableId] = sessionId
		service.broadcastState(interactableId, "locked")
	end

	-- OnStarted (non-fatal)
	if def.OnStarted ~= nil then
		local ok, err = pcall(def.OnStarted, player, sessionId)
		if not ok then
			logWarn("InteractionService: OnStarted error for %s: %s", interactableId, tostring(err))
		end
	end

	return true, "ok", sessionId
end

local function handleCancel(player: Player, interactableId: string, sessionId: any): (boolean, string, string?)
	if type(sessionId) ~= "string" or sessionId == "" then
		return false, "invalid_args", nil
	end

	local session = activeSessions[sessionId]
	if session == nil then
		return false, "session_not_found", nil
	end
	if session.userId ~= player.UserId then
		return false, "not_owner", nil
	end
	if session.interactableId ~= interactableId then
		return false, "invalid_args", nil
	end
	if session.cancelled or session.completed then
		return false, "already_resolved", nil
	end

	cancelSession(sessionId, "player_cancelled")
	return true, "ok", nil
end

-- Revalidates a Hold session before server-side completion.
-- Returns (true,"ok") or (false, cancelReason).
local function revalidateForCompletion(session: SessionRecord): (boolean, string)
	local def = registry[session.interactableId]
	if def == nil then
		return false, "target_removed"
	end

	local playerOk, playerCode = validatePlayer(session.player)
	if not playerOk then
		return false, playerCode
	end

	if not isEnabled(def) then
		return false, "not_enabled"
	end

	local primaryPart, partErr = getTargetPart(def)
	if primaryPart == nil then
		return false, partErr :: string
	end

	local character = session.player.Character :: Model
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart
	local maxDist = def.maxDistance or (gameConfig and gameConfig.Interaction.MaxDistance or 12)
	local dist = (rootPart.Position - (primaryPart :: BasePart).Position).Magnitude
	if dist > maxDist then
		return false, "too_far"
	end

	return true, "ok"
end

-- Attempts server-side completion of a Hold session.
-- Runs full revalidation; falls back to cancelSession on failure.
local function completeSession(sessionId: string)
	local session = activeSessions[sessionId]
	if session == nil or session.cancelled or session.completed then
		return
	end

	local valid, reason = revalidateForCompletion(session)
	if not valid then
		cancelSession(sessionId, reason)
		return
	end

	-- Mark completed before calling handler to prevent re-entry.
	session.completed = true

	local def = registry[session.interactableId]
	if def ~= nil and def.OnCompleted ~= nil then
		local ok, result, _ = pcall(def.OnCompleted, session.player, sessionId)
		if not ok then
			logWarn("InteractionService: OnCompleted error for %s: %s", session.interactableId, tostring(result))
			-- Session is already marked completed; clean up regardless.
		end
	end

	cleanupSession(sessionId)

	-- Apply cooldown after cleanup so the lock is released first.
	if def ~= nil and def.cooldown ~= nil and def.cooldown > 0 then
		cooldowns[session.interactableId] = os.clock() + def.cooldown
		service.broadcastState(session.interactableId, "cooldown")
	end
end

-- ---------------------------------------------------------------------------
-- Heartbeat — drives Hold completion, expiry, movement, and damage checks
-- ---------------------------------------------------------------------------

local function processHeartbeat()
	local now = os.clock()

	-- Collect session IDs first to avoid mutating the table mid-iteration.
	local ids = {}
	for sessionId in pairs(activeSessions) do
		table.insert(ids, sessionId)
	end

	for _, sessionId in ipairs(ids) do
		local session = activeSessions[sessionId]
		if session == nil or session.cancelled or session.completed then
			continue
		end

		local def = registry[session.interactableId]

		-- Target unregistered mid-session
		if def == nil then
			cancelSession(sessionId, "target_removed")
			continue
		end

		-- Safety-net expiry
		if now >= session.expiresAt then
			cancelSession(sessionId, "expired")
			continue
		end

		-- Movement cancellation
		if def.cancelOnMovement then
			local character = session.player.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if rootPart ~= nil then
				local ppOk, pp = pcall(def.getPrimaryPart)
				if ppOk and pp ~= nil then
					local maxDist = def.maxDistance or (gameConfig and gameConfig.Interaction.MaxDistance or 12)
					if ((rootPart :: BasePart).Position - (pp :: BasePart).Position).Magnitude > maxDist then
						cancelSession(sessionId, "player_moved")
						continue
					end
				end
			end
		end

		-- Damage cancellation
		if def.cancelOnDamage then
			local character = session.player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil and humanoid.Health < session.startHealth then
				cancelSession(sessionId, "player_damaged")
				continue
			end
		end

		-- Server-owned hold completion
		if now >= session.startTime + session.requiredDuration then
			completeSession(sessionId)
		end
	end

	-- Expire cooldowns and broadcast available when they clear.
	local expiredTargets = {}
	for targetId, expiresAt in pairs(cooldowns) do
		if now >= expiresAt then
			table.insert(expiredTargets, targetId)
		end
	end
	for _, targetId in ipairs(expiredTargets) do
		cooldowns[targetId] = nil
		if exclusiveLocks[targetId] == nil and registry[targetId] ~= nil then
			service.broadcastState(targetId, "available")
		end
	end
end

-- ---------------------------------------------------------------------------
-- Public management API
-- ---------------------------------------------------------------------------

-- Registers an interactable.  Errors if the ID is already registered.
-- Use replaceRegistration to replace an existing entry safely.
function service.register(id: string, definition: InteractionDefinition)
	assert(type(id) == "string" and id ~= "", "id must be a non-empty string")
	assert(registry[id] == nil, string.format("'%s' is already registered; use replaceRegistration", id))
	assert(type(definition) == "table", "definition must be a table")
	assert(type(definition.actionName) == "string" and definition.actionName ~= "", "actionName required")
	assert(type(definition.displayName) == "string" and definition.displayName ~= "", "displayName required")
	assert(definition.mode == "Instant" or definition.mode == "Hold", "mode must be 'Instant' or 'Hold'")
	assert(type(definition.getPrimaryPart) == "function", "getPrimaryPart must be a function")
	if definition.mode == "Hold" then
		assert(
			type(definition.holdDuration) == "number" and definition.holdDuration > 0,
			"holdDuration must be a positive number for Hold mode"
		)
	end
	registry[id] = definition
end

-- Cancels all sessions for the target, then replaces its registration.
function service.replaceRegistration(id: string, definition: InteractionDefinition)
	if registry[id] ~= nil then
		service.cancelTargetInteractions(id, "target_replaced")
	end
	registry[id] = nil
	service.register(id, definition)
end

-- Cancels all sessions for the target and removes it from the registry.
function service.unregister(id: string)
	service.cancelTargetInteractions(id, "target_removed")
	registry[id] = nil
	service.broadcastState(id, "disabled")
end

-- Cancels every active session belonging to the given player.
function service.cancelPlayerInteractions(player: Player, reason: string)
	local userId = player.UserId
	local sessions = sessionsByPlayer[userId]
	if sessions == nil then
		return
	end
	local toCancel = {}
	for sessionId in pairs(sessions) do
		table.insert(toCancel, sessionId)
	end
	for _, sessionId in ipairs(toCancel) do
		cancelSession(sessionId, reason)
	end
end

-- Cancels every active session targeting the given interactable.
function service.cancelTargetInteractions(interactableId: string, reason: string)
	local sessions = sessionsByTarget[interactableId]
	if sessions == nil then
		return
	end
	local toCancel = {}
	for sessionId in pairs(sessions) do
		table.insert(toCancel, sessionId)
	end
	for _, sessionId in ipairs(toCancel) do
		cancelSession(sessionId, reason)
	end
end

-- Cancels ALL active sessions and clears cooldowns.  Used for room/round resets.
function service.resetAll(reason: string)
	local toCancel = {}
	for sessionId in pairs(activeSessions) do
		table.insert(toCancel, sessionId)
	end
	for _, sessionId in ipairs(toCancel) do
		cancelSession(sessionId, reason)
	end
	cooldowns = {}
end

-- Calls Reset on every registered definition (pcall-wrapped).
function service.resetDefinitions()
	for id, def in pairs(registry) do
		if def.Reset ~= nil then
			local ok, err = pcall(def.Reset)
			if not ok then
				logWarn("InteractionService: Reset error for %s: %s", id, tostring(err))
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Player lifecycle binding
-- ---------------------------------------------------------------------------

local function bindPlayer(player: Player)
	serviceJanitor:Add(player.CharacterRemoving:Connect(function()
		service.cancelPlayerInteractions(player, "player_died")
	end))
	serviceJanitor:Add(player.CharacterAdded:Connect(function()
		-- After respawn clear any stale rate-limit timestamp so the fresh
		-- character can interact immediately.
		lastRequestTime[player.UserId] = nil
	end))
end

-- ---------------------------------------------------------------------------
-- Bootstrap lifecycle
-- ---------------------------------------------------------------------------

function service.Init(context)
	if initialized then
		context.Logger.warn("%s already initialized", service.Name)
		return
	end

	initialized = true
	gameConfig = context.Config
	serviceLogger = context.Logger

	Remotes.setup()

	local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)
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

	-- Bind request handler
	local requestRemote = Remotes.get(Remotes.Names.InteractionRequest)
	requestRemote.OnServerInvoke = function(player: Player, operation: any, interactableId: any, sessionId: any)
		if type(operation) ~= "string" or operation == "" then
			return false, "invalid_args", nil
		end
		if type(interactableId) ~= "string" or interactableId == "" then
			return false, "invalid_args", nil
		end
		if operation == "instant" then
			return handleInstant(player, interactableId)
		elseif operation == "begin" then
			return handleBegin(player, interactableId)
		elseif operation == "cancel" then
			return handleCancel(player, interactableId, sessionId)
		else
			return false, "invalid_args", nil
		end
	end
	serviceJanitor:Add(function()
		requestRemote.OnServerInvoke = nil
	end)

	-- Heartbeat for hold completion and expiry
	serviceJanitor:Add(RunService.Heartbeat:Connect(processHeartbeat))

	-- Player lifecycle
	for _, player in ipairs(Players:GetPlayers()) do
		bindPlayer(player)
	end
	serviceJanitor:Add(Players.PlayerAdded:Connect(function(player)
		bindPlayer(player)
	end))
	serviceJanitor:Add(Players.PlayerRemoving:Connect(function(player)
		service.cancelPlayerInteractions(player, "player_disconnected")
		lastRequestTime[player.UserId] = nil
	end))

	started = true
	context.Logger.info("%s started", service.Name)
end

function service.Stop(context)
	-- Cancel all active sessions before tearing down.
	service.resetAll("service_reset")

	-- Call Cleanup on all definitions.
	for id, def in pairs(registry) do
		if def.Cleanup ~= nil then
			local ok, err = pcall(def.Cleanup)
			if not ok then
				logWarn("InteractionService: Cleanup error for %s: %s", id, tostring(err))
			end
		end
	end

	registry = {}
	cooldowns = {}
	lastRequestTime = {}
	gameConfig = nil
	serviceLogger = nil

	if serviceJanitor ~= nil then
		serviceJanitor:Cleanup()
		serviceJanitor = nil
	end

	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
