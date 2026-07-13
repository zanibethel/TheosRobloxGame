-- RoomController
-- Client-side controller for the first playable search room.
-- Listens to three RemoteEvents from the server:
--
--   KeyStateChanged  (hasKey: boolean)
--     Updates the "Exit Key: Yes / No" status label in the HUD.
--
--   RoomStateChanged (state: string)
--     Shows the "Room Complete" overlay when state == "complete".
--
--   RoomFeedback     (message: string)
--     Displays a brief contextual message such as "The door is locked."
--     or "Key found!" in the centre of the screen, then fades it after
--     a short delay.
--
-- The controller also reads workspace.TestRoom:GetAttribute("RoomState")
-- and watches for the attribute to change so a player who respawns after
-- room completion sees the correct overlay without a server broadcast.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PartyConfig = require(ReplicatedStorage.Shared.Config.PartyConfig)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

local FEEDBACK_VISIBLE_SECONDS = 3

local controller = {
	Name = "RoomController",
}

local initialized = false
local started = false
local controllerJanitor = nil

-- ---------------------------------------------------------------------------
-- UI construction
-- ---------------------------------------------------------------------------

local function buildHUD(playerGui: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "RoomHUD"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- ---- Key status (bottom-right corner) ----------------------------------
	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "KeyStatusLabel"
	keyLabel.Size = UDim2.new(0, 200, 0, 36)
	keyLabel.Position = UDim2.new(1, -210, 1, -46)
	keyLabel.AnchorPoint = Vector2.new(0, 0)
	keyLabel.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
	keyLabel.BackgroundTransparency = 0.4
	keyLabel.BorderSizePixel = 0
	keyLabel.Text = "Exit Key: No"
	keyLabel.TextColor3 = Color3.fromRGB(200, 180, 100)
	keyLabel.TextSize = 14
	keyLabel.Font = Enum.Font.GothamBold
	keyLabel.TextXAlignment = Enum.TextXAlignment.Center
	keyLabel.Parent = gui

	-- ---- Feedback message (centre screen, temporary) -----------------------
	local feedbackLabel = Instance.new("TextLabel")
	feedbackLabel.Name = "FeedbackLabel"
	feedbackLabel.Size = UDim2.new(0, 320, 0, 48)
	feedbackLabel.Position = UDim2.fromScale(0.5, 0.55)
	feedbackLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	feedbackLabel.BackgroundTransparency = 1
	feedbackLabel.Text = ""
	feedbackLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
	feedbackLabel.TextSize = 16
	feedbackLabel.Font = Enum.Font.Gotham
	feedbackLabel.TextXAlignment = Enum.TextXAlignment.Center
	feedbackLabel.Visible = false
	feedbackLabel.Parent = gui

	-- ---- Room-complete overlay (full-screen, hidden until complete) ---------
	local completeFrame = Instance.new("Frame")
	completeFrame.Name = "RoomCompleteFrame"
	completeFrame.Size = UDim2.new(0, 400, 0, 100)
	completeFrame.Position = UDim2.fromScale(0.5, 0.35)
	completeFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	completeFrame.BackgroundColor3 = Color3.fromRGB(8, 8, 16)
	completeFrame.BackgroundTransparency = 0.2
	completeFrame.BorderSizePixel = 0
	completeFrame.Visible = false
	completeFrame.Parent = gui

	local completeLabel = Instance.new("TextLabel")
	completeLabel.Name = "RoomCompleteLabel"
	completeLabel.Size = UDim2.fromScale(1, 1)
	completeLabel.Position = UDim2.fromScale(0, 0)
	completeLabel.BackgroundTransparency = 1
	completeLabel.Text = "Room Complete"
	completeLabel.TextColor3 = Color3.fromRGB(100, 220, 100)
	completeLabel.TextSize = 28
	completeLabel.Font = Enum.Font.GothamBold
	completeLabel.TextXAlignment = Enum.TextXAlignment.Center
	completeLabel.Parent = completeFrame

	gui.Parent = playerGui
	return gui
end

-- ---------------------------------------------------------------------------
-- Controller lifecycle
-- ---------------------------------------------------------------------------

function controller.Init(context)
	if initialized then
		context.Logger.warn("%s already initialized", controller.Name)
		return
	end
	initialized = true
	controllerJanitor = Janitor.new()
	context.Janitor:Add(controllerJanitor)
end

function controller.Start(context)
	if started then
		context.Logger.warn("%s already started", controller.Name)
		return
	end
	if controllerJanitor == nil then
		error(string.format("%s cannot start: janitor is missing", controller.Name))
	end

	local localPlayer = Players.LocalPlayer
	if localPlayer == nil then
		context.Logger.warn("%s: LocalPlayer not available", controller.Name)
		return
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui", 10)
	if playerGui == nil then
		context.Logger.warn("%s: PlayerGui not available within timeout", controller.Name)
		return
	end

	local hud = buildHUD(playerGui)
	controllerJanitor:Add(hud)

	local keyLabel = hud:FindFirstChild("KeyStatusLabel")
	local feedbackLabel = hud:FindFirstChild("FeedbackLabel")
	local completeFrame = hud:FindFirstChild("RoomCompleteFrame")

	-- Active feedback dismiss thread (cancelled on new message or controller stop).
	local dismissTask = nil

	-- ---- Helpers -----------------------------------------------------------

	local function showComplete()
		if completeFrame ~= nil then
			completeFrame.Visible = true
		end
	end

	local function updateRoomState(state: any)
		if tostring(state) == "complete" then
			showComplete()
		end
	end

	local function showFeedback(message: string)
		if feedbackLabel == nil then
			return
		end
		if dismissTask ~= nil then
			task.cancel(dismissTask)
			dismissTask = nil
		end
		feedbackLabel.Text = message
		feedbackLabel.Visible = true
		dismissTask = task.delay(FEEDBACK_VISIBLE_SECONDS, function()
			if feedbackLabel ~= nil then
				feedbackLabel.Visible = false
			end
			dismissTask = nil
		end)
	end

	-- ---- Remote listeners --------------------------------------------------

	local keyRemote = Remotes.get(Remotes.Names.KeyStateChanged)
	controllerJanitor:Add(keyRemote.OnClientEvent:Connect(function(hasKey: any)
		if keyLabel ~= nil then
			keyLabel.Text = if hasKey == true then "Exit Key: Yes" else "Exit Key: No"
			keyLabel.TextColor3 = if hasKey == true
				then Color3.fromRGB(100, 220, 100)
				else Color3.fromRGB(200, 180, 100)
		end
	end))

	local roomStateRemote = Remotes.get(Remotes.Names.RoomStateChanged)
	controllerJanitor:Add(roomStateRemote.OnClientEvent:Connect(function(state: any)
		updateRoomState(state)
	end))

	local feedbackRemote = Remotes.get(Remotes.Names.RoomFeedback)
	controllerJanitor:Add(feedbackRemote.OnClientEvent:Connect(function(message: any)
		showFeedback(tostring(message))
	end))

	-- ---- Read persisted state from workspace attribute ---------------------
	-- Covers the case where the player spawns or respawns after the door has
	-- already been opened (the attribute is replicated; no server broadcast
	-- is needed for the late join).
	--
	-- A boolean guard prevents duplicate attribute listeners if checkRoomFolder
	-- is called more than once (e.g. room destroyed and recreated mid-session).

	local roomListenerRegistered = false

	local function checkRoomFolder(room: Instance?)
		if room == nil then
			return
		end
		local state = room:GetAttribute("RoomState")
		if state ~= nil then
			updateRoomState(state)
		end
		-- Only register the attribute listener once.  If the room folder is
		-- replaced the ChildAdded listener below would fire again, but the
		-- guard ensures we do not stack connections.
		if not roomListenerRegistered then
			roomListenerRegistered = true
			controllerJanitor:Add(room:GetAttributeChangedSignal("RoomState"):Connect(function()
				updateRoomState(room:GetAttribute("RoomState"))
			end))
		end
	end

	-- Check if the folder already exists (server may have built it before
	-- this controller starts).
	local existingRoom = Workspace:FindFirstChild(PartyConfig.TestRoom.SpawnFolderName)
	checkRoomFolder(existingRoom)

	-- Also watch for the folder to appear if it hasn't been built yet.
	controllerJanitor:Add(Workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == PartyConfig.TestRoom.SpawnFolderName then
			checkRoomFolder(child)
		end
	end))

	-- Cancel any pending dismiss task when the controller stops.
	controllerJanitor:Add(function()
		if dismissTask ~= nil then
			task.cancel(dismissTask)
			dismissTask = nil
		end
	end)

	started = true
	context.Logger.info("%s started", controller.Name)
end

function controller.Stop(context)
	if controllerJanitor ~= nil then
		controllerJanitor:Cleanup()
		controllerJanitor = nil
	end
	started = false
	initialized = false
	context.Logger.info("%s stopped", controller.Name)
end

return controller
