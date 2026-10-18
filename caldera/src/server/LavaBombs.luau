--[[
	LavaBombs
	Server-authoritative volcanic bombs. The server picks a target, solves the launch velocity,
	traces the arc against the world to find the real impact point, and tells clients the arc.
	Clients animate it from the shared Ballistics formula and the synced server clock, so no
	projectile is ever replicated and the impact a player sees is the one that hurts them.

	Impacts: blast damage and knockback, structural damage, fires, a splash of molten lava,
	a crater in the terrain and a scorch mark.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Ballistics = require(Shared.Ballistics)
local Net = require(Shared.Net)
local Hazards = require(script.Parent.Hazards)
local Structures = require(script.Parent.Structures)
local Combustion = require(script.Parent.Combustion)
local LavaFlow = require(script.Parent.LavaFlow)
local MapBuilder = require(script.Parent.MapBuilder)

local B = Config.Bombs

local LavaBombs = {}

local launchedEvent = Net.Event("BombLaunched")
local rng = Random.new()
local nextId = 0

local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Include
castParams.IgnoreWater = false

local pushParams = OverlapParams.new()
pushParams.FilterType = Enum.RaycastFilterType.Include

local folders

local function gravity(): Vector3
	return Vector3.new(0, -workspace.Gravity * B.GravityScale, 0)
end

local function cast(from: Vector3, to: Vector3): RaycastResult?
	return workspace:Raycast(from, to - from, castParams)
end

-- Turns grass and dirt around an impact into scorched ground, voxel by voxel in a circle.
local function scorch(position: Vector3, radius: number)
	local extent = Vector3.new(radius, 4, radius)
	local region = Region3.new(position - extent, position + extent):ExpandToGrid(4)
	local terrain = workspace.Terrain
	local materials, occupancies = terrain:ReadVoxels(region, 4)
	local size = materials.Size
	local corner = region.CFrame.Position - region.Size / 2
	local changed = false
	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				local material = materials[x][y][z]
				if
					material == Enum.Material.Grass
					or material == Enum.Material.LeafyGrass
					or material == Enum.Material.Ground
				then
					local center = corner + Vector3.new(x - 0.5, y - 0.5, z - 0.5) * 4
					local dx, dz = center.X - position.X, center.Z - position.Z
					if dx * dx + dz * dz <= radius * radius then
						materials[x][y][z] = if rng:NextNumber() < 0.6
							then Enum.Material.Basalt
							else Enum.Material.Ground
						changed = true
					end
				end
			end
		end
	end
	if changed then
		terrain:WriteVoxels(region, 4, materials, occupancies)
	end
end

local function impact(position: Vector3, hit: Instance?, size: number)
	local scale = size / B.Size.Max
	local radius = B.BlastRadius * (0.7 + 0.3 * scale)

	Hazards.Explode(position, radius, B.Damage * (0.75 + 0.25 * scale), B.Knockback, "a lava bomb", {
		workspace.Terrain,
		folders.Structures,
	})
	Structures.DamageRadius(position, radius * 0.8, B.StructureDamage, 45)
	Combustion.IgniteRadius(position, radius * 0.65, B.IgniteChance)
	LavaFlow.Splash(position, B.BombSplat * scale, 4)

	-- Throw loose props and debris around.
	pushParams.FilterDescendantsInstances = { folders.Props, folders.Debris }
	for _, part in workspace:GetPartBoundsInRadius(position, radius * 1.2, pushParams) do
		if not part.Anchored then
			local offset = part.Position - position
			local falloff = 1 - math.clamp(offset.Magnitude / (radius * 1.2), 0, 1)
			local direction = if offset.Magnitude > 0.1 then offset.Unit else Vector3.yAxis
			part.AssemblyLinearVelocity += (direction + Vector3.new(0, 0.6, 0)) * 60 * falloff
		end
	end

	if hit == workspace.Terrain then
		workspace.Terrain:FillBall(position, B.CraterRadius * (0.7 + 0.3 * scale), Enum.Material.Air)
		scorch(position, B.ScorchRadius)
		MapBuilder.MarkTerrainDirty(position, B.ScorchRadius + 4)
		LavaFlow.RefreshGround(position, B.CraterRadius + 4)
	end
end

--[[
	Fires one bomb from `origin` that would land on `target` after `flightTime` seconds, unless
	something gets in the way first.
]]
function LavaBombs.Launch(origin: Vector3, target: Vector3, flightTime: number, size: number)
	local g = gravity()
	local velocity = Ballistics.SolveVelocity(origin, target, g, flightTime)
	local hitTime, result = Ballistics.Trace(origin, velocity, g, flightTime * 1.6, 1 / 20, cast)
	local impactPosition = if result then result.Position else Ballistics.PositionAt(origin, velocity, g, hitTime)
	local normal = if result then result.Normal else Vector3.yAxis

	nextId += 1
	launchedEvent:FireAllClients({
		Id = nextId,
		Origin = origin,
		Velocity = velocity,
		Gravity = g,
		Start = workspace:GetServerTimeNow(),
		Duration = hitTime,
		Impact = impactPosition,
		Normal = normal,
		Size = size,
		Radius = B.BlastRadius,
	})

	local hit = if result then result.Instance else nil
	task.delay(hitTime, function()
		local ok, err = pcall(impact, impactPosition, hit, size)
		if not ok then
			warn("[LavaBombs] impact failed:", err)
		end
	end)
end

local function groundPoint(x: number, z: number): Vector3?
	local result = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), castParams)
	return if result then result.Position else nil
end

-- Picks a target: sometimes a player (leading their movement), otherwise somewhere around the volcano.
function LavaBombs.PickTarget(center: Vector3, flightTime: number, participants: { BasePart }): Vector3?
	if #participants > 0 and rng:NextNumber() < B.TargetPlayerChance then
		local root = participants[rng:NextInteger(1, #participants)]
		local velocity = root.AssemblyLinearVelocity
		local lead = Vector3.new(velocity.X, 0, velocity.Z) * flightTime * B.LeadFactor
		local angle = rng:NextNumber(0, math.pi * 2)
		local spread = math.sqrt(rng:NextNumber()) * B.Inaccuracy
		local aim = root.Position + lead + Vector3.new(math.cos(angle) * spread, 0, math.sin(angle) * spread)
		return groundPoint(aim.X, aim.Z)
	end

	-- Uniform over the ring area, weighted toward the village side.
	local angle = if rng:NextNumber() < 0.5 then rng:NextNumber(-1, 1) else rng:NextNumber(-math.pi, math.pi)
	local inner, outer = B.ScatterRadius.Min, B.ScatterRadius.Max
	local distance = math.sqrt(rng:NextNumber(inner * inner, outer * outer))
	return groundPoint(center.X + math.cos(angle) * distance, center.Z + math.sin(angle) * distance)
end

function LavaBombs.Init(mapFolders)
	folders = mapFolders
	castParams.FilterDescendantsInstances = {
		workspace.Terrain,
		mapFolders.Structures,
		mapFolders.Nature,
		mapFolders.Props,
	}
end

return LavaBombs
