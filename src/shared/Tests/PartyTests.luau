-- PartyTests
-- Pure-logic test suite for the party system state machine.
-- Uses only standard Lua/Luau; no Roblox APIs are required.
--
-- Usage (from a server Script or the Roblox Studio command bar):
--   local Tests = require(game.ReplicatedStorage.Shared.Tests.PartyTests)
--   local passed, total = Tests.run()
--   -- All tests pass when passed == total.
--
-- Tests cover:
--   Host transfer, countdown cancellation (leave / unready), party size
--   constraint, launch failure recovery, successful launch, in-game respawn
--   routing, launching-state respawn routing, lobby respawn routing, and
--   rate-limited request isolation.

local PartyTests = {}

-- ---------------------------------------------------------------------------
-- Minimal test harness (same pattern as InteractionTests)
-- ---------------------------------------------------------------------------

type TestCase = {
	name: string,
	fn: () -> (),
}

local testCases: { TestCase } = {}

local function addTest(name: string, fn: () -> ())
	table.insert(testCases, { name = name, fn = fn })
end

local function expect(condition: boolean, message: string)
	if not condition then
		error(string.format("Assertion failed: %s", message), 2)
	end
end

-- ---------------------------------------------------------------------------
-- Mock helpers
-- ---------------------------------------------------------------------------

local function makePlayer(name: string, userId: number)
	return { Name = name, UserId = userId }
end

-- ---------------------------------------------------------------------------
-- Pure-logic party state machine
--
-- Models the core decision logic of PartyService and PlayerLocationService
-- without any Roblox API dependencies.  Player references are plain tables
-- produced by makePlayer().
-- ---------------------------------------------------------------------------

local function makePartySystem()
	local parties: { [string]: any } = {}
	local playerToPartyId: { [any]: string } = {}
	local locations: { [any]: string } = {}
	local nextId = 0

	-- Location constants mirroring PlayerLocationService.LocationState.
	local LocationState = { Lobby = "Lobby", Launching = "Launching", InGame = "InGame" }

	local function genId(): string
		nextId += 1
		return "TEST" .. tostring(nextId)
	end

	local function getLocation(player): string
		return locations[player] or LocationState.Lobby
	end

	local function setLocation(player, loc: string)
		locations[player] = loc
	end

	-- Returns true when LobbyService should move the player to the lobby spawn.
	-- Mirrors the decision logic in LobbyService.handleRespawn.
	local function shouldMoveToLobby(player): boolean
		return getLocation(player) == LocationState.Lobby
	end

	-- Returns true when LobbyService should move the player to the game spawn.
	local function shouldMoveToGameSpawn(player): boolean
		return getLocation(player) == LocationState.InGame
	end

	local function cancelCountdown(party)
		if party.countdownActive then
			party.countdownActive = false
			party.state = "Waiting"
			party.countdownRemaining = nil
			return true
		end
		return false
	end

	local function create(player)
		if playerToPartyId[player] then
			return false, "already_in_party", nil
		end
		local id = genId()
		local party = {
			partyId = id,
			host = player,
			players = { player },
			readySet = {},
			maxPlayers = 6,
			state = "Waiting",
			countdownActive = false,
			countdownRemaining = nil,
		}
		parties[id] = party
		playerToPartyId[player] = id
		return true, "ok", id
	end

	local function join(player, partyId: string)
		if playerToPartyId[player] then
			return false, "already_in_party"
		end
		local party = parties[partyId]
		if not party then
			return false, "party_not_found"
		end
		if party.state ~= "Waiting" then
			return false, "party_locked"
		end
		if #party.players >= party.maxPlayers then
			return false, "party_full"
		end
		table.insert(party.players, player)
		playerToPartyId[player] = partyId
		return true, "ok"
	end

	local function leave(player)
		local partyId = playerToPartyId[player]
		if not partyId then
			return false, "no_party"
		end
		local party = parties[partyId]
		if not party then
			playerToPartyId[player] = nil
			return false, "party_not_found"
		end

		if party.state == "Countdown" then
			cancelCountdown(party)
		end

		party.readySet[player] = nil
		local remaining = {}
		for _, p in party.players do
			if p ~= player then
				table.insert(remaining, p)
			end
		end
		party.players = remaining
		playerToPartyId[player] = nil
		setLocation(player, LocationState.Lobby)

		if #remaining == 0 then
			parties[partyId] = nil
			return true, "ok"
		end

		if party.host == player then
			party.host = remaining[1]
		end

		return true, "ok"
	end

	local function ready(player)
		local partyId = playerToPartyId[player]
		if not partyId then
			return false, "no_party"
		end
		local party = parties[partyId]
		if party.state ~= "Waiting" then
			return false, "wrong_state"
		end
		party.readySet[player] = true
		return true, "ok"
	end

	local function unready(player)
		local partyId = playerToPartyId[player]
		if not partyId then
			return false, "no_party"
		end
		local party = parties[partyId]
		if party.state == "Countdown" then
			cancelCountdown(party)
		end
		if party.state ~= "Waiting" then
			return false, "wrong_state"
		end
		party.readySet[player] = nil
		return true, "ok"
	end

	local function start(player)
		local partyId = playerToPartyId[player]
		if not partyId then
			return false, "no_party"
		end
		local party = parties[partyId]
		if party.host ~= player then
			return false, "not_host"
		end
		if party.state ~= "Waiting" then
			return false, "wrong_state"
		end
		for _, p in party.players do
			if not party.readySet[p] then
				return false, "not_all_ready"
			end
		end
		party.state = "Countdown"
		party.countdownActive = true
		party.countdownRemaining = 5
		return true, "ok"
	end

	-- Simulates the countdown expiring and the Launching transition.
	-- Sets all members to Launching location, mirroring PartyService behaviour.
	local function beginLaunch(partyId: string)
		local party = parties[partyId]
		if not party then
			return false, "party_not_found"
		end
		if party.state ~= "Countdown" then
			return false, "wrong_state"
		end
		party.state = "Launching"
		party.countdownActive = false
		party.countdownRemaining = nil
		for _, p in party.players do
			setLocation(p, LocationState.Launching)
		end
		return true, "ok"
	end

	-- Applies the result returned by TransitionService.LaunchParty.
	-- success = true  → party enters InGame; all members set to InGame.
	-- success = false → party recovers to Waiting; all members reset to Lobby.
	local function applyLaunchResult(partyId: string, success: boolean)
		local party = parties[partyId]
		if not party then
			return false, "party_not_found"
		end
		if party.state ~= "Launching" then
			return false, "wrong_state"
		end
		if success then
			party.state = "InGame"
			for _, p in party.players do
				setLocation(p, LocationState.InGame)
			end
		else
			party.state = "Waiting"
			for _, p in party.players do
				setLocation(p, LocationState.Lobby)
			end
		end
		return true, "ok"
	end

	local function setSize(player, newSize: number)
		local partyId = playerToPartyId[player]
		if not partyId then
			return false, "no_party"
		end
		local party = parties[partyId]
		if party.host ~= player then
			return false, "not_host"
		end
		if party.state ~= "Waiting" then
			return false, "wrong_state"
		end
		if newSize < #party.players then
			return false, "invalid_size"
		end
		if newSize < 1 or newSize > 6 then
			return false, "invalid_size"
		end
		party.maxPlayers = newSize
		return true, "ok"
	end

	return {
		create = create,
		join = join,
		leave = leave,
		ready = ready,
		unready = unready,
		start = start,
		beginLaunch = beginLaunch,
		applyLaunchResult = applyLaunchResult,
		setSize = setSize,
		getParty = function(partyId: string)
			return parties[partyId]
		end,
		getPartyForPlayer = function(player)
			local id = playerToPartyId[player]
			return id and parties[id] or nil
		end,
		getLocation = getLocation,
		shouldMoveToLobby = shouldMoveToLobby,
		shouldMoveToGameSpawn = shouldMoveToGameSpawn,
	}
end

-- ---------------------------------------------------------------------------
-- Pure rate-limiter helper
--
-- Mirrors the per-player rate-limiting logic in PartyService so tests can
-- verify that rejected requests do not reach state-mutation code.
-- ---------------------------------------------------------------------------

local function makeRateLimiter(globalInterval: number, operationIntervals: { [string]: number }?)
	local globalLast: { [any]: number } = {}
	local opLast: { [any]: { [string]: number } } = {}

	return function(player, operation: string, now: number): (boolean, string?)
		-- Global interval.
		local gLast = globalLast[player]
		if gLast ~= nil and (now - gLast) < globalInterval then
			return false, "rate_limited"
		end
		-- Per-operation interval.
		if operationIntervals ~= nil then
			local opInterval = operationIntervals[operation]
			if opInterval ~= nil then
				local opMap = opLast[player]
				if opMap ~= nil then
					local last = opMap[operation]
					if last ~= nil and (now - last) < opInterval then
						return false, "rate_limited"
					end
				end
			end
		end
		-- Record timestamp.
		globalLast[player] = now
		if opLast[player] == nil then
			opLast[player] = {}
		end
		opLast[player][operation] = now
		return true, nil
	end
end

-- ---------------------------------------------------------------------------
-- Test cases
-- ---------------------------------------------------------------------------

-- 1. Host transfer when the host leaves a multi-member party.
addTest("host_transfer_on_leave", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local p2 = makePlayer("Player2", 2)
	local ok, _, partyId = sys.create(p1)
	expect(ok, "create should succeed")
	sys.join(p2, partyId)
	expect(sys.getParty(partyId).host == p1, "p1 should be initial host")
	sys.leave(p1)
	local party = sys.getParty(partyId)
	expect(party ~= nil, "party should still exist after host leaves")
	expect(party.host == p2, "p2 should become host after p1 leaves")
end)

-- 2. Countdown cancels when a member leaves during Countdown.
addTest("countdown_cancelled_on_member_leave", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local p2 = makePlayer("Player2", 2)
	local _, _, partyId = sys.create(p1)
	sys.join(p2, partyId)
	sys.ready(p1)
	sys.ready(p2)
	sys.start(p1)
	expect(sys.getParty(partyId).state == "Countdown", "party should be in Countdown")
	sys.leave(p2)
	expect(sys.getParty(partyId).state == "Waiting", "countdown should cancel when member leaves")
end)

-- 3. Countdown cancels when a player calls unready during Countdown.
addTest("countdown_cancelled_on_unready", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local p2 = makePlayer("Player2", 2)
	local _, _, partyId = sys.create(p1)
	sys.join(p2, partyId)
	sys.ready(p1)
	sys.ready(p2)
	sys.start(p1)
	expect(sys.getParty(partyId).state == "Countdown", "party should be in Countdown")
	sys.unready(p2)
	expect(sys.getParty(partyId).state == "Waiting", "countdown should cancel when a player unreadies")
end)

-- 4. Party size cannot be set below the current member count.
addTest("setSize_cannot_go_below_member_count", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local p2 = makePlayer("Player2", 2)
	local p3 = makePlayer("Player3", 3)
	local _, _, partyId = sys.create(p1)
	sys.join(p2, partyId)
	sys.join(p3, partyId)
	-- 3 members; trying to set max to 2 must fail.
	local ok, code = sys.setSize(p1, 2)
	expect(not ok, "setSize below member count should be rejected")
	expect(code == "invalid_size", "result code should be invalid_size")
	expect(sys.getParty(partyId).maxPlayers ~= 2, "maxPlayers must not change on rejection")
end)

-- 5. Launch failure restores the party to Waiting state.
addTest("launch_failure_restores_waiting", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local _, _, partyId = sys.create(p1)
	sys.ready(p1)
	sys.start(p1)
	sys.beginLaunch(partyId)
	expect(sys.getParty(partyId).state == "Launching", "party should be Launching before result")
	sys.applyLaunchResult(partyId, false)
	expect(sys.getParty(partyId).state == "Waiting", "launch failure should restore Waiting state")
end)

-- 6. Successful launch transitions the party to InGame.
addTest("successful_launch_enters_ingame", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local _, _, partyId = sys.create(p1)
	sys.ready(p1)
	sys.start(p1)
	sys.beginLaunch(partyId)
	sys.applyLaunchResult(partyId, true)
	expect(sys.getParty(partyId).state == "InGame", "successful launch should enter InGame state")
end)

-- 7. InGame respawn resolves to the game/test-room spawn (not the lobby).
addTest("ingame_respawn_resolves_to_game_spawn", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local _, _, partyId = sys.create(p1)
	sys.ready(p1)
	sys.start(p1)
	sys.beginLaunch(partyId)
	sys.applyLaunchResult(partyId, true)
	expect(not sys.shouldMoveToLobby(p1), "InGame player should NOT be moved to lobby on respawn")
	expect(sys.shouldMoveToGameSpawn(p1), "InGame player SHOULD be moved to game spawn on respawn")
end)

-- 8. Launching state respawn is skipped entirely (no lobby, no game spawn).
addTest("launching_respawn_is_skipped", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local _, _, partyId = sys.create(p1)
	sys.ready(p1)
	sys.start(p1)
	sys.beginLaunch(partyId)
	-- Player is in Launching state: neither lobby nor game spawn should fire.
	expect(not sys.shouldMoveToLobby(p1), "Launching player should NOT be moved to lobby")
	expect(not sys.shouldMoveToGameSpawn(p1), "Launching player should NOT be moved to game spawn")
end)

-- 9. New/unassigned players spawn in the lobby.
addTest("new_player_spawns_in_lobby", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	-- No party, no location set → implicit Lobby default.
	expect(sys.shouldMoveToLobby(p1), "new player should be directed to lobby spawn")
	expect(not sys.shouldMoveToGameSpawn(p1), "new player should not go to game spawn")
end)

-- 10. Rate-limited requests do not mutate party state.
addTest("rate_limited_requests_do_not_mutate_state", function()
	local sys = makePartySystem()
	local p1 = makePlayer("Player1", 1)
	local p2 = makePlayer("Player2", 2)
	local _, _, partyId = sys.create(p1)
	sys.join(p2, partyId)
	sys.ready(p1)
	sys.ready(p2)

	local rateLimiter = makeRateLimiter(0.5, { start = 3 })

	-- t=0: first start request is accepted.
	local allowed1, _ = rateLimiter(p1, "start", 0)
	expect(allowed1, "first start request should pass the rate limiter")
	sys.start(p1)
	expect(sys.getParty(partyId).state == "Countdown", "party should enter Countdown after start")

	-- Cancel for the next sub-test.
	sys.unready(p2) -- triggers countdown cancellation
	sys.ready(p2)
	expect(sys.getParty(partyId).state == "Waiting", "party should be Waiting after cancel")

	-- t=1: second start request arrives within the 3-second op window — rejected.
	local allowed2, code = rateLimiter(p1, "start", 1)
	expect(not allowed2, "second start within 3s should be rate limited")
	expect(code == "rate_limited", "result code should be rate_limited")
	-- State must not change; the rate-limited caller should never reach the handler.
	expect(sys.getParty(partyId).state == "Waiting", "party state must not change on rate-limited request")
end)

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

function PartyTests.run(): (number, number)
	local passed = 0
	local total = #testCases

	print(string.format("[PartyTests] Running %d tests...", total))

	for _, tc in ipairs(testCases) do
		local ok, err = pcall(tc.fn)
		if ok then
			passed += 1
			print(string.format("[PartyTests] PASS  %s", tc.name))
		else
			print(string.format("[PartyTests] FAIL  %s — %s", tc.name, tostring(err)))
		end
	end

	print(string.format("[PartyTests] %d / %d passed", passed, total))

	return passed, total
end

return PartyTests
