-- PartyController
-- Client-side controller for the party system UI.
-- All party state comes from the server via RemoteEvents; this controller
-- never treats its local cache as authoritative.
--
-- UI panels
--   MainPanel   visible when the local player has no party (Create / Join)
--   JoinPanel   overlay when browsing the public party list
--   PartyPanel  visible when the local player is in a party
--
-- Data flow
--   PartyStateChanged  → updates currentPartyInfo; shows/hides PartyPanel
--   PartyListChanged   → updates currentPartyList; refreshes JoinPanel list

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

local controller = {
	Name = "PartyController",
}

local initialized = false
local started = false
local controllerJanitor = nil

-- Cached server state (read-only snapshots)
local currentPartyInfo: { [string]: any }? = nil
local currentPartyList: { { [string]: any } } = {}

-- Remote handles
local partyRequestRemote = nil

-- Top-level UI references (assigned in Start after buildGui)
local screenGui: ScreenGui? = nil
local mainPanel: Frame? = nil
local joinPanel: Frame? = nil
local partyPanel: Frame? = nil

-- ---------------------------------------------------------------------------
-- Remote invocation
-- ---------------------------------------------------------------------------

local function invokeParty(operation: string, arg1: any?): (boolean, string, any?)
	if partyRequestRemote == nil then
		return false, "not_ready", nil
	end
	local ok, success, code, data = pcall(function()
		return partyRequestRemote:InvokeServer(operation, arg1)
	end)
	if not ok then
		return false, "invoke_error", nil
	end
	return success, code, data
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

local C = {
	bgDark = Color3.fromRGB(18, 18, 28),
	bgMed = Color3.fromRGB(32, 32, 50),
	bgLight = Color3.fromRGB(48, 48, 70),
	blue = Color3.fromRGB(50, 100, 200),
	green = Color3.fromRGB(40, 160, 80),
	red = Color3.fromRGB(180, 50, 50),
	orange = Color3.fromRGB(200, 120, 30),
	gray = Color3.fromRGB(60, 60, 80),
	textMain = Color3.fromRGB(220, 220, 240),
	textDim = Color3.fromRGB(140, 140, 160),
	textReady = Color3.fromRGB(80, 210, 100),
	textNotReady = Color3.fromRGB(200, 80, 80),
	yellow = Color3.fromRGB(255, 220, 60),
}

local function corner(parent: Instance, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = parent
end

local function listLayout(parent: Instance, padding: number?)
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, padding or 2)
	l.Parent = parent
end

local function mkFrame(parent: Instance?, name: string, size: UDim2, pos: UDim2, color: Color3?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = pos
	f.BackgroundColor3 = color or C.bgDark
	f.BorderSizePixel = 0
	if parent ~= nil then
		f.Parent = parent
	end
	return f
end

local function mkLabel(
	parent: Instance?,
	name: string,
	text: string,
	size: UDim2,
	pos: UDim2,
	textSize: number?,
	color: Color3?,
	font: Enum.Font?,
	xAlign: Enum.TextXAlignment?
): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Size = size
	l.Position = pos
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = color or C.textMain
	l.TextSize = textSize or 14
	l.Font = font or Enum.Font.Gotham
	l.TextXAlignment = xAlign or Enum.TextXAlignment.Left
	l.TextWrapped = true
	if parent ~= nil then
		l.Parent = parent
	end
	return l
end

local function mkButton(
	parent: Instance?,
	name: string,
	text: string,
	size: UDim2,
	pos: UDim2,
	color: Color3?
): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.Position = pos
	b.BackgroundColor3 = color or C.blue
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.TextSize = 13
	b.Font = Enum.Font.GothamBold
	b.AutoButtonColor = true
	if parent ~= nil then
		b.Parent = parent
	end
	return b
end

local function mkScroll(parent: Instance?, name: string, size: UDim2, pos: UDim2): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.Name = name
	s.Size = size
	s.Position = pos
	s.BackgroundColor3 = C.bgMed
	s.BorderSizePixel = 0
	s.ScrollBarThickness = 5
	s.CanvasSize = UDim2.new(0, 0, 0, 0)
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	if parent ~= nil then
		s.Parent = parent
	end
	return s
end

-- ---------------------------------------------------------------------------
-- UI construction
-- ---------------------------------------------------------------------------

local function buildGui(playerGui: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "PartyGui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	-- ------------------------------------------------------------------
	-- MainPanel — shown when not in a party
	-- ------------------------------------------------------------------
	local main = mkFrame(gui, "MainPanel", UDim2.new(0, 230, 0, 100), UDim2.new(0, 10, 0, 44))
	corner(main)
	mkLabel(
		main,
		"Title",
		"PARTY",
		UDim2.new(1, -12, 0, 22),
		UDim2.new(0, 8, 0, 6),
		15,
		C.textMain,
		Enum.Font.GothamBold
	)
	mkButton(main, "CreateButton", "Create Party", UDim2.new(1, -12, 0, 30), UDim2.new(0, 6, 0, 32), C.blue)
	mkButton(main, "JoinButton", "Join Party", UDim2.new(1, -12, 0, 30), UDim2.new(0, 6, 0, 65), C.gray)

	-- ------------------------------------------------------------------
	-- JoinPanel — overlay when browsing parties
	-- ------------------------------------------------------------------
	local join = mkFrame(gui, "JoinPanel", UDim2.new(0, 300, 0, 320), UDim2.new(0.5, -150, 0.5, -160))
	corner(join)
	join.Visible = false
	mkLabel(
		join,
		"Title",
		"Join a Party",
		UDim2.new(1, -12, 0, 22),
		UDim2.new(0, 8, 0, 6),
		15,
		C.textMain,
		Enum.Font.GothamBold
	)

	local joinScroll = mkScroll(join, "ListScroll", UDim2.new(1, -10, 1, -70), UDim2.new(0, 5, 0, 34))
	corner(joinScroll)
	listLayout(joinScroll, 3)

	-- Placeholder shown when list is empty
	mkLabel(
		joinScroll,
		"EmptyLabel",
		"No open parties",
		UDim2.new(1, 0, 0, 30),
		UDim2.new(0, 0, 0, 0),
		13,
		C.textDim,
		Enum.Font.Gotham,
		Enum.TextXAlignment.Center
	)

	mkButton(join, "CloseButton", "✕  Close", UDim2.new(1, -10, 0, 28), UDim2.new(0, 5, 1, -33), C.red)
	corner(join:FindFirstChild("CloseButton") :: Instance)

	-- ------------------------------------------------------------------
	-- PartyPanel — shown when in a party
	-- ------------------------------------------------------------------
	local party = mkFrame(gui, "PartyPanel", UDim2.new(0, 260, 0, 420), UDim2.new(1, -270, 0, 44))
	corner(party)
	party.Visible = false

	mkLabel(party, "PartyIdLabel", "Party: —", UDim2.new(1, -12, 0, 18), UDim2.new(0, 8, 0, 6), 12, C.textDim)
	mkLabel(party, "HostLabel", "Host: —", UDim2.new(1, -12, 0, 18), UDim2.new(0, 8, 0, 26), 12, C.textDim)
	mkLabel(
		party,
		"StateLabel",
		"Waiting",
		UDim2.new(1, -12, 0, 20),
		UDim2.new(0, 8, 0, 46),
		14,
		C.textMain,
		Enum.Font.GothamBold
	)

	-- Large countdown number (only visible during Countdown state)
	local cdLabel = mkLabel(
		party,
		"CountdownLabel",
		"",
		UDim2.new(1, 0, 0, 60),
		UDim2.new(0, 0, 0, 68),
		52,
		C.yellow,
		Enum.Font.GothamBold,
		Enum.TextXAlignment.Center
	)
	cdLabel.Visible = false

	-- Player list
	local playerScroll = mkScroll(party, "PlayerList", UDim2.new(1, -10, 0, 100), UDim2.new(0, 5, 0, 132))
	corner(playerScroll)
	listLayout(playerScroll, 2)

	-- Max-player size control (host only)
	local sizeFrame = mkFrame(party, "SizeFrame", UDim2.new(1, -10, 0, 28), UDim2.new(0, 5, 0, 238), C.bgMed)
	corner(sizeFrame)
	mkLabel(sizeFrame, "SizeTitle", "Max Players:", UDim2.new(0.45, 0, 1, 0), UDim2.new(0, 6, 0, 0), 12, C.textDim)
	mkButton(sizeFrame, "DecButton", "−", UDim2.new(0, 26, 0, 24), UDim2.new(0.45, 2, 0, 2), C.red)
	mkLabel(
		sizeFrame,
		"SizeValue",
		"6",
		UDim2.new(0, 26, 0, 24),
		UDim2.new(0.45, 30, 0, 2),
		13,
		C.textMain,
		Enum.Font.GothamBold,
		Enum.TextXAlignment.Center
	)
	mkButton(sizeFrame, "IncButton", "+", UDim2.new(0, 26, 0, 24), UDim2.new(0.45, 58, 0, 2), C.green)

	-- Ready / Leave row
	mkButton(party, "ReadyButton", "Ready", UDim2.new(0.5, -6, 0, 32), UDim2.new(0, 5, 0, 272), C.green)
	mkButton(party, "LeaveButton", "Leave", UDim2.new(0.5, -5, 0, 32), UDim2.new(0.5, 1, 0, 272), C.red)

	-- Host-only action row
	local startBtn =
		mkButton(party, "StartButton", "▶  Start Game", UDim2.new(1, -10, 0, 32), UDim2.new(0, 5, 0, 310), C.green)
	startBtn.Visible = false

	local cancelBtn = mkButton(
		party,
		"CancelButton",
		"✕  Cancel Countdown",
		UDim2.new(1, -10, 0, 32),
		UDim2.new(0, 5, 0, 310),
		C.orange
	)
	cancelBtn.Visible = false

	return gui
end

-- ---------------------------------------------------------------------------
-- Panel visibility management
-- ---------------------------------------------------------------------------

local function showMain()
	if mainPanel ~= nil then
		mainPanel.Visible = currentPartyInfo == nil
	end
end

local function showParty()
	if partyPanel ~= nil then
		partyPanel.Visible = currentPartyInfo ~= nil
	end
	showMain()
end

-- ---------------------------------------------------------------------------
-- Join panel population
-- ---------------------------------------------------------------------------

local function refreshJoinList()
	if joinPanel == nil then
		return
	end
	local scroll = joinPanel:FindFirstChild("ListScroll") :: ScrollingFrame?
	if scroll == nil then
		return
	end

	-- Clear existing dynamic entries (keep EmptyLabel)
	for _, child in scroll:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local emptyLabel = scroll:FindFirstChild("EmptyLabel")
	local count = 0

	for _, entry in currentPartyList do
		count += 1
		local row =
			mkFrame(scroll, "PartyRow_" .. tostring(entry.partyId), UDim2.new(1, -4, 0, 40), UDim2.new(0, 2, 0, 0))
		row.BackgroundColor3 = C.bgLight
		corner(row)
		row.LayoutOrder = count

		mkLabel(
			row,
			"IdLabel",
			string.format("[%s]  %s", tostring(entry.partyId), tostring(entry.hostName)),
			UDim2.new(1, -72, 0, 20),
			UDim2.new(0, 6, 0, 2),
			12,
			C.textMain
		)
		mkLabel(
			row,
			"CountLabel",
			string.format("%d / %d players", entry.playerCount, entry.maxPlayers),
			UDim2.new(1, -72, 0, 16),
			UDim2.new(0, 6, 0, 22),
			11,
			C.textDim
		)

		local joinBtn = mkButton(row, "JoinBtn", "Join", UDim2.new(0, 56, 0, 26), UDim2.new(1, -62, 0, 7), C.blue)
		corner(joinBtn)
		local capturedId = tostring(entry.partyId)
		joinBtn.Activated:Connect(function()
			invokeParty("join", capturedId)
		end)
	end

	if emptyLabel ~= nil then
		emptyLabel.Visible = count == 0
	end
end

-- ---------------------------------------------------------------------------
-- Party panel update
-- ---------------------------------------------------------------------------

local function updatePartyPanel()
	if partyPanel == nil then
		return
	end

	local info = currentPartyInfo
	if info == nil then
		partyPanel.Visible = false
		return
	end

	partyPanel.Visible = true

	local localPlayer = Players.LocalPlayer
	local localUserId = localPlayer ~= nil and localPlayer.UserId or -1
	local isHost = tostring(info.hostName) == (localPlayer ~= nil and localPlayer.Name or "")
	local state = tostring(info.state)
	local isCountdown = state == "Countdown"
	local isInGame = state == "InGame" or state == "Launching"

	-- Labels
	local function setText(name: string, text: string)
		local lbl = partyPanel:FindFirstChild(name) :: TextLabel?
		if lbl ~= nil then
			lbl.Text = text
		end
	end

	setText("PartyIdLabel", "Party: " .. tostring(info.partyId))
	setText("HostLabel", "Host: " .. tostring(info.hostName))
	setText("StateLabel", state)

	-- Countdown display
	local cdLabel = partyPanel:FindFirstChild("CountdownLabel") :: TextLabel?
	if cdLabel ~= nil then
		if isCountdown and info.countdownRemaining ~= nil then
			cdLabel.Visible = true
			cdLabel.Text = tostring(info.countdownRemaining)
		else
			cdLabel.Visible = false
			cdLabel.Text = ""
		end
	end

	-- Player list
	local playerScroll = partyPanel:FindFirstChild("PlayerList") :: ScrollingFrame?
	if playerScroll ~= nil then
		for _, child in playerScroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local players = info.players
		if type(players) == "table" then
			for index, pInfo in players do
				local row = mkFrame(playerScroll, "PlayerRow", UDim2.new(1, -4, 0, 28), UDim2.new(0, 2, 0, 0))
				row.BackgroundColor3 = C.bgLight
				corner(row)
				row.LayoutOrder = index

				local displayReady = pInfo.isReady and "●" or "○"
				local readyColor = pInfo.isReady and C.textReady or C.textNotReady
				mkLabel(
					row,
					"ReadyDot",
					displayReady,
					UDim2.new(0, 18, 1, 0),
					UDim2.new(0, 4, 0, 0),
					14,
					readyColor,
					Enum.Font.GothamBold
				)

				local nameText = tostring(pInfo.displayName) .. (pInfo.isHost and "  👑" or "")
				mkLabel(row, "NameLabel", nameText, UDim2.new(1, -70, 1, 0), UDim2.new(0, 24, 0, 0), 12, C.textMain)

				-- Kick button: host only, not on the host's own row
				if isHost and pInfo.userId ~= localUserId then
					local kickBtn =
						mkButton(row, "KickBtn", "Kick", UDim2.new(0, 40, 0, 22), UDim2.new(1, -44, 0, 3), C.red)
					corner(kickBtn)
					local capturedId = pInfo.userId
					kickBtn.Activated:Connect(function()
						invokeParty("kick", capturedId)
					end)
				end
			end
		end
	end

	-- Size control
	local sizeFrame = partyPanel:FindFirstChild("SizeFrame") :: Frame?
	if sizeFrame ~= nil then
		sizeFrame.Visible = isHost and not isCountdown and not isInGame
		local sizeVal = sizeFrame:FindFirstChild("SizeValue") :: TextLabel?
		if sizeVal ~= nil then
			sizeVal.Text = tostring(info.maxPlayers)
		end
	end

	-- Ready / Leave buttons
	local readyBtn = partyPanel:FindFirstChild("ReadyButton") :: TextButton?
	if readyBtn ~= nil then
		readyBtn.Visible = not isInGame
		readyBtn.Active = not isCountdown and not isInGame

		-- Reflect own ready state
		local amReady = false
		local players2 = info.players
		if type(players2) == "table" then
			for _, pInfo in players2 do
				if pInfo.userId == localUserId then
					amReady = pInfo.isReady == true
					break
				end
			end
		end
		readyBtn.Text = amReady and "Unready" or "Ready"
		readyBtn.BackgroundColor3 = amReady and C.orange or C.green
	end

	local leaveBtn = partyPanel:FindFirstChild("LeaveButton") :: TextButton?
	if leaveBtn ~= nil then
		leaveBtn.Visible = not isInGame
	end

	-- Host-only start / cancel
	local startBtn = partyPanel:FindFirstChild("StartButton") :: TextButton?
	local cancelBtn = partyPanel:FindFirstChild("CancelButton") :: TextButton?

	if startBtn ~= nil then
		startBtn.Visible = isHost and not isCountdown and not isInGame
		-- Dim if conditions not met
		local canStart = isHost and not isCountdown and not isInGame
		if canStart then
			local allReady = true
			local players3 = info.players
			if type(players3) == "table" then
				for _, pInfo in players3 do
					if not pInfo.isReady then
						allReady = false
						break
					end
				end
				canStart = allReady and #players3 >= 1
			end
		end
		startBtn.BackgroundColor3 = canStart and C.green or C.gray
	end

	if cancelBtn ~= nil then
		cancelBtn.Visible = isHost and isCountdown
	end
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

	-- Build UI
	local gui = buildGui(playerGui)
	screenGui = gui
	controllerJanitor:Add(gui)

	mainPanel = gui:FindFirstChild("MainPanel") :: Frame?
	joinPanel = gui:FindFirstChild("JoinPanel") :: Frame?
	partyPanel = gui:FindFirstChild("PartyPanel") :: Frame?

	-- Fetch remote handles
	partyRequestRemote = Remotes.get(Remotes.Names.PartyRequest)
	local partyStateChangedRemote = Remotes.get(Remotes.Names.PartyStateChanged)
	local partyListChangedRemote = Remotes.get(Remotes.Names.PartyListChanged)

	-- ------------------------------------------------------------------
	-- Wire MainPanel buttons
	-- ------------------------------------------------------------------
	if mainPanel ~= nil then
		local createBtn = mainPanel:FindFirstChild("CreateButton") :: TextButton?
		if createBtn ~= nil then
			controllerJanitor:Add(createBtn.Activated:Connect(function()
				invokeParty("create")
			end))
		end

		local joinBtn = mainPanel:FindFirstChild("JoinButton") :: TextButton?
		if joinBtn ~= nil then
			controllerJanitor:Add(joinBtn.Activated:Connect(function()
				if joinPanel ~= nil then
					refreshJoinList()
					joinPanel.Visible = true
				end
			end))
		end
	end

	-- ------------------------------------------------------------------
	-- Wire JoinPanel close button
	-- ------------------------------------------------------------------
	if joinPanel ~= nil then
		local closeBtn = joinPanel:FindFirstChild("CloseButton") :: TextButton?
		if closeBtn ~= nil then
			controllerJanitor:Add(closeBtn.Activated:Connect(function()
				if joinPanel ~= nil then
					joinPanel.Visible = false
				end
			end))
		end
	end

	-- ------------------------------------------------------------------
	-- Wire PartyPanel buttons
	-- ------------------------------------------------------------------
	if partyPanel ~= nil then
		local readyBtn = partyPanel:FindFirstChild("ReadyButton") :: TextButton?
		if readyBtn ~= nil then
			controllerJanitor:Add(readyBtn.Activated:Connect(function()
				local info = currentPartyInfo
				if info == nil then
					return
				end
				local amReady = false
				local players = info.players
				if type(players) == "table" then
					for _, pInfo in players do
						if pInfo.userId == localPlayer.UserId then
							amReady = pInfo.isReady == true
							break
						end
					end
				end
				if amReady then
					invokeParty("unready")
				else
					invokeParty("ready")
				end
			end))
		end

		local leaveBtn = partyPanel:FindFirstChild("LeaveButton") :: TextButton?
		if leaveBtn ~= nil then
			controllerJanitor:Add(leaveBtn.Activated:Connect(function()
				invokeParty("leave")
			end))
		end

		local startBtn = partyPanel:FindFirstChild("StartButton") :: TextButton?
		if startBtn ~= nil then
			controllerJanitor:Add(startBtn.Activated:Connect(function()
				invokeParty("start")
			end))
		end

		local cancelBtn = partyPanel:FindFirstChild("CancelButton") :: TextButton?
		if cancelBtn ~= nil then
			controllerJanitor:Add(cancelBtn.Activated:Connect(function()
				invokeParty("cancel")
			end))
		end

		-- Size controls
		local sizeFrame = partyPanel:FindFirstChild("SizeFrame") :: Frame?
		if sizeFrame ~= nil then
			local decBtn = sizeFrame:FindFirstChild("DecButton") :: TextButton?
			if decBtn ~= nil then
				controllerJanitor:Add(decBtn.Activated:Connect(function()
					local info = currentPartyInfo
					if info ~= nil then
						invokeParty("setSize", (info.maxPlayers :: number) - 1)
					end
				end))
			end

			local incBtn = sizeFrame:FindFirstChild("IncButton") :: TextButton?
			if incBtn ~= nil then
				controllerJanitor:Add(incBtn.Activated:Connect(function()
					local info = currentPartyInfo
					if info ~= nil then
						invokeParty("setSize", (info.maxPlayers :: number) + 1)
					end
				end))
			end
		end
	end

	-- ------------------------------------------------------------------
	-- Remote listeners
	-- ------------------------------------------------------------------

	controllerJanitor:Add(partyStateChangedRemote.OnClientEvent:Connect(function(partyInfo: any)
		currentPartyInfo = if type(partyInfo) == "table" then partyInfo else nil
		updatePartyPanel()
		showParty()

		-- Auto-close join panel when accepted into a party
		if currentPartyInfo ~= nil and joinPanel ~= nil then
			joinPanel.Visible = false
		end
	end))

	controllerJanitor:Add(partyListChangedRemote.OnClientEvent:Connect(function(list: any)
		currentPartyList = if type(list) == "table" then list else {}
		if joinPanel ~= nil and joinPanel.Visible then
			refreshJoinList()
		end
	end))

	-- Initial state
	showMain()

	started = true
	context.Logger.info("%s started", controller.Name)
end

function controller.Stop(context)
	if controllerJanitor ~= nil then
		controllerJanitor:Cleanup()
		controllerJanitor = nil
	end

	screenGui = nil
	mainPanel = nil
	joinPanel = nil
	partyPanel = nil
	partyRequestRemote = nil
	currentPartyInfo = nil
	currentPartyList = {}
	started = false
	initialized = false
	context.Logger.info("%s stopped", controller.Name)
end

return controller
