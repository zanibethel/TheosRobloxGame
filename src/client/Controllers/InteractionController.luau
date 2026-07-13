-- InteractionController
-- Client-side controller that manages ProximityPrompts for tagged interactables
-- and dispatches Begin / Cancel / Instant operations to InteractionService.
--
-- Interaction modes (read from InteractableMode attribute on the tagged instance)
--   "Instant"  ProximityPrompt.Triggered → InvokeServer("instant", id)
--   "Hold"     PromptButtonHoldBegan     → InvokeServer("begin", id)
--              PromptButtonHoldEnded     → InvokeServer("cancel", id, sessionId) if active
--              Server owns completion; client only shows ProximityPrompt progress.
--
-- Tagged instance attribute contract
--   InteractableId      string  — matches a server-registered definition id
--   InteractableMode    string  — "Instant" (default) or "Hold"
--   InteractableAction  string  — prompt ActionText
--   InteractableDisplay string? — prompt ObjectText (falls back to instance.Name)
--   InteractableHoldDuration number? — client ProximityPrompt hold duration (seconds)
--
-- State changes from server (InteractionStateChanged event) update prompt.Enabled.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local INTERACTABLE_TAG = "Interactable"
local DEFAULT_HOLD_DURATION = 3

local controller = {
	Name = "InteractionController",
}

local initialized = false
local started = false
local controllerJanitor = nil

local function getAttachPart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance :: BasePart
	elseif instance:IsA("Model") then
		return (instance :: Model).PrimaryPart
	end
	return nil
end

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
		error(string.format("%s cannot start: janitor is missing", controller.Name))
	end

	local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)
	local requestRemote = Remotes.get(Remotes.Names.InteractionRequest)
	local stateChangedRemote = Remotes.get(Remotes.Names.InteractionStateChanged)

	-- interactableId → ProximityPrompt (for state-change reactions)
	local promptByTarget: { [string]: ProximityPrompt } = {}

	-- Per-instance janitors and per-instance session tracking
	local instanceJanitors: { [Instance]: any } = {}

	-- -----------------------------------------------------------------------
	-- Instance setup / teardown
	-- -----------------------------------------------------------------------

	local function setupInstance(instance: Instance)
		if instanceJanitors[instance] ~= nil then
			return -- already set up; avoid duplicates
		end

		local interactableId = instance:GetAttribute("InteractableId")
		if type(interactableId) ~= "string" or interactableId == "" then
			context.Logger.warn(
				"%s: skipping %s — missing InteractableId attribute",
				controller.Name,
				instance:GetFullName()
			)
			return
		end

		local attachPart = getAttachPart(instance)
		if attachPart == nil then
			context.Logger.warn(
				"%s: skipping %s — no BasePart or PrimaryPart for prompt attachment",
				controller.Name,
				instance:GetFullName()
			)
			return
		end

		local mode = tostring(instance:GetAttribute("InteractableMode") or "Instant")
		local holdDuration = instance:GetAttribute("InteractableHoldDuration")
		if type(holdDuration) ~= "number" then
			holdDuration = if mode == "Hold"
				then DEFAULT_HOLD_DURATION
				else context.Config.Interaction.PromptHoldDurationSeconds
		end

		local instanceJanitor = Janitor.new()
		instanceJanitors[instance] = instanceJanitor

		-- Build ProximityPrompt
		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = tostring(instance:GetAttribute("InteractableDisplay") or instance.Name)
		prompt.ActionText = tostring(instance:GetAttribute("InteractableAction") or "Interact")
		prompt.MaxActivationDistance = context.Config.Interaction.MaxDistance
		prompt.HoldDuration = holdDuration :: number
		prompt.RequiresLineOfSight = false
		prompt.Parent = attachPart
		instanceJanitor:Add(prompt)

		promptByTarget[interactableId] = prompt
		instanceJanitor:Add(function()
			if promptByTarget[interactableId] == prompt then
				promptByTarget[interactableId] = nil
			end
		end)

		-- -----------------------------------------------------------------------
		-- Mode-specific wiring
		-- -----------------------------------------------------------------------

		if mode == "Instant" then
			instanceJanitor:Add(prompt.Triggered:Connect(function(_player: Player)
				local ok, success, code = pcall(function()
					return requestRemote:InvokeServer("instant", interactableId, nil)
				end)
				if not ok then
					-- InvokeServer threw (e.g. disconnect); silently ignore
					return
				end
				if not success then
					context.Logger.warn(
						"%s: instant rejected for %s: %s",
						controller.Name,
						interactableId,
						tostring(code)
					)
				end
			end))
		elseif mode == "Hold" then
			-- Per-instance hold-session state (safe with closures)
			local activeSessionId: string? = nil
			local waitingForBeginResponse = false
			local cancelAfterResponse = false

			instanceJanitor:Add(prompt.PromptButtonHoldBegan:Connect(function(_player: Player)
				waitingForBeginResponse = true
				cancelAfterResponse = false

				local ok, success, code, returnedSessionId = pcall(function()
					return requestRemote:InvokeServer("begin", interactableId, nil)
				end)

				waitingForBeginResponse = false

				if not ok then
					return
				end

				if not success then
					context.Logger.warn(
						"%s: begin rejected for %s: %s",
						controller.Name,
						interactableId,
						tostring(code)
					)
					return
				end

				-- If the player released the button before we got a response,
				-- cancel the session immediately rather than letting it run.
				if cancelAfterResponse then
					cancelAfterResponse = false
					if type(returnedSessionId) == "string" then
						pcall(function()
							requestRemote:InvokeServer("cancel", interactableId, returnedSessionId)
						end)
					end
				else
					activeSessionId = returnedSessionId :: string?
				end
			end))

			instanceJanitor:Add(prompt.PromptButtonHoldEnded:Connect(function(_player: Player)
				if waitingForBeginResponse then
					-- Response hasn't arrived yet; flag to cancel on arrival
					cancelAfterResponse = true
					return
				end
				if activeSessionId ~= nil then
					local sessionId = activeSessionId
					activeSessionId = nil
					pcall(function()
						requestRemote:InvokeServer("cancel", interactableId, sessionId)
					end)
				end
			end))

			-- Triggered fires when the full hold duration elapses on the client.
			-- The server owns completion; we just clear local session tracking here.
			instanceJanitor:Add(prompt.Triggered:Connect(function(_player: Player)
				activeSessionId = nil
			end))

			-- Cancel on character death
			local localPlayer = Players.LocalPlayer
			if localPlayer ~= nil then
				instanceJanitor:Add(localPlayer.CharacterRemoving:Connect(function()
					cancelAfterResponse = false
					if activeSessionId ~= nil then
						local sessionId = activeSessionId
						activeSessionId = nil
						pcall(function()
							requestRemote:InvokeServer("cancel", interactableId, sessionId)
						end)
					end
				end))
			end
		end

		-- React to attribute changes (e.g. InteractableId reassigned in Studio)
		instanceJanitor:Add(instance:GetAttributeChangedSignal("InteractableId"):Connect(function()
			-- Tear down and rebuild so the new ID is reflected
			local j = instanceJanitors[instance]
			if j ~= nil then
				j:Cleanup()
				instanceJanitors[instance] = nil
			end
			setupInstance(instance)
		end))

		instanceJanitor:Add(instance:GetAttributeChangedSignal("InteractableMode"):Connect(function()
			local j = instanceJanitors[instance]
			if j ~= nil then
				j:Cleanup()
				instanceJanitors[instance] = nil
			end
			setupInstance(instance)
		end))
	end

	local function teardownInstance(instance: Instance)
		local j = instanceJanitors[instance]
		if j ~= nil then
			j:Cleanup()
			instanceJanitors[instance] = nil
		end
	end

	-- -----------------------------------------------------------------------
	-- CollectionService watching
	-- -----------------------------------------------------------------------

	for _, instance in CollectionService:GetTagged(INTERACTABLE_TAG) do
		setupInstance(instance)
	end

	controllerJanitor:Add(CollectionService:GetInstanceAddedSignal(INTERACTABLE_TAG):Connect(function(instance)
		setupInstance(instance)
	end))

	controllerJanitor:Add(CollectionService:GetInstanceRemovedSignal(INTERACTABLE_TAG):Connect(function(instance)
		teardownInstance(instance)
	end))

	-- -----------------------------------------------------------------------
	-- Server state-change reactions
	-- -----------------------------------------------------------------------

	controllerJanitor:Add(stateChangedRemote.OnClientEvent:Connect(function(interactableId: any, state: any)
		local prompt = promptByTarget[tostring(interactableId)]
		if prompt == nil then
			return
		end
		local stateStr = tostring(state)
		if stateStr == "available" then
			prompt.Enabled = true
		elseif stateStr == "locked" or stateStr == "cooldown" or stateStr == "disabled" then
			prompt.Enabled = false
		end
	end))

	-- -----------------------------------------------------------------------
	-- Full cleanup of all instance janitors on controller shutdown
	-- -----------------------------------------------------------------------

	controllerJanitor:Add(function()
		for _, j in pairs(instanceJanitors) do
			j:Cleanup()
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
