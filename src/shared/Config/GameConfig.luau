local GameConfig = {
	Game = {
		Title = "Theo's Roblox Game",
		MaxPlayers = 6,
		StartingRoomId = "Room01",
	},
	Debug = {
		LoggingEnabled = true,
		StrictMissingInstances = false,
	},
	Interaction = {
		-- Maximum distance (studs) between HumanoidRootPart and target part.
		MaxDistance = 12,
		-- ProximityPrompt hold duration shown on client for instant interactions.
		PromptHoldDurationSeconds = 0.15,
		-- Minimum seconds between accepted Begin/Instant requests per player.
		RateLimitSeconds = 0.3,
		-- Maximum concurrent active Hold sessions per player.
		MaxActiveSessions = 3,
		-- Extra seconds added to holdDuration before a session is force-expired.
		SessionExpiryBuffer = 2,
	},
	Round = {
		ResetDelaySeconds = 5,
		RespawnDelaySeconds = 3,
	},
}

return table.freeze(GameConfig)
