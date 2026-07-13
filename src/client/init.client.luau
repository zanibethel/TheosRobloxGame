local STATE_ATTRIBUTE = "BootstrapState"
local BootstrapState = {
	NotStarted = "NotStarted",
	Initializing = "Initializing",
	Initialized = "Initialized",
	Failed = "Failed",
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local runtimeJanitor = nil

local function getChild(parent: Instance, childName: string): Instance?
	return parent:FindFirstChild(childName) or parent:WaitForChild(childName, 5)
end

local function setState(state: string)
	script:SetAttribute(STATE_ATTRIBUTE, state)
end

local function cleanupRuntime()
	if runtimeJanitor ~= nil then
		runtimeJanitor:Cleanup()
		runtimeJanitor = nil
	end
end

local function failBootstrap(message: string)
	cleanupRuntime()
	setState(BootstrapState.Failed)
	warn(string.format("[TheosRobloxGame] %s", message))
end

if script:GetAttribute(STATE_ATTRIBUTE) == nil then
	setState(BootstrapState.NotStarted)
end

local currentState = script:GetAttribute(STATE_ATTRIBUTE)
if currentState == BootstrapState.Initialized or currentState == BootstrapState.Initializing then
	return
end

cleanupRuntime()
setState(BootstrapState.Initializing)

local sharedFolder = getChild(ReplicatedStorage, "Shared")
if sharedFolder == nil then
	failBootstrap("Shared folder missing; client bootstrap aborted")
	return
end

local configFolder = getChild(sharedFolder, "Config")
local utilFolder = getChild(sharedFolder, "Util")
local gameConfigModule = configFolder and getChild(configFolder, "GameConfig")
local loggerModule = utilFolder and getChild(utilFolder, "Logger")
local janitorModule = utilFolder and getChild(utilFolder, "Janitor")
local moduleBootstrapModule = utilFolder and getChild(utilFolder, "ModuleBootstrap")
local controllersFolder = script:FindFirstChild("Controllers") or script:WaitForChild("Controllers", 5)

if
	not configFolder
	or not utilFolder
	or not gameConfigModule
	or not loggerModule
	or not janitorModule
	or not moduleBootstrapModule
	or not controllersFolder
then
	failBootstrap("Shared bootstrap dependencies are incomplete; client bootstrap aborted")
	return
end

local function safeRequire(moduleScript: ModuleScript, label: string)
	local ok, result = pcall(require, moduleScript)
	if not ok then
		return nil, string.format("Failed to require %s: %s", label, tostring(result))
	end

	return result, nil
end

local GameConfig, gameConfigError = safeRequire(gameConfigModule, gameConfigModule:GetFullName())
if GameConfig == nil then
	failBootstrap(gameConfigError)
	return
end

local Logger, loggerError = safeRequire(loggerModule, loggerModule:GetFullName())
if Logger == nil then
	failBootstrap(loggerError)
	return
end

local Janitor, janitorError = safeRequire(janitorModule, janitorModule:GetFullName())
if Janitor == nil then
	failBootstrap(janitorError)
	return
end

local ModuleBootstrap, moduleBootstrapError = safeRequire(moduleBootstrapModule, moduleBootstrapModule:GetFullName())
if ModuleBootstrap == nil then
	failBootstrap(moduleBootstrapError)
	return
end

local nextRuntimeJanitor = nil
local ok, bootstrapError = pcall(function()
	Logger.configure(GameConfig.Debug.LoggingEnabled)

	nextRuntimeJanitor = Janitor.new()
	local context = {
		Config = GameConfig,
		Janitor = nextRuntimeJanitor,
		Logger = Logger,
		RunContext = "Client",
	}

	local moduleJanitor, moduleError = ModuleBootstrap.run({
		root = controllersFolder,
		key = "ClientControllers",
		context = context,
	})
	if moduleJanitor == nil then
		error(tostring(moduleError))
	end

	nextRuntimeJanitor:Add(moduleJanitor)
	runtimeJanitor = nextRuntimeJanitor
end)

if not ok then
	if nextRuntimeJanitor ~= nil then
		nextRuntimeJanitor:Cleanup()
	end

	runtimeJanitor = nil
	setState(BootstrapState.Failed)
	Logger.warn("Client bootstrap aborted: %s", tostring(bootstrapError))
	return
end

setState(BootstrapState.Initialized)
Logger.info("Client bootstrap finished")
