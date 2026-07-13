-- TestRoomBuilder
-- Builds a temporary test room under workspace.TestRoom at runtime using
-- only basic Roblox parts.  No free models or external assets are used.
--
-- Idempotent: if workspace.TestRoom already exists when Start runs the
-- builder logs a warning and skips construction to avoid duplicating geometry.
--
-- Cleanup: the TestRoom folder and all its children are destroyed on Stop.
--
-- The room geometry is intentionally isolated here so it can later be
-- replaced by a hand-crafted Studio map without touching service logic.
--
-- Parts tagged "Interactable" with required attributes are added to the
-- drawer and exit-door so InteractionController picks them up on all clients
-- via CollectionService automatically.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RoomConfig = require(ReplicatedStorage.Shared.Config.RoomConfig)
local PartyConfig = require(ReplicatedStorage.Shared.Config.PartyConfig)
local Janitor = require(ReplicatedStorage.Shared.Util.Janitor)

local INTERACTABLE_TAG = "Interactable"

local service = {
	Name = "TestRoomBuilder",
}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local initialized = false
local started = false
local serviceJanitor = nil

-- ---------------------------------------------------------------------------
-- Private: part builders
-- ---------------------------------------------------------------------------

local function makePart(parent: Instance, name: string, position: Vector3, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Builds floor, walls, ceiling, and a point light.
local function buildRoomGeometry(parent: Instance)
	local cfg = RoomConfig.Room
	local cx = cfg.CenterX
	local cy = cfg.CenterY
	local cz = cfg.CenterZ
	local w = cfg.Width
	local l = cfg.Length
	local h = cfg.Height
	local ft = cfg.FloorThickness
	local wt = cfg.WallThickness

	local floorColor = Color3.fromRGB(80, 80, 80)
	local wallColor = Color3.fromRGB(60, 60, 60)
	local ceilColor = Color3.fromRGB(50, 50, 50)

	-- Floor slab: top surface at cy + ft.
	makePart(parent, "Floor", Vector3.new(cx, cy + ft / 2, cz), Vector3.new(w, ft, l), floorColor)

	-- Ceiling slab.
	makePart(
		parent,
		"Ceiling",
		Vector3.new(cx, cy + ft + h + wt / 2, cz),
		Vector3.new(w + wt * 2, wt, l + wt * 2),
		ceilColor
	)

	-- Wall vertical centre (floor top → ceiling bottom).
	local wallCenterY = cy + ft + h / 2

	-- North wall (positive Z) — exit side.
	-- Built in three sections so the doorway opening is physically passable:
	--   WallNorthLeft  : left of the opening
	--   WallNorthRight : right of the opening
	--   WallNorthTop   : above the opening up to the ceiling
	-- The opening is DoorSize + 2*DoorClearance wide and
	-- DoorSize.Y + DoorClearance tall (clearance on sides and top; bottom is the floor).
	local northWallZ = cz + l / 2 + wt / 2
	local dPos = RoomConfig.DoorPosition
	local dSize = RoomConfig.DoorSize
	local clearance = RoomConfig.DoorClearance

	local openingLeft = dPos.X - dSize.X / 2 - clearance
	local openingRight = dPos.X + dSize.X / 2 + clearance
	local openingTop = dPos.Y + dSize.Y / 2 + clearance

	local fullWallLeft = cx - w / 2 - wt
	local fullWallRight = cx + w / 2 + wt
	local wallTop = cy + ft + h

	-- Left section: from the full wall's left edge to the opening's left edge.
	local leftWidth = openingLeft - fullWallLeft
	local leftCenterX = (fullWallLeft + openingLeft) / 2
	makePart(
		parent,
		"WallNorthLeft",
		Vector3.new(leftCenterX, wallCenterY, northWallZ),
		Vector3.new(leftWidth, h, wt),
		wallColor
	)

	-- Right section: from the opening's right edge to the full wall's right edge.
	local rightWidth = fullWallRight - openingRight
	local rightCenterX = (openingRight + fullWallRight) / 2
	makePart(
		parent,
		"WallNorthRight",
		Vector3.new(rightCenterX, wallCenterY, northWallZ),
		Vector3.new(rightWidth, h, wt),
		wallColor
	)

	-- Top section: spans the full wall width, from the opening's top to the ceiling.
	local topHeight = wallTop - openingTop
	local topCenterY = (openingTop + wallTop) / 2
	makePart(
		parent,
		"WallNorthTop",
		Vector3.new(cx, topCenterY, northWallZ),
		Vector3.new(w + wt * 2, topHeight, wt),
		wallColor
	)

	-- South wall (negative Z).
	makePart(
		parent,
		"WallSouth",
		Vector3.new(cx, wallCenterY, cz - l / 2 - wt / 2),
		Vector3.new(w + wt * 2, h, wt),
		wallColor
	)

	-- East wall (positive X).
	makePart(parent, "WallEast", Vector3.new(cx + w / 2 + wt / 2, wallCenterY, cz), Vector3.new(wt, h, l), wallColor)

	-- West wall (negative X).
	makePart(parent, "WallWest", Vector3.new(cx - w / 2 - wt / 2, wallCenterY, cz), Vector3.new(wt, h, l), wallColor)

	-- Overhead point light embedded near the ceiling.
	local lightPart = makePart(
		parent,
		"RoomLight",
		Vector3.new(cx, cy + ft + h - 1, cz),
		Vector3.new(1, 1, 1),
		Color3.fromRGB(255, 255, 200)
	)
	lightPart.Transparency = 0.8
	local pointLight = Instance.new("PointLight")
	pointLight.Brightness = 4
	pointLight.Range = 60
	pointLight.Color = Color3.fromRGB(255, 245, 200)
	pointLight.Parent = lightPart
end

-- Builds the invisible SpawnPoint that LobbyService and TransitionService use.
local function buildSpawnPoint(parent: Instance)
	local spawnPart = makePart(
		parent,
		PartyConfig.TestRoom.SpawnPartName,
		RoomConfig.SpawnPosition,
		Vector3.new(2, 0.5, 2),
		Color3.fromRGB(0, 200, 0)
	)
	spawnPart.Transparency = 1
	spawnPart.CanCollide = false
end

-- Builds a wooden drawer prop and tags its body for InteractionController.
local function buildDrawer(parent: Instance)
	local drawerModel = Instance.new("Model")
	drawerModel.Name = "Drawer"
	drawerModel.Parent = parent

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = RoomConfig.DrawerSize
	body.CFrame = CFrame.new(RoomConfig.DrawerPosition)
	body.Color = Color3.fromRGB(163, 120, 60)
	body.Material = Enum.Material.Wood
	body.Anchored = true
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Parent = drawerModel
	drawerModel.PrimaryPart = body

	-- Attributes read by InteractionController to build the ProximityPrompt.
	body:SetAttribute("InteractableId", "room_search_drawer")
	body:SetAttribute("InteractableMode", "Hold")
	body:SetAttribute("InteractableAction", "Search")
	body:SetAttribute("InteractableDisplay", "Drawer")
	body:SetAttribute("InteractableHoldDuration", RoomConfig.SearchHoldDuration)
	CollectionService:AddTag(body, INTERACTABLE_TAG)
end

-- Builds a door frame and sliding panel prop and tags the panel for
-- InteractionController.  The panel is what blocks the exit path initially;
-- it slides upward when the room is completed.
local function buildExitDoor(parent: Instance)
	local doorModel = Instance.new("Model")
	doorModel.Name = "ExitDoor"
	doorModel.Parent = parent

	local wt = RoomConfig.Room.WallThickness
	local dPos = RoomConfig.DoorPosition
	local dSize = RoomConfig.DoorSize
	local clearance = RoomConfig.DoorClearance

	-- Decorative frame — three separate pieces so the centre doorway stays open.
	-- Each piece sits just outside the clearance boundary of the door panel.
	-- The playable opening (dSize.X + 2*clearance wide, dSize.Y + clearance tall)
	-- is left completely unobstructed.
	local frameColor = Color3.fromRGB(100, 70, 40)
	local frameMat = Enum.Material.Wood
	-- Visual thickness of each frame strip (must be > 0; kept narrow so it does
	-- not visually intrude on the opening).
	local frameThickness = 0.25
	-- Total clear width including the side clearances (shared by pillar placement
	-- and top-beam width).
	local openingWidth = dSize.X + 2 * clearance

	-- Left pillar: sits to the left of the opening's left edge.
	local leftPillar = Instance.new("Part")
	leftPillar.Name = "DoorFrameLeft"
	leftPillar.Size = Vector3.new(frameThickness, dSize.Y, wt)
	leftPillar.CFrame = CFrame.new(dPos.X - openingWidth / 2 - frameThickness / 2, dPos.Y, dPos.Z)
	leftPillar.Color = frameColor
	leftPillar.Material = frameMat
	leftPillar.Anchored = true
	leftPillar.TopSurface = Enum.SurfaceType.Smooth
	leftPillar.BottomSurface = Enum.SurfaceType.Smooth
	leftPillar.Parent = doorModel

	-- Right pillar: sits to the right of the opening's right edge.
	local rightPillar = Instance.new("Part")
	rightPillar.Name = "DoorFrameRight"
	rightPillar.Size = Vector3.new(frameThickness, dSize.Y, wt)
	rightPillar.CFrame = CFrame.new(dPos.X + openingWidth / 2 + frameThickness / 2, dPos.Y, dPos.Z)
	rightPillar.Color = frameColor
	rightPillar.Material = frameMat
	rightPillar.Anchored = true
	rightPillar.TopSurface = Enum.SurfaceType.Smooth
	rightPillar.BottomSurface = Enum.SurfaceType.Smooth
	rightPillar.Parent = doorModel

	-- Top beam: spans the full opening width (including left/right strips) and
	-- sits above the clearance top edge.
	local topBeam = Instance.new("Part")
	topBeam.Name = "DoorFrameTop"
	topBeam.Size = Vector3.new(openingWidth + 2 * frameThickness, frameThickness, wt)
	topBeam.CFrame = CFrame.new(dPos.X, dPos.Y + dSize.Y / 2 + clearance + frameThickness / 2, dPos.Z)
	topBeam.Color = frameColor
	topBeam.Material = frameMat
	topBeam.Anchored = true
	topBeam.TopSurface = Enum.SurfaceType.Smooth
	topBeam.BottomSurface = Enum.SurfaceType.Smooth
	topBeam.Parent = doorModel

	-- Door panel (the blocking surface that slides open).
	local panel = Instance.new("Part")
	panel.Name = "DoorPanel"
	panel.Size = dSize
	panel.CFrame = CFrame.new(dPos)
	panel.Color = Color3.fromRGB(120, 80, 50)
	panel.Material = Enum.Material.Wood
	panel.Anchored = true
	panel.TopSurface = Enum.SurfaceType.Smooth
	panel.BottomSurface = Enum.SurfaceType.Smooth
	panel.Parent = doorModel
	doorModel.PrimaryPart = panel

	-- Attributes read by InteractionController to build the ProximityPrompt.
	panel:SetAttribute("InteractableId", "room_exit_door")
	panel:SetAttribute("InteractableMode", "Instant")
	panel:SetAttribute("InteractableAction", "Use Key")
	panel:SetAttribute("InteractableDisplay", "Exit Door")
	CollectionService:AddTag(panel, INTERACTABLE_TAG)
end

-- ---------------------------------------------------------------------------
-- Service lifecycle
-- ---------------------------------------------------------------------------

function service.Init(context)
	if initialized then
		context.Logger.warn("%s already initialized", service.Name)
		return
	end
	initialized = true
	serviceJanitor = Janitor.new()
	context.Janitor:Add(serviceJanitor)
end

function service.Start(context)
	if started then
		context.Logger.warn("%s already started", service.Name)
		return
	end
	if serviceJanitor == nil then
		error(string.format("%s cannot start: janitor is missing", service.Name))
	end

	-- Idempotent guard: skip build if the folder already exists.
	local existing = Workspace:FindFirstChild(PartyConfig.TestRoom.SpawnFolderName)
	if existing ~= nil then
		context.Logger.warn(
			"%s: %s already exists in workspace; skipping room build",
			service.Name,
			PartyConfig.TestRoom.SpawnFolderName
		)
		started = true
		context.Logger.info("%s started (room pre-existing)", service.Name)
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = PartyConfig.TestRoom.SpawnFolderName
	-- RoomState attribute is read by clients as the authoritative room phase.
	folder:SetAttribute("RoomState", "searching")
	folder.Parent = Workspace

	buildRoomGeometry(folder)
	buildSpawnPoint(folder)
	buildDrawer(folder)
	buildExitDoor(folder)

	-- Register with janitor so the folder is removed on service stop.
	serviceJanitor:Add(folder)

	started = true
	context.Logger.info("%s: test room built under workspace.%s", service.Name, PartyConfig.TestRoom.SpawnFolderName)
end

function service.Stop(context)
	if serviceJanitor ~= nil then
		serviceJanitor:Cleanup()
		serviceJanitor = nil
	end
	started = false
	initialized = false
	context.Logger.info("%s stopped", service.Name)
end

return service
