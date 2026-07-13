local Janitor = {}
Janitor.__index = Janitor

export type CleanupTask =
	RBXScriptConnection
	| Instance
	| (() -> ())
	| { Destroy: (any) -> () }
	| { Cleanup: (any) -> () }
	| { Disconnect: (any) -> () }
export type Janitor = typeof(setmetatable(
	{} :: {
		_tasks: { CleanupTask },
		_cleaned: boolean,
	},
	Janitor
))

local function cleanupTask(task: CleanupTask)
	local taskType = typeof(task)

	if taskType == "RBXScriptConnection" then
		(task :: RBXScriptConnection):Disconnect()
	elseif taskType == "Instance" then
		(task :: Instance):Destroy()
	elseif taskType == "function" then
		(task :: () -> ())()
	elseif taskType == "table" then
		local object = task :: any
		if type(object.Cleanup) == "function" then
			object:Cleanup()
		elseif type(object.Destroy) == "function" then
			object:Destroy()
		elseif type(object.Disconnect) == "function" then
			object:Disconnect()
		end
	end
end

function Janitor.new(): Janitor
	return setmetatable({
		_tasks = {},
		_cleaned = false,
	}, Janitor)
end

function Janitor.Add(self: Janitor, task: CleanupTask): CleanupTask
	if self._cleaned then
		cleanupTask(task)
		return task
	end

	table.insert(self._tasks, task)
	return task
end

function Janitor.Cleanup(self: Janitor)
	if self._cleaned then
		return
	end

	self._cleaned = true

	for index = #self._tasks, 1, -1 do
		local task = self._tasks[index]
		local ok, err = pcall(cleanupTask, task)
		if not ok then
			warn(string.format("[TheosRobloxGame] Janitor cleanup failed: %s", tostring(err)))
		end

		self._tasks[index] = nil :: any
	end
end

return Janitor
