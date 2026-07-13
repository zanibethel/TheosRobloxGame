local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local controller = {
	Name = "RuntimeController",
}

local initialized = false
local started = false
local controllerJanitor = nil

function controller.Init(context)
	if initialized then
		context.Logger.warn("%s already initialized", controller.Name)
		return
	end

	initialized = true

	local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)
	controllerJanitor = Janitor.new()
	context.Janitor:Add(controllerJanitor)
end

function controller.Start(context)
	if started then
		context.Logger.warn("%s already started", controller.Name)
		return
	end

	if controllerJanitor == nil then
		error(string.format("%s cannot start because its janitor is missing", controller.Name))
	end

	local runtimeFolder = ReplicatedStorage:FindFirstChild("GameRuntime")
		or ReplicatedStorage:WaitForChild("GameRuntime", 5)
	if runtimeFolder == nil then
		error(string.format("%s could not find ReplicatedStorage.GameRuntime", controller.Name))
	end

	controllerJanitor:Add(runtimeFolder:GetAttributeChangedSignal("Phase"):Connect(function()
		context.Logger.info("Runtime phase changed to %s", tostring(runtimeFolder:GetAttribute("Phase")))
	end))

	local localPlayer = Players.LocalPlayer
	if localPlayer ~= nil then
		controllerJanitor:Add(localPlayer.CharacterAdded:Connect(function()
			context.Logger.info("Character spawned for %s", localPlayer.Name)
		end))
		controllerJanitor:Add(localPlayer.CharacterRemoving:Connect(function()
			context.Logger.info("Character removing for %s", localPlayer.Name)
		end))
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
