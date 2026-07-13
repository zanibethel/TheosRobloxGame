-- RoomService
-- Manages the first playable search-room interactions and state:
--
--   room_search_drawer  Hold-mode, exclusive, once per session.
--                       OnCompleted awards the exit key via KeyService and
--                       changes the drawer colour to indicate it has been
--                       searched.
--
--   room_exit_door      Instant-mode, exclusive, once per session.
--                       CanInteract fires a RoomFeedback message when the
--                       player has no key ("The door is locked.").
--                       OnCompleted consumes the key, tweens the door open,
--                       and broadcasts RoomStateChanged("complete").
--
-- Both interactions reuse InteractionService for all remote/session/
-- validation plumbing.  This service owns per-session room state only;
-- geometry lives in TestRoomBuilder.

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RoomConfig = require(ReplicatedStorage.Shared.Config.RoomConfig)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

local service = {
	Name = "RoomService",
}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local initialized = false
local started = false
local serviceJanitor = nil
local serviceLogger = nil

-- Per-session flags; cleared on reset / service stop.
local drawerSearched = false
local doorUnlocked = false

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

local function getRoomFolder(): Instance?
	return Workspace:FindFirstChild("TestRoom")
end

local function getDrawerPart(): BasePart?
	local room = getRoomFolder()
	if room == nil then
		return nil
	end
	local drawer = room:FindFirstChild("Drawer")
	if drawer == nil then
		return nil
	end
	local body = drawer:FindFirstChild("Body")
	if body ~= nil and body:IsA("BasePart") then
		return body :: BasePart
	end
	return nil
end

local function getDoorPart(): BasePart?
	local room = getRoomFolder()
	if room == nil then
		return nil
	end
	local door = room:FindFirstChild("ExitDoor")
	if door == nil then
		return nil
	end
	local panel = door:FindFirstChild("DoorPanel")
	if panel ~= nil and panel:IsA("BasePart") then
		return panel :: BasePart
	end
	return nil
end

-- Stores RoomState on the folder (replicated attribute) and fires all clients.
local function broadcastRoomState(state: string)
	local room = getRoomFolder()
	if room ~= nil then
		room:SetAttribute("RoomState", state)
	end
	local remote = Remotes.get(Remotes.Names.RoomStateChanged)
	remote:FireAllClients(state)
end

-- Fires a contextual message to one player (e.g. "The door is locked.").
local function sendFeedback(player: Player, message: string)
	local remote = Remotes.get(Remotes.Names.RoomFeedback)
	remote:FireClient(player, message)
end

-- Slides the door panel up above the doorway using TweenService.
-- Disables collision after the tween completes so players can walk through.
local function animateDoorOpen(doorPart: BasePart)
	local raisedCFrame = doorPart.CFrame + Vector3.new(0, RoomConfig.DoorSize.Y + 1, 0)
	local tweenInfo = TweenInfo.new(RoomConfig.DoorOpenDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(doorPart, tweenInfo, { CFrame = raisedCFrame })
	tween:Play()
	task.delay(RoomConfig.DoorOpenDuration, function()
		if doorPart ~= nil and doorPart.Parent ~= nil then
			doorPart.CanCollide = false
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Interaction registration
-- ---------------------------------------------------------------------------

local function registerInteractions(InteractionService: any, KeyService: any)
	-- -----------------------------------------------------------------------
	-- room_search_drawer — Hold, exclusive, once per session
	-- -----------------------------------------------------------------------
	InteractionService.register("room_search_drawer", {
		id = "room_search_drawer",
		actionName = "Search",
		displayName = "Drawer",
		mode = "Hold",
		holdDuration = RoomConfig.SearchHoldDuration,
		exclusive = true,
		-- Disabled globally once the drawer has been searched.
		enabled = function(): boolean
			return not drawerSearched
		end,
		getPrimaryPart = getDrawerPart,
		CanInteract = function(_player: Player): (boolean, string?)
			if drawerSearched then
				return false, "already_searched"
			end
			return true, nil
		end,
		OnCompleted = function(player: Player, _sessionId: string): (boolean, string?)
			-- Guard against a second completion that wins the race after the
			-- first completion sets drawerSearched = true.
			if drawerSearched then
				return false, "already_searched"
			end
			drawerSearched = true

			-- Visual: shift colour to indicate the drawer has been searched.
			local drawerPart = getDrawerPart()
			if drawerPart ~= nil then
				drawerPart.Color = Color3.fromRGB(120, 80, 40)
			end

			-- Award the exit key and send a "Key found!" feedback message.
			KeyService.awardKey(player)
			sendFeedback(player, "Key found!")

			if serviceLogger ~= nil then
				serviceLogger.info("%s: key awarded to %s", service.Name, player.Name)
			end

			return true, nil
		end,
		Reset = function()
			drawerSearched = false
			local drawerPart = getDrawerPart()
			if drawerPart ~= nil then
				drawerPart.Color = Color3.fromRGB(163, 120, 60)
			end
		end,
	})

	-- -----------------------------------------------------------------------
	-- room_exit_door — Instant, exclusive, once per session
	-- -----------------------------------------------------------------------
	InteractionService.register("room_exit_door", {
		id = "room_exit_door",
		actionName = "Use Key",
		displayName = "Exit Door",
		mode = "Instant",
		exclusive = true,
		-- Disabled globally once the door has been unlocked.
		enabled = function(): boolean
			return not doorUnlocked
		end,
		getPrimaryPart = getDoorPart,
		CanInteract = function(player: Player): (boolean, string?)
			if doorUnlocked then
				return false, "already_unlocked"
			end
			if not KeyService.hasKey(player) then
				-- Fire a feedback message so the player knows why it failed.
				sendFeedback(player, "The door is locked.")
				return false, "no_key"
			end
			return true, nil
		end,
		OnCompleted = function(player: Player, _sessionId: string): (boolean, string?)
			-- Double-check; another winner may have beaten us between CanInteract
			-- and OnCompleted (Instant mode, no exclusive session window).
			if doorUnlocked then
				return false, "already_unlocked"
			end
			doorUnlocked = true

			-- Consume the key.
			if RoomConfig.ConsumeKeyOnUnlock then
				KeyService.consumeKey(player)
			end

			-- Animate the door opening.
			local doorPart = getDoorPart()
			if doorPart ~= nil then
				animateDoorOpen(doorPart)
			end

			-- Broadcast success state to all players.
			broadcastRoomState("complete")

			if serviceLogger ~= nil then
				serviceLogger.info(
					"%s: door unlocked by %s — room complete",
					service.Name,
					player.Name
				)
			end

			return true, nil
		end,
		Reset = function()
			doorUnlocked = false
		end,
	})
end

-- ---------------------------------------------------------------------------
-- Public reset API
-- ---------------------------------------------------------------------------

-- Resets per-session state and visual state for a new round.
-- Call this before starting a new session while the room geometry persists.
function service.reset(KeyService: any)
	drawerSearched = false
	doorUnlocked = false

	-- Reset drawer colour.
	local drawerPart = getDrawerPart()
	if drawerPart ~= nil then
		drawerPart.Color = Color3.fromRGB(163, 120, 60)
	end

	-- Reset door position and collision.
	local doorPart = getDoorPart()
	if doorPart ~= nil then
		doorPart.CFrame = CFrame.new(RoomConfig.DoorPosition)
		doorPart.CanCollide = true
	end

	-- Clear all player keys.
	if KeyService ~= nil then
		KeyService.reset()
	end

	broadcastRoomState("searching")
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

	local InteractionService = require(script.Parent.InteractionService)
	local KeyService = require(script.Parent.KeyService)

	registerInteractions(InteractionService, KeyService)

	started = true
	context.Logger.info("%s started", service.Name)
end

function service.Stop(context)
	-- Unregister interactions so InteractionService does not reference stale
	-- definitions after this module is torn down.
	local ok, InteractionService = pcall(require, script.Parent.InteractionService)
	if ok and InteractionService ~= nil and InteractionService.unregister ~= nil then
		pcall(InteractionService.unregister, "room_search_drawer")
		pcall(InteractionService.unregister, "room_exit_door")
	end

	if serviceJanitor ~= nil then
		serviceJanitor:Cleanup()
		serviceJanitor = nil
	end

	drawerSearched = false
	doorUnlocked = false
	serviceLogger = nil
	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
