local Logger = {}

local loggingEnabled = true

local function render(message: string, ...: any): string
	local success, formatted = pcall(string.format, message, ...)
	if success then
		return formatted
	end

	return message
end

function Logger.configure(enabled: boolean)
	loggingEnabled = enabled
end

function Logger.info(message: string, ...: any)
	if not loggingEnabled then
		return
	end

	print(string.format("[TheosRobloxGame] %s", render(message, ...)))
end

function Logger.warn(message: string, ...: any)
	warn(string.format("[TheosRobloxGame] %s", render(message, ...)))
end

function Logger.error(message: string, ...: any)
	error(string.format("[TheosRobloxGame] %s", render(message, ...)))
end

return table.freeze(Logger)
