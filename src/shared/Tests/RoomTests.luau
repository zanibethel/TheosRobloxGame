-- RoomTests
-- Pure-logic test suite for the first playable search room state machine.
-- Uses only standard Lua/Luau; no Roblox APIs are required.
--
-- Usage (from a server Script or the Roblox Studio command bar):
--   local Tests = require(game.ReplicatedStorage.Shared.Tests.RoomTests)
--   local passed, total = Tests.run()
--   -- All tests pass when passed == total.
--
-- Tests cover:
--   First search awards key.
--   Second search does not award another key.
--   Player without key cannot unlock door.
--   Player with key unlocks door and key is consumed.
--   Door unlock happens only once.
--   Simultaneous search: exactly one winner.
--   Session reset clears key and searchable state.
--   Player disconnect removes their key.

local RoomTests = {}

-- ---------------------------------------------------------------------------
-- Minimal test harness (same pattern as InteractionTests / PartyTests)
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
-- Pure-logic room state machine
-- Models the core decision logic of KeyService and RoomService without any
-- Roblox API dependencies.  Player references are plain tables.
-- ---------------------------------------------------------------------------

local function makeRoomSystem()
	-- Per-session flags
	local drawerSearched = false
	local doorUnlocked = false
	local roomState = "searching"

	-- Per-player key ownership (mirrors KeyService.playerKeys)
	local playerKeys: { [any]: boolean } = {}

	-- Mirror of KeyService
	local function awardKey(player)
		if playerKeys[player] then
			return
		end
		playerKeys[player] = true
	end

	local function hasKey(player): boolean
		return playerKeys[player] == true
	end

	local function consumeKey(player)
		playerKeys[player] = nil
	end

	local function cleanPlayer(player)
		playerKeys[player] = nil
	end

	-- Attempt to search the drawer.
	-- Returns: (success: boolean, reason: string)
	local function trySearch(player): (boolean, string)
		if drawerSearched then
			return false, "already_searched"
		end
		drawerSearched = true
		awardKey(player)
		return true, "ok"
	end

	-- Attempt to unlock the door.
	-- Returns: (success: boolean, reason: string)
	local function tryUnlock(player): (boolean, string)
		if doorUnlocked then
			return false, "already_unlocked"
		end
		if not hasKey(player) then
			return false, "no_key"
		end
		doorUnlocked = true
		consumeKey(player)
		roomState = "complete"
		return true, "ok"
	end

	-- Reset all state for a new session.
	local function reset()
		drawerSearched = false
		doorUnlocked = false
		roomState = "searching"
		for player in playerKeys do
			playerKeys[player] = nil
		end
	end

	return {
		trySearch = trySearch,
		tryUnlock = tryUnlock,
		hasKey = hasKey,
		reset = reset,
		cleanPlayer = cleanPlayer,
		isDrawerSearched = function(): boolean
			return drawerSearched
		end,
		isDoorUnlocked = function(): boolean
			return doorUnlocked
		end,
		getRoomState = function(): string
			return roomState
		end,
	}
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- 1. First search awards the key to the searching player.
addTest("first search awards key", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }
	local ok, reason = room.trySearch(alice)
	expect(ok, "first search should succeed (got: " .. reason .. ")")
	expect(room.hasKey(alice), "alice should have the key after first search")
	expect(room.isDrawerSearched(), "drawer should be marked searched")
end)

-- 2. Second search attempt does not award another key.
addTest("second search does not award key", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }
	local bob = { name = "Bob" }

	local ok1 = room.trySearch(alice)
	expect(ok1, "first search should succeed")

	local ok2, reason2 = room.trySearch(bob)
	expect(not ok2, "second search should fail (got: " .. tostring(ok2) .. ")")
	expect(reason2 == "already_searched", "reason should be already_searched")
	expect(not room.hasKey(bob), "bob should not have a key")
end)

-- 3. Player without key cannot unlock the door.
addTest("player without key cannot unlock door", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }

	local ok, reason = room.tryUnlock(alice)
	expect(not ok, "unlock should fail without key")
	expect(reason == "no_key", "reason should be no_key")
	expect(not room.isDoorUnlocked(), "door should remain locked")
end)

-- 4. Player with key unlocks the door; key is consumed.
addTest("player with key unlocks door and key consumed", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }

	room.trySearch(alice)
	expect(room.hasKey(alice), "alice should have key before unlock")

	local ok, reason = room.tryUnlock(alice)
	expect(ok, "unlock should succeed (got: " .. reason .. ")")
	expect(room.isDoorUnlocked(), "door should be unlocked")
	expect(not room.hasKey(alice), "key should be consumed after unlock")
	expect(room.getRoomState() == "complete", "room state should be complete")
end)

-- 5. Door unlock happens only once; second attempt returns already_unlocked.
addTest("door unlock happens only once", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }
	local bob = { name = "Bob" }

	-- Alice finds key and opens door.
	room.trySearch(alice)
	room.tryUnlock(alice)
	expect(room.isDoorUnlocked(), "door should be unlocked after alice")

	-- Simulate bob also having a key (e.g. via some other path).
	-- tryUnlock still fails because the door is already open.
	local ok2, reason2 = room.tryUnlock(bob)
	expect(not ok2, "second unlock should fail")
	expect(reason2 == "already_unlocked", "reason should be already_unlocked")
end)

-- 6. Simultaneous search: exactly one winner (atomic check + set).
addTest("simultaneous search: only one winner", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }
	local bob = { name = "Bob" }

	-- Simulate two calls in the same tick (sequential, but both before the
	-- other returns — modelled here as back-to-back with no yields in between).
	local ok1, _ = room.trySearch(alice)
	local ok2, _ = room.trySearch(bob)

	-- Exactly one should succeed.
	local successCount = (if ok1 then 1 else 0) + (if ok2 then 1 else 0)
	expect(successCount == 1, "exactly one search should succeed; got " .. successCount)

	-- The winner holds the key; the other does not.
	local keyHolders = (if room.hasKey(alice) then 1 else 0) + (if room.hasKey(bob) then 1 else 0)
	expect(keyHolders == 1, "exactly one player should hold the key; got " .. keyHolders)
end)

-- 7. Session reset clears key ownership and searchable/door state.
addTest("session reset clears all state", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }

	-- Progress the room to complete.
	room.trySearch(alice)
	room.tryUnlock(alice)
	expect(room.isDoorUnlocked(), "door should be unlocked before reset")
	expect(room.getRoomState() == "complete", "state should be complete before reset")

	room.reset()

	expect(not room.isDrawerSearched(), "drawer should be unsearched after reset")
	expect(not room.isDoorUnlocked(), "door should be locked after reset")
	expect(not room.hasKey(alice), "alice should have no key after reset")
	expect(room.getRoomState() == "searching", "room state should be searching after reset")
end)

-- 8. Player disconnect removes their key record.
addTest("player disconnect clears key", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }

	room.trySearch(alice)
	expect(room.hasKey(alice), "alice should have key before disconnect")

	room.cleanPlayer(alice)
	expect(not room.hasKey(alice), "alice should have no key after disconnect")
end)

-- ---------------------------------------------------------------------------
-- Minimal session manager (mirrors TransitionService occupancy logic)
-- ---------------------------------------------------------------------------

local function makeSessionManager(roomSystem)
	local activePartyId: string? = nil

	local function acquire(partyId: string): (boolean, string)
		if activePartyId ~= nil then
			return false, "room_in_use"
		end
		-- Reset the room so the new party starts clean.
		roomSystem.reset()
		activePartyId = partyId
		return true, "ok"
	end

	local function release(partyId: string)
		if activePartyId == partyId then
			activePartyId = nil
		end
	end

	return {
		acquire = acquire,
		release = release,
		isOccupied = function(): boolean
			return activePartyId ~= nil
		end,
	}
end

-- ---------------------------------------------------------------------------
-- Tests — session lifecycle
-- ---------------------------------------------------------------------------

-- 9. New session starts with clean drawer, key, door, and room state.
addTest("new session starts with clean state", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }
	local session = makeSessionManager(room)

	local ok, _ = session.acquire("party-A")
	expect(ok, "acquire should succeed for empty room")
	expect(not room.isDrawerSearched(), "drawer should not be searched in new session")
	expect(not room.isDoorUnlocked(), "door should not be unlocked in new session")
	expect(not room.hasKey(alice), "player should have no key in new session")
	expect(room.getRoomState() == "searching", "room state should be searching in new session")
end)

-- 10. A second party cannot reset an occupied room.
addTest("second party cannot reset occupied room", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }
	local session = makeSessionManager(room)

	-- Party A acquires and makes progress.
	local ok1, _ = session.acquire("party-A")
	expect(ok1, "first acquire should succeed")
	room.trySearch(alice)
	expect(room.isDrawerSearched(), "drawer should be searched for party-A")

	-- Party B attempts to acquire while room is occupied.
	local ok2, code2 = session.acquire("party-B")
	expect(not ok2, "second acquire should fail")
	expect(code2 == "room_in_use", "code should be room_in_use")

	-- Party A's state must remain intact.
	expect(room.isDrawerSearched(), "party-A's drawer state must not be reset")
	expect(session.isOccupied(), "room should still be marked occupied")
end)

-- 11. Room becomes available after the active session ends.
addTest("room becomes available after session ends", function()
	local room = makeRoomSystem()
	local session = makeSessionManager(room)

	session.acquire("party-A")
	session.release("party-A")
	expect(not session.isOccupied(), "room should be free after release")

	local ok, _ = session.acquire("party-B")
	expect(ok, "party-B should acquire after party-A releases")
end)

-- 12. Completing one session does not permanently contaminate the next.
addTest("completing one session does not contaminate next", function()
	local room = makeRoomSystem()
	local alice = { name = "Alice" }
	local bob = { name = "Bob" }
	local session = makeSessionManager(room)

	-- Session 1: Alice completes the room.
	session.acquire("party-A")
	room.trySearch(alice)
	room.tryUnlock(alice)
	expect(room.getRoomState() == "complete", "session 1 should reach complete state")
	session.release("party-A")

	-- Session 2: Bob starts fresh — acquire triggers a reset.
	session.acquire("party-B")
	expect(not room.isDrawerSearched(), "drawer should be clean for session 2")
	expect(not room.isDoorUnlocked(), "door should be locked for session 2")
	expect(not room.hasKey(bob), "bob should have no key in session 2")
	expect(room.getRoomState() == "searching", "room state should be searching for session 2")
end)

function RoomTests.run(): (number, number)
	local passed = 0
	local total = #testCases

	for _, testCase in ipairs(testCases) do
		local ok, err = pcall(testCase.fn)
		if ok then
			passed += 1
			print(string.format("[RoomTests] PASS: %s", testCase.name))
		else
			warn(string.format("[RoomTests] FAIL: %s — %s", testCase.name, tostring(err)))
		end
	end

	print(string.format("[RoomTests] %d/%d tests passed", passed, total))
	return passed, total
end

return RoomTests
