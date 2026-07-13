local Janitor = require(script.Parent.Janitor)
local Logger = require(script.Parent.Logger)

export type BootstrapModule = {
	Init: ((context: any) -> ())?,
	Start: ((context: any) -> ())?,
	Stop: ((context: any) -> ())?,
	Destroy: ((context: any) -> ())?,
	Cleanup: ((context: any) -> ())?,
}

export type BootstrapOptions = {
	root: Instance?,
	key: string,
	context: any,
}

type BootstrapState = "Initializing" | "Initialized"
type ResolvedModule = {
	instance: ModuleScript,
	module: BootstrapModule,
}

local bootstrapStates: { [string]: BootstrapState } = {}

local ModuleBootstrap = {}

local function getModules(root: Instance): ({ ResolvedModule }?, string?)
	local resolvedModules = {}
	local children = root:GetChildren()

	table.sort(children, function(left, right)
		return left.Name < right.Name
	end)

	for _, child in children do
		if child:IsA("ModuleScript") then
			local ok, loadedModule = pcall(require, child)
			if not ok then
				local message = string.format("Failed to require %s: %s", child:GetFullName(), tostring(loadedModule))
				Logger.warn(message)
				return nil, message
			end

			if type(loadedModule) ~= "table" then
				local message = string.format("Bootstrap module %s must return a table", child:GetFullName())
				Logger.warn(message)
				return nil, message
			end

			table.insert(resolvedModules, {
				instance = child,
				module = loadedModule :: BootstrapModule,
			})
		end
	end

	return resolvedModules, nil
end

local function cleanupModule(definition: ResolvedModule, context: any)
	local stop = definition.module.Stop or definition.module.Destroy or definition.module.Cleanup
	if stop ~= nil then
		local ok, err = pcall(stop, context)
		if not ok then
			Logger.warn("Cleanup failed for %s: %s", definition.instance:GetFullName(), tostring(err))
		end
	end
end

function ModuleBootstrap.run(options: BootstrapOptions)
	local janitor = Janitor.new()
	local key = options.key

	if type(key) ~= "string" or key == "" then
		local message = "Skipping bootstrap because the key is invalid"
		Logger.warn(message)
		return nil, message
	end

	if options.root == nil then
		local message = string.format("Skipping bootstrap for %s because the root instance is missing", key)
		Logger.warn(message)
		return nil, message
	end

	local existingState = bootstrapStates[key]
	if existingState ~= nil then
		local message = string.format("Skipped duplicate bootstrap for %s because it is already %s", key, existingState)
		Logger.warn(message)
		return nil, message
	end

	bootstrapStates[key] = "Initializing"
	janitor:Add(function()
		bootstrapStates[key] = nil
	end)

	local activeModules = {}
	local activeModuleLookup: { [ModuleScript]: boolean } = {}

	local function activate(definition: ResolvedModule)
		if activeModuleLookup[definition.instance] then
			return
		end

		activeModuleLookup[definition.instance] = true
		table.insert(activeModules, definition)
	end

	janitor:Add(function()
		for index = #activeModules, 1, -1 do
			cleanupModule(activeModules[index], options.context)
		end
	end)

	local modules, modulesError = getModules(options.root)
	if modules == nil then
		janitor:Cleanup()
		return nil, modulesError
	end

	for _, definition in modules do
		local init = definition.module.Init
		if init ~= nil then
			activate(definition)

			local ok, err = pcall(init, options.context)
			if not ok then
				local message =
					string.format("Init failed for %s: %s", definition.instance:GetFullName(), tostring(err))
				Logger.warn(message)
				janitor:Cleanup()
				return nil, message
			end
		end
	end

	for _, definition in modules do
		local start = definition.module.Start
		if start ~= nil then
			activate(definition)

			local ok, err = pcall(start, options.context)
			if not ok then
				local message =
					string.format("Start failed for %s: %s", definition.instance:GetFullName(), tostring(err))
				Logger.warn(message)
				janitor:Cleanup()
				return nil, message
			end
		end
	end

	bootstrapStates[key] = "Initialized"

	return janitor, nil
end

return table.freeze(ModuleBootstrap)
