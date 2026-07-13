-- PartyState
-- Enum-style frozen table for party state machine states.
-- Always use these values when reading or writing party state;
-- avoid raw string literals for states throughout service and controller code.

local PartyState = table.freeze({
	Waiting = "Waiting",
	Ready = "Ready",
	Countdown = "Countdown",
	Launching = "Launching",
	InGame = "InGame",
	Closed = "Closed",
})

return PartyState
