local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local service = {
	Name = "RuntimeStateService",
}

local initialized = false
local started = false
local serviceJanitor = nil
local runtimeFolder = nil

local function refreshPlayerCount()
	if runtimeFolder == nil then
		return
	end

	runtimeFolder:SetAttribute("PlayerCount", #Players:GetPlayers())
end

function service.Init(context)
	if initialized then
		context.Logger.warn("%s already initialized", service.Name)
		return
	end

	initialized = true

	local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)
	serviceJanitor = Janitor.new()
	context.Janitor:Add(serviceJanitor)

	runtimeFolder = ReplicatedStorage:FindFirstChild("GameRuntime")
	if runtimeFolder == nil then
		runtimeFolder = Instance.new("Folder")
		runtimeFolder.Name = "GameRuntime"
		runtimeFolder.Parent = ReplicatedStorage
		serviceJanitor:Add(runtimeFolder)
	end

	runtimeFolder:SetAttribute("GameTitle", context.Config.Game.Title)
	runtimeFolder:SetAttribute("MaxPlayers", context.Config.Game.MaxPlayers)
	runtimeFolder:SetAttribute("CurrentRoomId", context.Config.Game.StartingRoomId)
	runtimeFolder:SetAttribute("Phase", "Bootstrap")
end

function service.Start(context)
	if started then
		context.Logger.warn("%s already started", service.Name)
		return
	end

	if serviceJanitor == nil or runtimeFolder == nil then
		error(string.format("%s cannot start because runtime state is unavailable", service.Name))
	end

	serviceJanitor:Add(Players.PlayerAdded:Connect(refreshPlayerCount))
	serviceJanitor:Add(Players.PlayerRemoving:Connect(refreshPlayerCount))

	refreshPlayerCount()
	runtimeFolder:SetAttribute("Phase", "RoomReady")
	started = true
	context.Logger.info("%s started", service.Name)
end

function service.Stop(context)
	if runtimeFolder ~= nil then
		runtimeFolder:SetAttribute("Phase", "RoomResetting")
	end

	if serviceJanitor ~= nil then
		serviceJanitor:Cleanup()
		serviceJanitor = nil
	end

	started = false
	runtimeFolder = nil
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
