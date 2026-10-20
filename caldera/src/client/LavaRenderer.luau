--[[
	LavaRenderer
	Draws the server's lava simulation locally from the packed deltas it streams.

	Each wet cell is one pooled slab. Slabs are tilted to the local surface gradient (from the
	neighbouring cells) so a flow reads as a continuous sheet rather than a staircase, and their
	height eases toward the latest server value every frame so the flow moves smoothly even
	though updates only arrive a few times a second. All slabs are moved in one BulkMoveTo.

	Molten slabs glow and are non-collidable (you wade into them). Once a cell freezes into
	basalt crust its slab turns to rock and becomes collidable for the local character, which is
	simulated on this client, so you can walk on the cooled flow.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local LavaGrid = require(Shared.LavaGrid)
local Net = require(Shared.Net)

local P = Config.Lava
local N = LavaGrid.N
local CELL = LavaGrid.CellSize
local COUNT = LavaGrid.Count
local MIN_VISIBLE = 0.04
local SLAB_WIDTH = CELL * P.SlabOverlap

local LavaRenderer = {}

local ground = table.create(COUNT, 0)
local crust = table.create(COUNT, 0)
local lava = table.create(COUNT, 0)
local temp = table.create(COUNT, 0)
local shown = table.create(COUNT, 0)
local styleKey = table.create(COUNT, -2)
local parts: { [number]: BasePart } = {}
local lights: { [number]: PointLight } = {}
local lightCount = 0

local animating: { [number]: boolean } = {}
local placeSet: { [number]: boolean } = {}
local pool: { BasePart } = {}
local folder: Folder

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local HEAT_COLORS = {
	{ 1.0, Color3.fromRGB(255, 222, 130) },
	{ 0.8, Color3.fromRGB(255, 150, 44) },
	{ 0.55, Color3.fromRGB(236, 74, 22) },
	{ 0.35, Color3.fromRGB(150, 36, 16) },
	{ 0.0, Color3.fromRGB(70, 28, 20) },
}
local CRUST_COLOR = Color3.fromRGB(48, 44, 43)

local function heatColor(t: number): Color3
	for i = 1, #HEAT_COLORS - 1 do
		local upper, lower = HEAT_COLORS[i], HEAT_COLORS[i + 1]
		if t >= lower[1] then
			local alpha = (t - lower[1]) / (upper[1] - lower[1])
			return lower[2]:Lerp(upper[2], alpha)
		end
	end
	return HEAT_COLORS[#HEAT_COLORS][2]
end

local template = Instance.new("Part")
template.Name = "Lava"
template.Anchored = true
template.CanCollide = false
template.CanQuery = false
template.CanTouch = false
template.CastShadow = false
template.Material = Enum.Material.Neon
template.TopSurface = Enum.SurfaceType.Smooth
template.BottomSurface = Enum.SurfaceType.Smooth
template.Size = Vector3.new(SLAB_WIDTH, P.SlabThickness, SLAB_WIDTH)

local function acquire(index: number): BasePart
	local part = table.remove(pool) or template:Clone()
	parts[index] = part
	-- New cells rise out of the ground instead of popping in.
	shown[index] = ground[index] + crust[index] - 0.3
	styleKey[index] = -2
	part.Parent = folder
	return part
end

local function removeLight(index: number)
	local light = lights[index]
	if light then
		light:Destroy()
		lights[index] = nil
		lightCount -= 1
	end
end

local function release(index: number)
	local part = parts[index]
	if not part then
		return
	end
	removeLight(index)
	parts[index] = nil
	animating[index] = nil
	part.Parent = nil
	table.insert(pool, part)
end

-- Neighbours' tilt depends on this cell's height, so they need re-placing too.
local function markNeighbours(index: number)
	local ix, iz = LavaGrid.Coords(index)
	if ix > 0 then
		placeSet[index - N] = true
	end
	if ix < N - 1 then
		placeSet[index + N] = true
	end
	if iz > 0 then
		placeSet[index - 1] = true
	end
	if iz < N - 1 then
		placeSet[index + 1] = true
	end
end

local function style(index: number, part: BasePart)
	local molten = lava[index] > MIN_VISIBLE
	-- Quantise so we only touch properties when the look actually changes.
	local key = if molten then math.floor(temp[index] * 24) else -1
	if key == styleKey[index] then
		return
	end
	styleKey[index] = key

	if molten then
		local t = temp[index]
		part.Material = if t > 0.45 then Enum.Material.Neon else Enum.Material.CrackedLava
		part.Color = heatColor(t)
		part.CanCollide = false
		local wantsLight = t > 0.55 and index % P.LightEvery == 0
		if wantsLight and not lights[index] and lightCount < P.MaxLights then
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 120, 40)
			light.Range = 16
			light.Brightness = 1.4
			light.Shadows = false
			light.Parent = part
			lights[index] = light
			lightCount += 1
		elseif not wantsLight then
			removeLight(index)
		end
	else
		part.Material = Enum.Material.Basalt
		part.Color = CRUST_COLOR
		part.CanCollide = true
		removeLight(index)
	end
end

local function apply(index: number, g: number, c: number, l: number, t: number)
	ground[index], crust[index], lava[index], temp[index] = g, c, l, t
	if l <= MIN_VISIBLE and c <= MIN_VISIBLE then
		release(index)
		markNeighbours(index)
		return
	end
	local part = parts[index] or acquire(index)
	style(index, part)
	local thickness = math.max(P.SlabThickness, math.ceil((c + l + 2) / 2) * 2)
	if part.Size.Y ~= thickness then
		part.Size = Vector3.new(SLAB_WIDTH, thickness, SLAB_WIDTH)
	end
	animating[index] = true
	markNeighbours(index)
end

-- Surface height of a neighbour if it has a slab, else nil.
local function neighbourTop(index: number): number?
	if parts[index] then
		return shown[index]
	end
	return nil
end

local function slabCFrame(index: number): CFrame
	local ix, iz = LavaGrid.Coords(index)
	local h = shown[index]
	local left = if ix > 0 then neighbourTop(index - N) else nil
	local right = if ix < N - 1 then neighbourTop(index + N) else nil
	local back = if iz > 0 then neighbourTop(index - 1) else nil
	local front = if iz < N - 1 then neighbourTop(index + 1) else nil

	local gx = 0
	if left and right then
		gx = (right - left) / (2 * CELL)
	elseif right then
		gx = (right - h) / CELL
	elseif left then
		gx = (h - left) / CELL
	end
	local gz = 0
	if back and front then
		gz = (front - back) / (2 * CELL)
	elseif front then
		gz = (front - h) / CELL
	elseif back then
		gz = (h - back) / CELL
	end
	gx = math.clamp(gx, -P.MaxTilt, P.MaxTilt)
	gz = math.clamp(gz, -P.MaxTilt, P.MaxTilt)

	-- Tangent along X and the surface normal give an orthonormal frame directly.
	local right3 = Vector3.new(1, gx, 0).Unit
	local up = Vector3.new(-gx, 1, -gz).Unit
	local x, z = LavaGrid.CellCenter(index)
	local thickness = parts[index].Size.Y
	-- A hair above the true surface so thin crust never z-fights the terrain.
	local top = Vector3.new(x, h + 0.06, z)
	return CFrame.fromMatrix(top - up * (thickness / 2), right3, up)
end

local function render(dt: number)
	local alpha = 1 - math.exp(-P.Smoothing * dt)
	for index in animating do
		local target = ground[index] + crust[index] + lava[index]
		local current = shown[index]
		local nextValue = current + (target - current) * alpha
		if math.abs(target - nextValue) < 0.01 then
			nextValue = target
			animating[index] = nil
		end
		shown[index] = nextValue
		placeSet[index] = true
		markNeighbours(index)
	end

	local n = 0
	for index in placeSet do
		local part = parts[index]
		if part then
			n += 1
			moveParts[n] = part
			moveCFrames[n] = slabCFrame(index)
		end
	end
	table.clear(placeSet)
	if n > 0 then
		-- Trim leftovers from a busier previous frame.
		for i = #moveParts, n + 1, -1 do
			moveParts[i] = nil
			moveCFrames[i] = nil
		end
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function LavaRenderer.Clear()
	for index in parts do
		release(index)
	end
	table.clear(animating)
	table.clear(placeSet)
	for index = 1, COUNT do
		ground[index], crust[index], lava[index], temp[index], shown[index] = 0, 0, 0, 0, 0
		styleKey[index] = -2
	end
end

function LavaRenderer.Start()
	folder = Instance.new("Folder")
	folder.Name = "MountIgnisLava"
	folder.Parent = workspace

	Net.Event("LavaDelta").OnClientEvent:Connect(function(buf: buffer)
		LavaGrid.Decode(buf, apply)
	end)
	Net.Event("LavaSnapshot").OnClientEvent:Connect(function(buf: buffer)
		LavaRenderer.Clear()
		LavaGrid.Decode(buf, apply)
	end)
	Net.Event("LavaClear").OnClientEvent:Connect(LavaRenderer.Clear)

	RunService.Heartbeat:Connect(render)
	Net.Event("LavaSnapshot"):FireServer()
end

return LavaRenderer
