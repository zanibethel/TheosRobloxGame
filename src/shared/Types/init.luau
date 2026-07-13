export type GamePhase = "Bootstrap" | "RoomReady" | "RoomActive" | "RoomResetting"

export type PlayerRuntimeState = {
	userId: number,
	isAlive: boolean,
	isHidden: boolean,
	currentRoomId: string?,
}

export type BootstrapContext = {
	Config: typeof(require(script.Parent.Parent.Config.GameConfig)),
	Janitor: any,
	Logger: any,
	RunContext: "Server" | "Client",
}

-- ---------------------------------------------------------------------------
-- Interaction framework types
-- ---------------------------------------------------------------------------

-- "Instant" completes immediately on a single validated request.
-- "Hold"    creates a server-owned timed session; client displays progress only.
export type InteractionMode = "Instant" | "Hold"

-- The three operations a client may send via InteractionRequest.
-- "complete" is intentionally absent — the server owns hold completion.
export type InteractionOperation = "instant" | "begin" | "cancel"

-- Non-sensitive result codes returned to the client.
-- Never embed internal reason strings in these codes.
export type InteractionResultCode =
	"ok"
	| "rate_limited"
	| "invalid_args"
	| "not_registered"
	| "no_character"
	| "dead"
	| "too_far"
	| "not_enabled"
	| "cooldown"
	| "locked"
	| "session_limit"
	| "session_not_found"
	| "session_expired"
	| "not_owner"
	| "already_resolved"
	| "wrong_operation"
	| "handler_error"

-- State broadcast by the server so clients can update prompt availability.
export type InteractionTargetState = "available" | "locked" | "cooldown" | "disabled"

-- Full definition schema for a registered interactable.
-- Passed to InteractionService.register().
-- All callbacks are wrapped in pcall on the server.
export type InteractionDefinition = {
	-- Required identity fields
	id: string,
	actionName: string,
	displayName: string,
	mode: InteractionMode,
	-- Returns the BasePart used for distance checks and existence validation.
	-- Returning nil is treated as "target removed".
	getPrimaryPart: () -> BasePart?,

	-- Hold-mode options
	holdDuration: number?, -- seconds; required when mode == "Hold"

	-- Behaviour tuning
	maxDistance: number?, -- overrides GameConfig.Interaction.MaxDistance
	cooldown: number?, -- seconds of per-target cooldown after completion
	-- enabled may be a static boolean or a zero-argument resolver function.
	-- nil is treated as true.  Use type `any` to support both forms.
	enabled: any,
	exclusive: boolean?, -- true → at most one active session per target at a time
	requiresLineOfSight: boolean?, -- reserved for future use; not yet enforced
	cancelOnMovement: boolean?, -- cancel Hold if player drifts outside maxDistance
	cancelOnDamage: boolean?, -- cancel Hold if player takes any damage

	-- Server callbacks — all wrapped in pcall; errors are logged, not leaked
	CanInteract: ((player: Player) -> (boolean, string?))?,
	OnStarted: ((player: Player, sessionId: string) -> ())?,
	OnCancelled: ((player: Player, sessionId: string, reason: string) -> ())?,
	OnCompleted: ((player: Player, sessionId: string) -> (boolean, string?))?,
	Reset: (() -> ())?,
	Cleanup: (() -> ())?,
}

-- Internal per-session record stored server-side only; never sent to clients.
export type SessionRecord = {
	sessionId: string,
	player: Player,
	userId: number,
	interactableId: string,
	actionName: string,
	mode: InteractionMode,
	startTime: number, -- os.clock() at session creation
	requiredDuration: number, -- seconds the server will wait before completing
	expiresAt: number, -- safety-net expiry = startTime + requiredDuration + buffer
	cancelled: boolean,
	completed: boolean,
	startHealth: number, -- Humanoid.Health at session start, for cancelOnDamage
}

-- ---------------------------------------------------------------------------
-- Party system types
-- ---------------------------------------------------------------------------

-- All possible party lifecycle states.  Use PartyState enum values; never
-- compare raw strings against these types in service or controller code.
export type PartyState = "Waiting" | "Ready" | "Countdown" | "Launching" | "InGame" | "Closed"

-- Operations a client may send via the PartyRequest RemoteFunction.
export type PartyOperation = "create" | "join" | "leave" | "ready" | "unready" | "start" | "cancel" | "kick" | "setSize"

-- Non-sensitive result codes returned to the client.  Never embed internal
-- reason strings or server-side details in these codes.
export type PartyResultCode =
	"ok"
	| "already_in_party"
	| "no_party"
	| "not_host"
	| "party_not_found"
	| "party_full"
	| "party_locked"
	| "not_enough_players"
	| "not_all_ready"
	| "wrong_state"
	| "player_not_found"
	| "invalid_size"
	| "invalid_args"
	| "internal_error"

-- Per-player snapshot inside a PartyInfo broadcast.
export type PartyPlayerInfo = {
	name: string,
	displayName: string,
	userId: number,
	isReady: boolean,
	isHost: boolean,
}

-- Safe read-only snapshot of a party broadcast to its members via PartyStateChanged.
-- Never includes internal state, threads, or sensitive server data.
export type PartyInfo = {
	partyId: string,
	hostName: string,
	maxPlayers: number,
	playerCount: number,
	players: { PartyPlayerInfo },
	state: string,
	countdownRemaining: number?,
}

-- Entry in the public lobby list broadcast to all clients via PartyListChanged.
export type PartyListEntry = {
	partyId: string,
	hostName: string,
	playerCount: number,
	maxPlayers: number,
}

return nil
