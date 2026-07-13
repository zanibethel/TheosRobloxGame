-- LobbyController
-- Client-side controller for the lobby phase.
-- Displays a minimal status bar showing the current game phase as reported
-- by ReplicatedStorage.GameRuntime.  React to future phase changes here
-- (e.g. hide/show HUD sections, play lobby music, fade transitions).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

local controller = {
	Name = "LobbyController",
}

local initialized = false
local started = false
local controllerJanitor = nil

-- ---------------------------------------------------------------------------
-- UI construction
-- ---------------------------------------------------------------------------

local function buildStatusBar(playerGui: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "LobbyStatusGui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local bar = Instance.new("Frame")
	bar.Name = "StatusBar"
	bar.Size = UDim2.new(1, 0, 0, 36)
	bar.Position = UDim2.new(0, 0, 0, 0)
	bar.BackgroundColor3 = Color3.fromRGB(12, 12, 20)
	bar.BorderSizePixel = 0
	bar.Parent = gui

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleLabel"
	titleLabel.Size = UDim2.new(0.5, 0, 1, 0)
	titleLabel.Position = UDim2.new(0, 10, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "Theo's Game"
	titleLabel.TextColor3 = Color3.fromRGB(220, 220, 240)
	titleLabel.TextSize = 15
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = bar

	local phaseLabel = Instance.new("TextLabel")
	phaseLabel.Name = "PhaseLabel"
	phaseLabel.Size = UDim2.new(0.5, -10, 1, 0)
	phaseLabel.Position = UDim2.new(0.5, 0, 0, 0)
	phaseLabel.BackgroundTransparency = 1
	phaseLabel.Text = "Phase: —"
	phaseLabel.TextColor3 = Color3.fromRGB(140, 140, 160)
	phaseLabel.TextSize = 13
	phaseLabel.Font = Enum.Font.Gotham
	phaseLabel.TextXAlignment = Enum.TextXAlignment.Right
	phaseLabel.Parent = bar

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

	local statusGui = buildStatusBar(playerGui)
	controllerJanitor:Add(statusGui)

	local phaseLabel = statusGui:FindFirstChild("StatusBar") and statusGui.StatusBar:FindFirstChild("PhaseLabel")

	local runtimeFolder = ReplicatedStorage:FindFirstChild("GameRuntime")
		or ReplicatedStorage:WaitForChild("GameRuntime", 10)

	if runtimeFolder ~= nil and phaseLabel ~= nil then
		local function updatePhase()
			local phase = tostring(runtimeFolder:GetAttribute("Phase") or "—")
			phaseLabel.Text = "Phase: " .. phase
		end

		updatePhase()
		controllerJanitor:Add(runtimeFolder:GetAttributeChangedSignal("Phase"):Connect(updatePhase))
	end

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
