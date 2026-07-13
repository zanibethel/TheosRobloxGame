-- InteractionTests
-- Pure-logic test suite for the interaction framework state machine.
-- Uses only standard Lua/Luau; no Roblox APIs are required.
--
-- Usage (from a server Script or the Roblox Studio command bar):
--   local Tests = require(ReplicatedStorage.Shared.Tests.InteractionTests)
--   local passed, total = Tests.run()
--   -- All tests pass when passed == total.
--
-- Tests cover:
--   Session ID uniqueness, exclusive locking, cooldowns, expiry,
--   replay rejection, session ownership, session limit, rate limiting,
--   cancel/complete state transitions, and concurrent cancellation safety.

local InteractionTests = {}

-- ---------------------------------------------------------------------------
-- Minimal test harness
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
-- Pure-logic helpers that mirror InteractionService internals
-- ---------------------------------------------------------------------------

local function makeSessionIdGenerator()
	local counter = 0
	return function(): string
		counter += 1
		return string.format("sid_%d_%08x", counter, math.random(0, 2147483647))
	end
end

local function makeExclusiveLockManager()
	local locks: { [string]: string } = {}
	return {
		acquire = function(targetId: string, sessionId: string): boolean
			if locks[targetId] ~= nil then
				return false
			end
			locks[targetId] = sessionId
			return true
		end,
		release = function(targetId: string, sessionId: string)
			if locks[targetId] == sessionId then
				locks[targetId] = nil
			end
		end,
		isLocked = function(targetId: string): boolean
			return locks[targetId] ~= nil
		end,
		holder = function(targetId: string): string?
			return locks[targetId]
		end,
	}
end

local function makeCooldownManager()
	local cooldowns: { [string]: number } = {}
	return {
		set = function(key: string, duration: number, now: number)
			cooldowns[key] = now + duration
		end,
		isActive = function(key: string, now: number): boolean
			local expiry = cooldowns[key]
			return expiry ~= nil and now < expiry
		end,
		clear = function(key: string)
			cooldowns[key] = nil
		end,
	}
end

local function makeSessionStateTracker()
	local sessions: { [string]: { cancelled: boolean, completed: boolean } } = {}
	return {
		add = function(sessionId: string)
			sessions[sessionId] = { cancelled = false, completed = false }
		end,
		cancel = function(sessionId: string): boolean
			local s = sessions[sessionId]
			if s == nil or s.cancelled or s.completed then
				return false
			end
			s.cancelled = true
			return true
		end,
		complete = function(sessionId: string): boolean
			local s = sessions[sessionId]
			if s == nil or s.cancelled or s.completed then
				return false
			end
			s.completed = true
			return true
		end,
		isResolved = function(sessionId: string): boolean
			local s = sessions[sessionId]
			if s == nil then
				return false
			end
			return s.cancelled or s.completed
		end,
	}
end

local function makeRateLimiter(limitSeconds: number)
	local lastTimes: { [number]: number } = {}
	return function(userId: number, now: number): boolean
		local last = lastTimes[userId]
		if last ~= nil and (now - last) < limitSeconds then
			return false
		end
		lastTimes[userId] = now
		return true
	end
end

local function makeSessionLimitTracker(maxPerPlayer: number)
	local byPlayer: { [number]: { [string]: boolean } } = {}

	local function count(userId: number): number
		local sessions = byPlayer[userId]
		if sessions == nil then
			return 0
		end
		local n = 0
		for _ in pairs(sessions) do
			n += 1
		end
		return n
	end

	return {
		tryAdd = function(userId: number, sessionId: string): boolean
			if count(userId) >= maxPerPlayer then
				return false
			end
			if byPlayer[userId] == nil then
				byPlayer[userId] = {}
			end
			byPlayer[userId][sessionId] = true
			return true
		end,
		remove = function(userId: number, sessionId: string)
			if byPlayer[userId] ~= nil then
				byPlayer[userId][sessionId] = nil
			end
		end,
		countFor = count,
	}
end

-- ---------------------------------------------------------------------------
-- Test cases
-- ---------------------------------------------------------------------------

addTest("sessionId_uniqueness_500", function()
	local newId = makeSessionIdGenerator()
	local seen: { [string]: boolean } = {}
	for _ = 1, 500 do
		local id = newId()
		expect(type(id) == "string" and id ~= "", "ID must be a non-empty string")
		expect(seen[id] == nil, "Duplicate session ID: " .. id)
		seen[id] = true
	end
end)

addTest("sessionId_format", function()
	local newId = makeSessionIdGenerator()
	local id = newId()
	expect(id:sub(1, 4) == "sid_", "ID should start with 'sid_'")
end)

addTest("exclusive_lock_single_acquire", function()
	local lm = makeExclusiveLockManager()
	expect(lm.acquire("t1", "s1"), "First acquire should succeed")
	expect(lm.isLocked("t1"), "Target should be locked")
	expect(lm.holder("t1") == "s1", "Holder should be s1")
end)

addTest("exclusive_lock_rejects_second", function()
	local lm = makeExclusiveLockManager()
	lm.acquire("t1", "s1")
	expect(not lm.acquire("t1", "s2"), "Second acquire must fail")
end)

addTest("exclusive_lock_release_allows_reacquire", function()
	local lm = makeExclusiveLockManager()
	lm.acquire("t1", "s1")
	lm.release("t1", "s1")
	expect(not lm.isLocked("t1"), "Should be unlocked after release")
	expect(lm.acquire("t1", "s2"), "New acquire after release should succeed")
end)

addTest("exclusive_lock_wrong_owner_cannot_release", function()
	local lm = makeExclusiveLockManager()
	lm.acquire("t1", "s1")
	lm.release("t1", "s_wrong") -- wrong owner
	expect(lm.isLocked("t1"), "Lock should remain when wrong owner tries to release")
	expect(lm.holder("t1") == "s1", "Holder should still be s1")
end)

addTest("exclusive_lock_independent_targets", function()
	local lm = makeExclusiveLockManager()
	expect(lm.acquire("t1", "s1"), "t1 acquire should succeed")
	expect(lm.acquire("t2", "s2"), "t2 acquire should succeed independently")
	expect(lm.isLocked("t1"), "t1 should be locked")
	expect(lm.isLocked("t2"), "t2 should be locked")
end)

addTest("cooldown_active_immediately_after_set", function()
	local cm = makeCooldownManager()
	cm.set("k1", 5, 100)
	expect(cm.isActive("k1", 100), "Should be on cooldown immediately")
	expect(cm.isActive("k1", 104.9), "Should still be on cooldown at 4.9s")
end)

addTest("cooldown_expired_at_duration", function()
	local cm = makeCooldownManager()
	cm.set("k1", 5, 100)
	expect(not cm.isActive("k1", 105), "Should not be on cooldown at exact expiry")
	expect(not cm.isActive("k1", 110), "Should not be on cooldown after expiry")
end)

addTest("cooldown_clear", function()
	local cm = makeCooldownManager()
	cm.set("k1", 5, 100)
	cm.clear("k1")
	expect(not cm.isActive("k1", 100), "Should not be on cooldown after clear")
end)

addTest("session_expiry_logic", function()
	local function isExpired(expiresAt: number, now: number): boolean
		return now >= expiresAt
	end
	expect(not isExpired(105, 100), "Not expired before time")
	expect(isExpired(105, 105), "Expired at exact time")
	expect(isExpired(105, 200), "Expired after time")
end)

addTest("replay_rejection_cancel_after_complete", function()
	local tracker = makeSessionStateTracker()
	tracker.add("s1")
	expect(tracker.complete("s1"), "First complete should succeed")
	expect(not tracker.cancel("s1"), "Cancel after complete must fail (replay)")
	expect(not tracker.complete("s1"), "Double complete must fail (replay)")
end)

addTest("replay_rejection_complete_after_cancel", function()
	local tracker = makeSessionStateTracker()
	tracker.add("s1")
	expect(tracker.cancel("s1"), "First cancel should succeed")
	expect(not tracker.complete("s1"), "Complete after cancel must fail (replay)")
	expect(not tracker.cancel("s1"), "Double cancel must fail")
end)

addTest("session_ownership", function()
	-- Simulate ownership check: session.userId must equal requesting userId
	local sessions: { [string]: { userId: number } } = {
		["s1"] = { userId = 42 },
		["s2"] = { userId = 99 },
	}
	local function isOwner(sessionId: string, userId: number): boolean
		local s = sessions[sessionId]
		return s ~= nil and s.userId == userId
	end
	expect(isOwner("s1", 42), "Player 42 owns s1")
	expect(not isOwner("s1", 99), "Player 99 does not own s1")
	expect(isOwner("s2", 99), "Player 99 owns s2")
	expect(not isOwner("unknown", 42), "Unknown session has no owner")
end)

addTest("session_limit_per_player", function()
	local tracker = makeSessionLimitTracker(3)
	expect(tracker.tryAdd(1, "s1"), "Session 1 should be allowed")
	expect(tracker.tryAdd(1, "s2"), "Session 2 should be allowed")
	expect(tracker.tryAdd(1, "s3"), "Session 3 should be allowed")
	expect(not tracker.tryAdd(1, "s4"), "Session 4 must be rejected (at limit)")
	-- Removing one should open a slot
	tracker.remove(1, "s2")
	expect(tracker.tryAdd(1, "s4"), "Session 4 should now be allowed after removal")
	-- Other players are unaffected
	expect(tracker.tryAdd(2, "s5"), "Player 2 is independent")
	expect(tracker.countFor(2) == 1, "Player 2 count should be 1")
end)

addTest("rate_limit_basic", function()
	local check = makeRateLimiter(0.3)
	expect(check(1, 0), "First request passes")
	expect(not check(1, 0.1), "Request within limit rejected")
	expect(not check(1, 0.29), "Request just below limit rejected")
	expect(check(1, 0.3), "Request at limit boundary passes")
	expect(check(2, 0), "Different player is unaffected")
end)

addTest("rate_limit_resets_after_allowed", function()
	local check = makeRateLimiter(0.3)
	check(1, 0) -- accepted; timestamp = 0
	check(1, 0.3) -- accepted; timestamp = 0.3
	expect(not check(1, 0.5), "Request 0.2s after last accepted should be rejected")
	expect(check(1, 0.6), "Request 0.3s after last accepted should pass")
end)

addTest("concurrent_cancel_exclusive_lock_safety", function()
	-- Two sessions race; only one should hold the lock
	local lm = makeExclusiveLockManager()
	local tracker = makeSessionStateTracker()

	tracker.add("s1")
	tracker.add("s2")

	-- s1 acquires lock
	local s1Locked = lm.acquire("t1", "s1")
	-- s2 tries immediately after — must fail
	local s2Locked = lm.acquire("t1", "s2")

	expect(s1Locked, "s1 should acquire the lock")
	expect(not s2Locked, "s2 must not acquire the lock")

	-- Cancel s1; lock releases; s2 can now acquire
	tracker.cancel("s1")
	lm.release("t1", "s1")

	expect(not lm.isLocked("t1"), "Lock should be free after s1 cancel")
	expect(lm.acquire("t1", "s2"), "s2 should acquire lock after s1 released")
end)

addTest("shared_mode_allows_multiple_holders", function()
	-- In shared (non-exclusive) mode there is no lock; simulate many sessions
	local tracker = makeSessionStateTracker()
	for i = 1, 6 do
		tracker.add("s" .. i)
	end
	-- All should be independently completable
	for i = 1, 6 do
		expect(tracker.complete("s" .. i), "Session " .. i .. " should complete independently")
	end
end)

addTest("hold_completion_at_required_duration", function()
	local startTime = 100
	local requiredDuration = 3
	local expiresAt = startTime + requiredDuration + 2 -- buffer

	local function shouldComplete(now: number): boolean
		return now >= startTime + requiredDuration and now < expiresAt
	end
	local function shouldExpire(now: number): boolean
		return now >= expiresAt
	end

	expect(not shouldComplete(102.9), "Should not complete before duration")
	expect(shouldComplete(103), "Should complete at duration")
	expect(not shouldExpire(103), "Should not expire at completion time")
	expect(shouldExpire(105), "Should expire after buffer elapses without completion")
end)

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

function InteractionTests.run(): (number, number)
	local passed = 0
	local total = #testCases

	print(string.format("[InteractionTests] Running %d tests...", total))

	for _, tc in ipairs(testCases) do
		local ok, err = pcall(tc.fn)
		if ok then
			passed += 1
			print(string.format("[InteractionTests] PASS  %s", tc.name))
		else
			print(string.format("[InteractionTests] FAIL  %s — %s", tc.name, tostring(err)))
		end
	end

	print(string.format("[InteractionTests] %d / %d passed", passed, total))

	return passed, total
end

return InteractionTests
