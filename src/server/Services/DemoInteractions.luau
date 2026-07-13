-- DemoInteractions
-- Minimal demonstration of the interaction framework.
-- Registers two interactables that update server-owned attributes only.
-- No inventory, rewards, keys, or progression are implemented here.
--
-- Studio setup required to exercise the prompts:
--   1. Create a BasePart in Workspace named "DemoButton".
--      Tag it "Interactable" and add attributes:
--        InteractableId      = "demo_instant_button"
--        InteractableMode    = "Instant"
--        InteractableAction  = "Press"
--        InteractableDisplay = "Button"
--
--   2. Create a BasePart in Workspace named "DemoLever".
--      Tag it "Interactable" and add attributes:
--        InteractableId        = "demo_hold_lever"
--        InteractableMode      = "Hold"
--        InteractableAction    = "Pull"
--        InteractableDisplay   = "Lever"
--        InteractableHoldDuration = 3
--
--   3. Play the game.  Inspect ReplicatedStorage.DemoInteractionState attributes
--      to observe the server-side state changes.
--
-- Demo interactable IDs
--   demo_instant_button  Instant, shared (no exclusive lock), 2 s cooldown.
--   demo_hold_lever      Hold (3 s), exclusive, 5 s cooldown, toggles on/off.
--
-- Observing reset:
--   Call InteractionService.resetAll("test") from the server console to verify
--   that the lever returns to "off" and the button counter stays where it is
--   (instant interactions have no in-flight state to reset).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local demo = {
	Name = "DemoInteractions",
}

local initialized = false
local started = false
local stateFolder = nil

function demo.Init(context)
	if initialized then
		context.Logger.warn("%s already initialized", demo.Name)
		return
	end

	initialized = true

	-- Create a Folder in ReplicatedStorage to expose observable demo state.
	local existing = ReplicatedStorage:FindFirstChild("DemoInteractionState")
	if existing ~= nil then
		existing:Destroy()
	end

	stateFolder = Instance.new("Folder")
	stateFolder.Name = "DemoInteractionState"
	stateFolder:SetAttribute("ButtonPressCount", 0)
	stateFolder:SetAttribute("LeverState", "off")
	stateFolder.Parent = ReplicatedStorage

	-- Attach to context janitor so it is removed on service stop.
	context.Janitor:Add(stateFolder)
end

function demo.Start(context)
	if started then
		context.Logger.warn("%s already started", demo.Name)
		return
	end

	if stateFolder == nil then
		error(string.format("%s cannot start: stateFolder is missing", demo.Name))
	end

	local InteractionService = require(script.Parent.InteractionService)

	-- ------------------------------------------------------------------
	-- demo_instant_button  — Instant, shared, 2 s cooldown
	-- ------------------------------------------------------------------
	InteractionService.register("demo_instant_button", {
		id = "demo_instant_button",
		actionName = "Press",
		displayName = "Button",
		mode = "Instant",
		cooldown = 2,
		getPrimaryPart = function(): BasePart?
			local part = Workspace:FindFirstChild("DemoButton")
			if part ~= nil and part:IsA("BasePart") then
				return part :: BasePart
			end
			return nil
		end,
		OnCompleted = function(player: Player, _sessionId: string): (boolean, string?)
			local count = stateFolder:GetAttribute("ButtonPressCount") or 0
			stateFolder:SetAttribute("ButtonPressCount", count + 1)
			context.Logger.info("%s: button pressed by %s (total=%d)", demo.Name, player.Name, count + 1)
			return true, nil
		end,
	})

	-- ------------------------------------------------------------------
	-- demo_hold_lever  — Hold (3 s), exclusive, 5 s cooldown
	-- ------------------------------------------------------------------
	InteractionService.register("demo_hold_lever", {
		id = "demo_hold_lever",
		actionName = "Pull",
		displayName = "Lever",
		mode = "Hold",
		holdDuration = 3,
		exclusive = true,
		cooldown = 5,
		cancelOnMovement = true,
		getPrimaryPart = function(): BasePart?
			local part = Workspace:FindFirstChild("DemoLever")
			if part ~= nil and part:IsA("BasePart") then
				return part :: BasePart
			end
			return nil
		end,
		OnStarted = function(player: Player, sessionId: string)
			context.Logger.info("%s: lever hold started — player=%s session=%s", demo.Name, player.Name, sessionId)
		end,
		OnCancelled = function(player: Player, sessionId: string, reason: string)
			context.Logger.info(
				"%s: lever cancelled — player=%s session=%s reason=%s",
				demo.Name,
				player.Name,
				sessionId,
				reason
			)
		end,
		OnCompleted = function(player: Player, sessionId: string): (boolean, string?)
			local current = stateFolder:GetAttribute("LeverState") or "off"
			local next = if current == "off" then "on" else "off"
			stateFolder:SetAttribute("LeverState", next)
			context.Logger.info("%s: lever pulled by %s session=%s state=%s", demo.Name, player.Name, sessionId, next)
			return true, nil
		end,
		Reset = function()
			if stateFolder ~= nil then
				stateFolder:SetAttribute("LeverState", "off")
			end
		end,
	})

	started = true
	context.Logger.info("%s started", demo.Name)
end

function demo.Stop(context)
	-- Unregister so InteractionService does not reference definitions after
	-- the demo module is torn down.  InteractionService.Stop has already
	-- cancelled sessions by the time this runs (Stop is called in reverse
	-- init order; D comes before I so InteractionService stops first).
	local ok, InteractionService = pcall(require, script.Parent.InteractionService)
	if ok and InteractionService ~= nil then
		if InteractionService.unregister ~= nil then
			pcall(InteractionService.unregister, "demo_instant_button")
			pcall(InteractionService.unregister, "demo_hold_lever")
		end
	end

	stateFolder = nil
	started = false
	initialized = false
	context.Logger.info("%s stopped", demo.Name)
end

return demo
