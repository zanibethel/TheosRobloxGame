-- RoomConfig
-- Configuration for the first playable search room.
-- Change values here; do not hardcode them in service or builder logic.
-- All positions are absolute world-space coordinates.
--
-- Room layout (defaults):
--   Floor top surface at Y = CenterY + FloorThickness = 2
--   Walls start at floor top; ceiling at floor top + Height = 17
--   SpawnPoint at Y = 2 so characters land at Y = 5 (matching FallbackSpawnPosition)
--   Drawer near the west wall; exit door against the north wall

local RoomConfig = {
	Room = {
		-- World-space footprint in studs.
		Width = 40, -- X axis
		Length = 40, -- Z axis
		Height = 15, -- Y axis (floor-top to ceiling-bottom)
		FloorThickness = 2,
		WallThickness = 1,
		-- Origin corner: floor bottom-center in world space.
		CenterX = 100,
		CenterY = 0, -- world Y at bottom of floor slab
		CenterZ = 0,
	},
	-- SpawnPoint part center.  Y = CenterY + FloorThickness = 0 + 2 = 2, which
	-- places it on the floor top surface.  LobbyService and TransitionService add
	-- +3 studs when they use a SpawnPoint part, so characters land at Y = 5,
	-- matching PartyConfig.TestRoom.FallbackSpawnPosition = Vector3.new(100, 5, 0).
	SpawnPosition = Vector3.new(100, 2, -5),
	-- Drawer body center.  Bottom at Y = 2.5, resting on the floor.
	DrawerPosition = Vector3.new(92, 3.5, -8),
	DrawerSize = Vector3.new(3, 2, 2),
	-- Exit-door panel center against the north wall (inner face at Z = 20).
	-- Bottom at Y = 2 (floor surface); top at Y = 10.
	DoorPosition = Vector3.new(100, 6, 19.5),
	DoorSize = Vector3.new(4, 8, 1),
	-- Gap in studs between the door panel edge and each side of the wall opening.
	-- The opening is DoorSize + 2 * DoorClearance wide and DoorSize.Y + DoorClearance
	-- tall (clearance on top only; bottom sits on the floor).
	DoorClearance = 0.2,
	-- Hold duration a player must keep the ProximityPrompt held to search.
	SearchHoldDuration = 2,
	-- Seconds for the door-open slide animation.
	DoorOpenDuration = 0.6,
	-- When true the key is removed from the player after the door opens.
	ConsumeKeyOnUnlock = true,
}

return table.freeze(RoomConfig)
