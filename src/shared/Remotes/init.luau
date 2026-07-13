-- Remotes
-- Shared accessor for interaction RemoteFunction and RemoteEvent instances.
-- Server must call Remotes.setup() once during Init to create the instances.
-- Clients call Remotes.get(name) which waits up to WAIT_TIMEOUT seconds.
--
-- Remote protocol
-- ---------------
-- InteractionRequest  (RemoteFunction)
--   Client → Server:  InvokeServer(operation, interactableId, sessionId?)
--     operation    : "instant" | "begin" | "cancel"
--     interactableId: string
--     sessionId    : string? (required only for "cancel")
--   Server → Client:  returns (success: boolean, code: string, sessionId: string?)
--     success   : whether the operation was accepted
--     code      : InteractionResultCode (non-sensitive)
--     sessionId : opaque server-generated ID returned on successful "begin"
--
-- InteractionStateChanged  (RemoteEvent)
--   Server → Client:  FireClient(interactableId, state)
--     interactableId: string
--     state         : "available" | "locked" | "cooldown" | "disabled"
--   Used to enable/disable client prompts without polling.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "Remotes"
local WAIT_TIMEOUT = 10

local Names = {
	InteractionRequest = "InteractionRequest",
	InteractionStateChanged = "InteractionStateChanged",
}

local REMOTE_CLASSES: { [string]: string } = {
	[Names.InteractionRequest] = "RemoteFunction",
	[Names.InteractionStateChanged] = "RemoteEvent",
}

local Remotes = {}
Remotes.Names = Names

local function getFolder(): Instance?
	if IS_SERVER then
		return ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	else
		return ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
	end
end

-- Creates the Remotes folder and all remote instances under ReplicatedStorage.
-- Must be called once on the server before clients connect.
function Remotes.setup()
	assert(IS_SERVER, "Remotes.setup() must only be called on the server")

	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end

	for name, className in REMOTE_CLASSES do
		if folder:FindFirstChild(name) == nil then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = folder
		end
	end
end

-- Returns the named remote instance. Errors if not found within the timeout.
function Remotes.get(name: string): any
	local folder = getFolder()
	if folder == nil then
		error(string.format("[Remotes] Remotes folder not found when looking for: %s", name))
	end

	local remote
	if IS_SERVER then
		remote = folder:FindFirstChild(name)
	else
		remote = folder:WaitForChild(name, WAIT_TIMEOUT)
	end

	if remote == nil then
		error(string.format("[Remotes] Remote not found: %s", name))
	end

	return remote
end

return table.freeze(Remotes)
