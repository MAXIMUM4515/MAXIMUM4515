--[[
	MapBuilder
	Generates the whole test map from code so the place is reproducible from source:

		- Terrain: plains + Mount Ignis, written chunk by chunk with WriteVoxels from the shared Heightmap.
		- The village of Emberfall: timber and stone houses, a concrete shelter, trees and loose props.
		- A spectator lobby out of the danger zone.

	Buildings are rebuilt every round. Terrain is only rewritten in chunks that bomb craters touched.

	Attributes written here are the contract with the other systems:
		Destructible  part can be damaged and collapse (Structures)
		Support       part holds a structure up and never breaks (foundations)
		Grounded      part rests on the ground (counts as support while intact)
		Indestructible  never takes damage
		Fragile       glass, shaken loose by tremors
		Prop          loose physics object
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Heightmap = require(Shared.Heightmap)

local M = Config.Map
local V = Config.Volcano

local VOXEL = 4
local CHUNK = 64
local CHUNK_VOXELS = CHUNK // VOXEL
local HALF = M.TerrainHalfSize
local CHUNKS_PER_SIDE = (HALF * 2) // CHUNK
local WATER_LEVEL = 0

local MapBuilder = {}

MapBuilder.Folders = {} :: {
	Root: Folder,
	Structures: Folder,
	Nature: Folder,
	Props: Folder,
	Debris: Folder,
	Effects: Folder,
	Lobby: Folder,
}
MapBuilder.VillageSpawns = {} :: { Vector3 }
MapBuilder.LobbySpawn = CFrame.identity
-- The lobby's leaderboards: each front face carries a board (see Leaderboard).
MapBuilder.Boards = {} :: { Wins: Part, RobuxSpent: Part }
MapBuilder.CraterPosition = Vector3.zero

local dirtyChunks: { [number]: boolean } = {}

--------------------------------------------------------------------------------------------
-- Part helpers
--------------------------------------------------------------------------------------------

type Props = { [string]: any }

-- Creates an instance with deterministic property order: Shape first (it resizes Balls), Parent last.
local function make(className: string, props: Props, parent: Instance?): any
	local instance = Instance.new(className)
	if props.Shape then
		(instance :: any).Shape = props.Shape
	end
	for key, value in props do
		if key ~= "Shape" and key ~= "Attributes" then
			(instance :: any)[key] = value
		end
	end
	if props.Attributes then
		for name, value in props.Attributes do
			instance:SetAttribute(name, value)
		end
	end
	instance.Parent = parent
	return instance
end

local function block(
	parent: Instance,
	name: string,
	cframe: CFrame,
	size: Vector3,
	material: Enum.Material,
	color: Color3,
	attributes: Props?
): Part
	return make("Part", {
		Name = name,
		Anchored = true,
		CFrame = cframe,
		Size = size,
		Material = material,
		Color = color,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
		Attributes = attributes,
	}, parent)
end

local function folder(name: string, parent: Instance): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing :: Folder
	end
	return make("Folder", { Name = name }, parent)
end

function MapBuilder.GroundHeight(x: number, z: number): number
	return Heightmap.Height(x, z)
end

--------------------------------------------------------------------------------------------
-- Terrain
--------------------------------------------------------------------------------------------

local function chunkKey(cx: number, cz: number): number
	return cx * 1000 + cz
end

local function writeChunk(cx: number, cz: number)
	local x0 = -HALF + cx * CHUNK + V.Center.X
	local z0 = -HALF + cz * CHUNK + V.Center.Z

	-- Sample the surface once per voxel column.
	local heights, surface, deep = {}, {}, {}
	local top = -math.huge
	for i = 1, CHUNK_VOXELS do
		heights[i], surface[i], deep[i] = {}, {}, {}
		for k = 1, CHUNK_VOXELS do
			local x = x0 + (i - 0.5) * VOXEL
			local z = z0 + (k - 0.5) * VOXEL
			local h = Heightmap.Height(x, z)
			heights[i][k] = h
			surface[i][k] = Heightmap.SurfaceMaterial(x, z)
			deep[i][k] = Heightmap.DeepMaterial(x, z)
			top = math.max(top, h)
		end
	end

	local yMin = -M.BedrockDepth
	local yMax = math.max(math.ceil((top + VOXEL) / VOXEL) * VOXEL, WATER_LEVEL + VOXEL)
	local layers = (yMax - yMin) // VOXEL

	local materials, occupancies = table.create(CHUNK_VOXELS), table.create(CHUNK_VOXELS)
	for i = 1, CHUNK_VOXELS do
		local matX, occX = table.create(layers), table.create(layers)
		materials[i], occupancies[i] = matX, occX
		for j = 1, layers do
			local matY, occY = table.create(CHUNK_VOXELS), table.create(CHUNK_VOXELS)
			matX[j], occX[j] = matY, occY
			local bottom = yMin + (j - 1) * VOXEL
			for k = 1, CHUNK_VOXELS do
				local h = heights[i][k]
				local occupancy = math.clamp((h - bottom) / VOXEL, 0, 1)
				local material
				if occupancy <= 0 then
					material = Enum.Material.Air
				elseif h - bottom < VOXEL * 2 then
					material = surface[i][k]
				else
					material = deep[i][k]
				end
				-- Fill the pond: the voxel holding the lake bed surface and anything above it, up to the water line.
				if
					bottom + VOXEL <= WATER_LEVEL
					and h < bottom + VOXEL - 0.5
					and h < WATER_LEVEL - 0.5
					and occupancy < 1
				then
					if Heightmap.Pond(x0 + (i - 0.5) * VOXEL, z0 + (k - 0.5) * VOXEL) > 0 then
						material = Enum.Material.Water
						occupancy = 1
					end
				end
				matY[k] = material
				occY[k] = occupancy
			end
		end
	end

	local region = Region3.new(Vector3.new(x0, yMin, z0), Vector3.new(x0 + CHUNK, yMax, z0 + CHUNK))
	workspace.Terrain:WriteVoxels(region, VOXEL, materials, occupancies)
end

function MapBuilder.BuildTerrain()
	workspace.Terrain:Clear()
	local written = 0
	for cx = 0, CHUNKS_PER_SIDE - 1 do
		for cz = 0, CHUNKS_PER_SIDE - 1 do
			writeChunk(cx, cz)
			written += 1
			if written % 6 == 0 then
				task.wait()
			end
		end
	end
	table.clear(dirtyChunks)
end

-- Remember which chunks a crater touched so the next reset only rewrites those.
function MapBuilder.MarkTerrainDirty(position: Vector3, radius: number)
	local minX = math.floor((position.X - radius - V.Center.X + HALF) / CHUNK)
	local maxX = math.floor((position.X + radius - V.Center.X + HALF) / CHUNK)
	local minZ = math.floor((position.Z - radius - V.Center.Z + HALF) / CHUNK)
	local maxZ = math.floor((position.Z + radius - V.Center.Z + HALF) / CHUNK)
	for cx = math.max(minX, 0), math.min(maxX, CHUNKS_PER_SIDE - 1) do
		for cz = math.max(minZ, 0), math.min(maxZ, CHUNKS_PER_SIDE - 1) do
			dirtyChunks[chunkKey(cx, cz)] = true
		end
	end
end

function MapBuilder.RepairTerrain(): number
	local repaired = 0
	for key in dirtyChunks do
		writeChunk(key // 1000, key % 1000)
		repaired += 1
		if repaired % 4 == 0 then
			task.wait()
		end
	end
	table.clear(dirtyChunks)
	return repaired
end

--------------------------------------------------------------------------------------------
-- Lighting
--------------------------------------------------------------------------------------------

local function ensure(className: string, name: string, parent: Instance): any
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing
	end
	return make(className, { Name = name }, parent)
end

function MapBuilder.SetupLighting()
	Lighting.ClockTime = 17.3
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(58, 48, 48)
	Lighting.OutdoorAmbient = Color3.fromRGB(122, 104, 98)
	Lighting.EnvironmentDiffuseScale = 0.45
	Lighting.EnvironmentSpecularScale = 0.5
	Lighting.GlobalShadows = true

	-- Remove any stock Atmosphere so ours is the only one the client tweens.
	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") and child.Name ~= "MountIgnisAtmosphere" then
			child:Destroy()
		end
	end

	local atmosphere = ensure("Atmosphere", "MountIgnisAtmosphere", Lighting)
	atmosphere.Density = 0.3
	atmosphere.Offset = 0.12
	atmosphere.Color = Color3.fromRGB(205, 178, 160)
	atmosphere.Decay = Color3.fromRGB(110, 92, 84)
	atmosphere.Glare = 0.25
	atmosphere.Haze = 1.4

	local bloom = ensure("BloomEffect", "MountIgnisBloom", Lighting)
	bloom.Intensity = 0.55
	bloom.Size = 30
	bloom.Threshold = 1.15

	local grade = ensure("ColorCorrectionEffect", "MountIgnisGrade", Lighting)
	grade.Saturation = 0.05
	grade.Contrast = 0.06
	grade.Brightness = 0
	grade.TintColor = Color3.new(1, 1, 1)

	local rays = ensure("SunRaysEffect", "MountIgnisSunRays", Lighting)
	rays.Intensity = 0.05
	rays.Spread = 0.6
end

--------------------------------------------------------------------------------------------
-- Lobby
--------------------------------------------------------------------------------------------

local STONE = Color3.fromRGB(120, 116, 112)
local BOARD_TIMBER = Color3.fromRGB(86, 60, 42)

-- A slate board on two posts with a timber frame, standing on `base` (floor level) and turned to
-- face `facing` (only its X and Z matter). Returns the slate panel, whose front face is the board.
local function buildBoard(parent: Instance, name: string, base: Vector3, facing: Vector3): Part
	local size = Config.Leaderboards.BoardSize
	local center = base + Vector3.new(0, 2 + size.Y / 2, 0)
	local frame = CFrame.lookAt(center, Vector3.new(facing.X, center.Y, facing.Z))
	local board = block(parent, name, frame, size, Enum.Material.Slate, Color3.fromRGB(34, 30, 30))
	block(
		parent,
		`{name}Frame`,
		frame * CFrame.new(0, 0, 0.4),
		Vector3.new(size.X + 1, size.Y + 1, 0.4),
		Enum.Material.Wood,
		BOARD_TIMBER
	)
	local postHeight = 2 + size.Y + 0.5
	for _, side in { -1, 1 } do
		local post = frame * CFrame.new(side * (size.X / 2 - 1.5), 0, 0.9)
		block(
			parent,
			`{name}Post`,
			CFrame.new(post.X, base.Y + postHeight / 2, post.Z) * frame.Rotation,
			Vector3.new(0.8, postHeight, 0.8),
			Enum.Material.Wood,
			BOARD_TIMBER
		)
	end
	return board
end

function MapBuilder.BuildLobby()
	local lobby = MapBuilder.Folders.Lobby
	lobby:ClearAllChildren()

	local spec = M.Lobby
	local center = spec.Position
	local size = spec.Size

	block(lobby, "Platform", CFrame.new(center), size, Enum.Material.Cobblestone, STONE)

	-- Pillars down to the ground.
	for _, corner in { Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, -1), Vector3.new(-1, 0, -1) } do
		local x = center.X + corner.X * (size.X / 2 - 3)
		local z = center.Z + corner.Z * (size.Z / 2 - 3)
		local ground = Heightmap.Height(x, z) - 4
		local height = center.Y - ground
		block(
			lobby,
			"Pillar",
			CFrame.new(x, ground + height / 2, z),
			Vector3.new(4, height, 4),
			Enum.Material.Concrete,
			STONE
		)
	end

	-- Low walls around the edge.
	local wallY = center.Y + size.Y / 2 + 1.5
	block(
		lobby,
		"Rail",
		CFrame.new(center.X, wallY, center.Z + size.Z / 2 - 0.5),
		Vector3.new(size.X, 3, 1),
		Enum.Material.Cobblestone,
		STONE
	)
	block(
		lobby,
		"Rail",
		CFrame.new(center.X, wallY, center.Z - size.Z / 2 + 0.5),
		Vector3.new(size.X, 3, 1),
		Enum.Material.Cobblestone,
		STONE
	)
	block(
		lobby,
		"Rail",
		CFrame.new(center.X + size.X / 2 - 0.5, wallY, center.Z),
		Vector3.new(1, 3, size.Z),
		Enum.Material.Cobblestone,
		STONE
	)
	block(
		lobby,
		"Rail",
		CFrame.new(center.X - size.X / 2 + 0.5, wallY, center.Z),
		Vector3.new(1, 3, size.Z),
		Enum.Material.Cobblestone,
		STONE
	)

	local floorY = center.Y + size.Y / 2
	local spawnPosition = Vector3.new(center.X, floorY + 0.5, center.Z + 4)
	local spawnLocation = make("SpawnLocation", {
		Name = "LobbySpawn",
		Anchored = true,
		Size = Vector3.new(12, 1, 12),
		CFrame = CFrame.lookAt(spawnPosition, spawnPosition + Vector3.zAxis),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(70, 66, 64),
		Neutral = true,
		Duration = 0,
		TopSurface = Enum.SurfaceType.Smooth,
	}, lobby)
	MapBuilder.LobbySpawn = spawnLocation.CFrame + Vector3.new(0, 4, 0)

	-- The leaderboards stand at the front of the lobby either side of the spawn, each turned toward
	-- a point just behind it so it faces the camera of anyone who spawns.
	local boards = Config.Leaderboards
	local floorCenter = Vector3.new(center.X, floorY, center.Z)
	local facing = Vector3.new(spawnPosition.X, 0, spawnPosition.Z - 6)
	MapBuilder.Boards = {
		Wins = buildBoard(lobby, "WinsBoard", floorCenter + boards.Wins.Offset, facing),
		RobuxSpent = buildBoard(lobby, "RobuxBoard", floorCenter + boards.RobuxSpent.Offset, facing),
	}
end

--------------------------------------------------------------------------------------------
-- Village
--------------------------------------------------------------------------------------------

local WOOD_WALLS = {
	Color3.fromRGB(156, 112, 76),
	Color3.fromRGB(140, 98, 66),
	Color3.fromRGB(176, 132, 92),
	Color3.fromRGB(122, 86, 60),
}
local ROOF_WOOD = Color3.fromRGB(104, 58, 44)
local ROOF_SLATE = Color3.fromRGB(70, 72, 82)
local BRICK = Color3.fromRGB(158, 112, 92)
local TIMBER = Color3.fromRGB(86, 60, 42)
local GLASS = Color3.fromRGB(170, 212, 232)

local DESTRUCTIBLE = { Destructible = true }

local function buildHouse(index: number, base: CFrame, width: number, depth: number, stone: boolean, rng: Random): Model
	-- Houses are proper buildings: being inside one can survive the pyroclastic flow (see Shelter).
	local model = make("Model", { Name = `House{index}`, Attributes = { Shelter = true } })
	local wallHeight = 9
	local wallMaterial = if stone then Enum.Material.Brick else Enum.Material.WoodPlanks
	local wallColor = if stone then BRICK else WOOD_WALLS[rng:NextInteger(1, #WOOD_WALLS)]

	block(
		model,
		"Foundation",
		base * CFrame.new(0, -0.5, 0),
		Vector3.new(width + 1, 3, depth + 1),
		Enum.Material.Concrete,
		STONE,
		{
			Support = true,
		}
	)
	block(
		model,
		"Floor",
		base * CFrame.new(0, 1.1, 0),
		Vector3.new(width - 1, 0.2, depth - 1),
		Enum.Material.WoodPlanks,
		Color3.fromRGB(120, 84, 58),
		DESTRUCTIBLE
	)

	local function piece(cframe: CFrame, size: Vector3)
		block(model, "Wall", cframe, size, wallMaterial, wallColor, DESTRUCTIBLE)
	end

	local function window(cframe: CFrame, size: Vector3)
		local pane =
			block(model, "Window", cframe, size, Enum.Material.Glass, GLASS, { Destructible = true, Fragile = true })
		pane.Transparency = 0.45
		pane.Reflectance = 0.1
	end

	-- A wall split into ~4 stud panels so it can burn and break apart piece by piece.
	local function wall(origin: CFrame, length: number, openings: { [number]: string })
		local segments = math.max(1, math.round(length / 4))
		local segment = length / segments
		for s = 1, segments do
			local x = -length / 2 + (s - 0.5) * segment
			local kind = openings[s]
			if kind == "door" then
				piece(origin * CFrame.new(x, 7 + (wallHeight - 7) / 2, 0), Vector3.new(segment, wallHeight - 7, 1))
			elseif kind == "window" then
				piece(origin * CFrame.new(x, 1.25, 0), Vector3.new(segment, 2.5, 1))
				window(origin * CFrame.new(x, 4, 0), Vector3.new(segment, 3, 0.4))
				piece(
					origin * CFrame.new(x, 5.5 + (wallHeight - 5.5) / 2, 0),
					Vector3.new(segment, wallHeight - 5.5, 1)
				)
			else
				piece(origin * CFrame.new(x, wallHeight / 2, 0), Vector3.new(segment, wallHeight, 1))
			end
		end
	end

	local frontSegments = math.max(1, math.round(width / 4))
	local front = {}
	local door = (frontSegments + 1) // 2
	front[door] = "door"
	for s = 1, frontSegments do
		if s ~= door and (s - door) % 2 == 0 then
			front[s] = "window"
		end
	end
	local back = {}
	for s = 2, frontSegments - 1, 2 do
		back[s] = "window"
	end
	local sideSegments = math.max(1, math.round((depth - 2) / 4))
	local side = { [(sideSegments + 1) // 2] = "window" }

	-- Front faces local -Z (toward the square).
	wall(base * CFrame.new(0, 1, -depth / 2 + 0.5), width, front)
	wall(base * CFrame.new(0, 1, depth / 2 - 0.5), width, back)
	wall(base * CFrame.new(width / 2 - 0.5, 1, 0) * CFrame.Angles(0, math.pi / 2, 0), depth - 2, side)
	wall(base * CFrame.new(-width / 2 + 0.5, 1, 0) * CFrame.Angles(0, math.pi / 2, 0), depth - 2, side)

	for _, corner in { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } } do
		block(
			model,
			"Post",
			base * CFrame.new(corner[1] * (width / 2 - 0.5), 1 + wallHeight / 2, corner[2] * (depth / 2 - 0.5)),
			Vector3.new(1.4, wallHeight, 1.4),
			Enum.Material.Wood,
			TIMBER,
			DESTRUCTIBLE
		)
	end

	local top = 1 + wallHeight
	block(
		model,
		"Ceiling",
		base * CFrame.new(0, top + 0.3, 0),
		Vector3.new(width, 0.6, depth),
		Enum.Material.WoodPlanks,
		TIMBER,
		DESTRUCTIBLE
	)

	-- Pitched roof: two slabs meeting at a ridge above the centre line.
	local pitch = math.rad(32)
	local halfSpan = depth / 2 + 1
	local slabLength = halfSpan / math.cos(pitch)
	local rise = halfSpan * math.tan(pitch)
	local roofMaterial = if stone then Enum.Material.Slate else Enum.Material.WoodPlanks
	local roofColor = if stone then ROOF_SLATE else ROOF_WOOD
	for _, sideSign in { -1, 1 } do
		block(
			model,
			"Roof",
			base * CFrame.new(0, top + 0.6 + rise / 2, sideSign * halfSpan / 2) * CFrame.Angles(sideSign * pitch, 0, 0),
			Vector3.new(width + 2, 0.8, slabLength),
			roofMaterial,
			roofColor,
			DESTRUCTIBLE
		)
	end

	if stone then
		block(
			model,
			"Chimney",
			base * CFrame.new(width / 4, top + 3, depth / 4),
			Vector3.new(2.4, 8, 2.4),
			Enum.Material.Brick,
			BRICK,
			DESTRUCTIBLE
		)
	end

	return model
end

local function buildBunker(index: number, base: CFrame): Model
	-- A concrete bunker with its opening facing away from the volcano. Never breaks, never burns.
	local model = make("Model", { Name = `Bunker{index}`, Attributes = { Shelter = true } })
	local concrete = Color3.fromRGB(150, 148, 142)
	local solid = { Support = true, Indestructible = true }
	local w, d, h = 14, 12, 8
	block(
		model,
		"Floor",
		base * CFrame.new(0, -0.5, 0),
		Vector3.new(w + 2, 3, d + 2),
		Enum.Material.Concrete,
		concrete,
		solid
	)
	block(
		model,
		"BackWall",
		base * CFrame.new(0, 1 + h / 2, -d / 2),
		Vector3.new(w + 2, h, 2),
		Enum.Material.Concrete,
		concrete,
		solid
	)
	block(
		model,
		"SideWall",
		base * CFrame.new(w / 2, 1 + h / 2, 0),
		Vector3.new(2, h, d),
		Enum.Material.Concrete,
		concrete,
		solid
	)
	block(
		model,
		"SideWall",
		base * CFrame.new(-w / 2, 1 + h / 2, 0),
		Vector3.new(2, h, d),
		Enum.Material.Concrete,
		concrete,
		solid
	)
	block(
		model,
		"Roof",
		base * CFrame.new(0, 1 + h + 1, 0),
		Vector3.new(w + 4, 2, d + 3),
		Enum.Material.Concrete,
		concrete,
		solid
	)

	local signPosition = (base * CFrame.new(0, 1 + h - 1, d / 2 + 1.6)).Position
	local sign = block(
		model,
		"Sign",
		CFrame.lookAt(signPosition, signPosition + base.LookVector * -1),
		Vector3.new(8, 2, 0.4),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(230, 190, 40),
		solid
	)
	local gui = make(
		"SurfaceGui",
		{ Face = Enum.NormalId.Front, SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud, PixelsPerStud = 30 },
		sign
	)
	make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "SHELTER",
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(30, 30, 30),
	}, gui)
	return model
end

local function buildTree(index: number, position: Vector3, rng: Random): Model
	local model = make("Model", { Name = `Tree{index}` })
	local height = rng:NextNumber(10, 16)
	local thickness = rng:NextNumber(1.4, 2.2)
	make("Part", {
		Name = "Trunk",
		Shape = Enum.PartType.Cylinder,
		Anchored = true,
		-- Two studs buried so voxel rounding of the terrain never leaves a tree floating.
		Size = Vector3.new(height + 2, thickness, thickness),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2 - 1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(92, 66, 46),
		Attributes = { Destructible = true, Grounded = true },
	}, model)
	local greens = { Color3.fromRGB(76, 120, 58), Color3.fromRGB(92, 136, 64), Color3.fromRGB(64, 104, 52) }
	for leaf = 1, rng:NextInteger(2, 3) do
		local size = rng:NextNumber(7, 10)
		local offset = Vector3.new(
			rng:NextNumber(-2.2, 2.2),
			rng:NextNumber(-1, 2.5) + (leaf - 1) * 1.5,
			rng:NextNumber(-2.2, 2.2)
		)
		make("Part", {
			Name = "Leaves",
			Shape = Enum.PartType.Ball,
			Anchored = true,
			Size = Vector3.one * size,
			CFrame = CFrame.new(position + Vector3.new(0, height, 0) + offset),
			Material = Enum.Material.LeafyGrass,
			Color = greens[rng:NextInteger(1, #greens)],
			Attributes = DESTRUCTIBLE,
		}, model)
	end
	return model
end

local function buildProp(position: Vector3, rng: Random, parent: Instance)
	local part
	if rng:NextNumber() < 0.55 then
		part = make("Part", {
			Name = "Crate",
			Size = Vector3.one * rng:NextNumber(2.6, 3.4),
			Material = Enum.Material.WoodPlanks,
			Color = Color3.fromRGB(164, 124, 82),
		})
	else
		part = make("Part", {
			Name = "Barrel",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3.2, 2.6, 2.6),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(118, 78, 50),
		})
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local upright = if part.Shape == Enum.PartType.Cylinder then CFrame.Angles(0, 0, math.pi / 2) else CFrame.identity
	part.CFrame = CFrame.new(position + Vector3.new(0, part.Size.Y / 2 + 0.6, 0))
		* CFrame.Angles(0, rng:NextNumber(0, math.pi), 0)
		* upright
	part:SetAttribute("Prop", true)
	part.Parent = parent
	pcall(part.SetNetworkOwner, part, nil)
end

local function groundAt(x: number, z: number): number
	return Heightmap.Height(x, z)
end

-- Rebuilds everything that can be destroyed. Called at startup and between rounds.
function MapBuilder.BuildDestructibles()
	local folders = MapBuilder.Folders
	folders.Structures:ClearAllChildren()
	folders.Nature:ClearAllChildren()
	folders.Props:ClearAllChildren()
	folders.Debris:ClearAllChildren()

	local rng = Random.new(M.Seed)
	local square = M.VillageCenter
	local squareY = groundAt(square.X, square.Z)
	local squarePosition = Vector3.new(square.X, squareY, square.Z)

	-- Houses in a ring, all facing the square.
	local footprints: { { Position: Vector3, Radius: number } } = {}
	local stoneHouses = { [2] = true, [5] = true }
	for i = 1, M.HouseCount do
		local angle = (i / M.HouseCount) * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		local distance = rng:NextNumber(M.VillageRadius - 8, M.VillageRadius)
		local x = square.X + math.cos(angle) * distance
		local z = square.Z + math.sin(angle) * distance
		local y = groundAt(x, z)
		local width = ({ 14, 16, 18 })[rng:NextInteger(1, 3)]
		local depth = ({ 12, 14 })[rng:NextInteger(1, 2)]
		local base = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(square.X, y, square.Z))
		local house = buildHouse(i, base, width, depth, stoneHouses[i] == true, rng)
		house.Parent = folders.Structures
		table.insert(footprints, { Position = Vector3.new(x, y, z), Radius = math.max(width, depth) * 0.75 })

		-- A couple of crates and barrels beside each house.
		for _ = 1, rng:NextInteger(1, 3) do
			local spot = base * CFrame.new(rng:NextNumber(-width / 2, width / 2), 0, depth / 2 + rng:NextNumber(2.5, 5))
			buildProp(Vector3.new(spot.X, groundAt(spot.X, spot.Z), spot.Z), rng, folders.Props)
		end
	end

	-- Concrete bunkers around the village, each with its solid back wall toward the volcano.
	for i, offset in M.Bunkers do
		local x, z = square.X + offset.X, square.Z + offset.Z
		local position = Vector3.new(x, groundAt(x, z), z)
		local away = Vector3.new(x - V.Center.X, 0, z - V.Center.Z).Unit
		-- lookAt(away) points local -Z (the back wall) away from the volcano; flip it to face the volcano.
		local base = CFrame.lookAt(position, position + away) * CFrame.Angles(0, math.pi, 0)
		buildBunker(i, base).Parent = folders.Structures
		table.insert(footprints, { Position = position, Radius = 12 })
	end

	-- Stone well in the square.
	local well = make("Model", { Name = "Well" })
	make("Part", {
		Name = "WellRing",
		Shape = Enum.PartType.Cylinder,
		Anchored = true,
		Size = Vector3.new(3, 7, 7),
		CFrame = CFrame.new(squarePosition + Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Cobblestone,
		Color = STONE,
		Attributes = { Support = true, Indestructible = true },
	}, well)
	well.Parent = folders.Structures
	table.insert(footprints, { Position = squarePosition, Radius = 6 })

	-- Is there room for a building of this size here? Keeps clear of everything already placed,
	-- the pond and the volcano's slope.
	local function isClear(position: Vector3, radius: number): boolean
		if Heightmap.Volcano(position.X, position.Z) > 2 then
			return false
		end
		local pond = M.Pond
		local px, pz = position.X - pond.Center.X, position.Z - pond.Center.Z
		if px * px + pz * pz < (pond.Radius + radius + 6) ^ 2 then
			return false
		end
		for _, footprint in footprints do
			local fx, fz = position.X - footprint.Position.X, position.Z - footprint.Position.Z
			if fx * fx + fz * fz < (footprint.Radius + radius + 4) ^ 2 then
				return false
			end
		end
		return true
	end

	-- Outer ring: more houses facing the square, every third one a larger brick house. A spot that
	-- is taken is nudged sideways a few times before giving up on it.
	local outerCount = 0
	for i = 1, M.OuterHouseCount do
		local brick = i % 3 == 0
		local width = if brick then 20 else ({ 14, 16, 18 })[rng:NextInteger(1, 3)]
		local depth = if brick then 16 else ({ 12, 14 })[rng:NextInteger(1, 2)]
		local radius = math.max(width, depth) * 0.75
		local baseAngle = (i + 0.5) / M.OuterHouseCount * math.pi * 2
		for attempt = 0, 4 do
			local side = if attempt % 2 == 0 then 1 else -1
			local angle = baseAngle + side * math.ceil(attempt / 2) * 0.12
			local distance = M.OuterRadius + rng:NextNumber(-4, 4)
			local x = square.X + math.cos(angle) * distance
			local z = square.Z + math.sin(angle) * distance
			local position = Vector3.new(x, groundAt(x, z), z)
			if isClear(position, radius) then
				outerCount += 1
				local base = CFrame.lookAt(position, Vector3.new(square.X, position.Y, square.Z))
				buildHouse(M.HouseCount + outerCount, base, width, depth, brick, rng).Parent = folders.Structures
				table.insert(footprints, { Position = position, Radius = radius })
				local spot = base
					* CFrame.new(rng:NextNumber(-width / 2, width / 2), 0, depth / 2 + rng:NextNumber(2.5, 5))
				buildProp(Vector3.new(spot.X, groundAt(spot.X, spot.Z), spot.Z), rng, folders.Props)
				break
			end
		end
	end

	-- Spawn points around the well.
	table.clear(MapBuilder.VillageSpawns)
	for i = 1, 10 do
		local angle = i / 10 * math.pi * 2
		local x, z = square.X + math.cos(angle) * 13, square.Z + math.sin(angle) * 13
		table.insert(MapBuilder.VillageSpawns, Vector3.new(x, groundAt(x, z) + 3, z))
	end

	-- Trees on the plains and lower flanks, kept off the square, the houses and the pond.
	local placed = 0
	local attempts = 0
	while placed < M.TreeCount and attempts < M.TreeCount * 20 do
		attempts += 1
		local angle = rng:NextNumber(-math.pi, math.pi)
		local distance = rng:NextNumber(V.BaseRadius * 0.55, 360)
		local x = V.Center.X + math.cos(angle) * distance
		local z = V.Center.Z + math.sin(angle) * distance
		local ok = Heightmap.Volcano(x, z) < 22 and Heightmap.Pond(x, z) == 0
		if ok then
			local dx, dz = x - square.X, z - square.Z
			ok = dx * dx + dz * dz > 20 * 20
		end
		if ok then
			for _, footprint in footprints do
				local fx, fz = x - footprint.Position.X, z - footprint.Position.Z
				if fx * fx + fz * fz < (footprint.Radius + 5) ^ 2 then
					ok = false
					break
				end
			end
		end
		if ok then
			placed += 1
			buildTree(placed, Vector3.new(x, groundAt(x, z), z), rng).Parent = folders.Nature
		end
	end

	-- A few loose props in the square.
	for _ = 1, 6 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = rng:NextNumber(8, 20)
		local x, z = square.X + math.cos(angle) * distance, square.Z + math.sin(angle) * distance
		buildProp(Vector3.new(x, groundAt(x, z), z), rng, folders.Props)
	end
end

--------------------------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------------------------

function MapBuilder.CreateFolders()
	local root = folder("MountIgnis", workspace)
	MapBuilder.Folders = {
		Root = root,
		Structures = folder("Structures", root),
		Nature = folder("Nature", root),
		Props = folder("Props", root),
		Debris = folder("Debris", root),
		Effects = folder("Effects", root),
		Lobby = folder("Lobby", root),
	}
	MapBuilder.CraterPosition = Vector3.new(V.Center.X, Heightmap.Height(V.Center.X, V.Center.Z), V.Center.Z)
end

function MapBuilder.Build()
	MapBuilder.CreateFolders()
	MapBuilder.SetupLighting()
	-- The lobby holds the only SpawnLocation, so build it before anything that yields.
	MapBuilder.BuildLobby()
	MapBuilder.BuildTerrain()
	MapBuilder.BuildDestructibles()
end

function MapBuilder.Reset()
	MapBuilder.RepairTerrain()
	MapBuilder.BuildDestructibles()
end

return MapBuilder
