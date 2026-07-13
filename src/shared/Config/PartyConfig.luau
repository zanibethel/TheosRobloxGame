-- PartyConfig
-- Tuning and location configuration for the lobby and party system.
-- Change values here; do not hardcode them in service or controller logic.
-- Workspace folder names are configurable so map designers can reorganise
-- the hierarchy without touching service code.

local PartyConfig = {
	Party = {
		-- Minimum number of players required for the host to start the game.
		MinPlayers = 1,
		-- Absolute maximum players per party (must not exceed GameConfig.Game.MaxPlayers).
		MaxPlayers = 6,
		-- Default max-player cap assigned to a newly created party.
		DefaultMaxPlayers = 6,
		-- How many seconds the server countdown runs before launching.
		CountdownSeconds = 5,
		-- Character length for generated party IDs.
		PartyIdLength = 6,
	},
	Lobby = {
		-- Name of the Workspace folder that holds lobby spawn points.
		-- LobbyService looks for workspace[SpawnFolderName][SpawnPartName].
		-- If the part is absent the FallbackSpawnPosition is used instead.
		SpawnFolderName = "Lobby",
		SpawnPartName = "SpawnPoint",
		-- Fallback spawn if the workspace part is absent.
		FallbackSpawnPosition = Vector3.new(0, 5, 0),
	},
	TestRoom = {
		-- Name of the Workspace folder that holds test-room spawn points.
		-- TransitionService looks for workspace[SpawnFolderName][SpawnPartName].
		SpawnFolderName = "TestRoom",
		SpawnPartName = "SpawnPoint",
		-- Fallback spawn if the workspace part is absent.
		FallbackSpawnPosition = Vector3.new(100, 5, 0),
	},
	-- Set to true once TeleportService integration is ready.
	-- TransitionService checks this flag before choosing a launch path.
	FutureTeleportEnabled = false,
	RateLimiting = {
		-- Minimum elapsed seconds between any two PartyRequest calls from the
		-- same player.  Requests arriving faster than this are rejected with
		-- "rate_limited" and do not mutate any party state.
		GlobalMinInterval = 0.5,
		-- Per-operation minimum seconds applied on top of the global interval.
		-- Operations not listed here are governed only by GlobalMinInterval.
		OperationIntervals = {
			create = 5,
			join = 2,
			start = 3,
			kick = 1,
			setSize = 1,
			ready = 1,
			unready = 1,
		},
	},
}

return table.freeze(PartyConfig)
