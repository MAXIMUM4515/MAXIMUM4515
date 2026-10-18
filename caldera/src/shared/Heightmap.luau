--[[
	Heightmap
	Deterministic surface height for the generated map: rolling plains, a stratovolcano with a
	crater, a breach in the crater rim that funnels lava toward the village, and a village pond.

	It is a pure function of (x, z) so the terrain generator, the offline lava tests and any
	future tooling all agree on the exact same shape.
]]

local Config = require(script.Parent.Config)

local V = Config.Volcano
local M = Config.Map

local CX, CZ = V.Center.X, V.Center.Z
local SEED = M.Seed % 1000 + 0.37

local Heightmap = {}

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function angleDelta(a: number, b: number): number
	local d = (a - b + math.pi) % (2 * math.pi) - math.pi
	return d
end

Heightmap.Smoothstep = smoothstep

-- Height of the volcano alone (0 outside its footprint).
function Heightmap.Volcano(x: number, z: number): number
	local dx, dz = x - CX, z - CZ
	local rawDistance = math.sqrt(dx * dx + dz * dz)
	if rawDistance > V.BaseRadius + 24 then
		return 0
	end
	-- Warp the radius a little so the cone is not a perfect circle.
	local d = rawDistance + math.noise(x / 70, z / 70, SEED) * 9
	local angle = math.atan2(dz, dx)

	local height
	if d >= V.BaseRadius then
		height = 0
	elseif d <= V.SummitRadius then
		height = V.Height
		-- Crater bowl: flat floor, steep walls, narrow rim plateau.
		if d < V.CraterRadius then
			local wall = smoothstep(V.CraterRadius * 0.6, V.CraterRadius, d)
			height = V.Height - V.CraterDepth * (1 - wall)
		end
	else
		local u = (d - V.SummitRadius) / (V.BaseRadius - V.SummitRadius)
		height = V.Height * (1 - u) ^ V.Profile
	end

	-- Breach: a gorge cut through the rim that keeps descending, then a shallow channel down the flank.
	-- The descent matters: a flat-floored notch would choke the outflow and flood the crater over its rim.
	local breach = V.Breach
	local delta = angleDelta(angle, breach.Angle)
	local notch = math.exp(-(delta / breach.Width) ^ 2)
	local cutFloor = V.Height - breach.Depth - math.max(0, d - V.CraterRadius * 0.6) * breach.Slope
	if height > cutFloor and d > V.CraterRadius * 0.6 then
		height -= (height - cutFloor) * notch
	end
	if d > V.SummitRadius and d < V.BaseRadius * 1.05 then
		local channel = math.exp(-(delta / breach.ChannelWidth) ^ 2)
		local fade = smoothstep(V.SummitRadius, V.SummitRadius + 10, d)
			* (1 - smoothstep(V.BaseRadius * 0.8, V.BaseRadius * 1.05, d))
		height -= breach.ChannelDepth * channel * fade
	end

	-- Surface roughness, strongest on the mid flanks.
	local flank = smoothstep(V.SummitRadius, V.SummitRadius + 20, d)
		* (1 - smoothstep(V.BaseRadius * 0.85, V.BaseRadius, d))
	height += math.noise(x / 24, z / 24, SEED + 3.1) * V.SurfaceNoise * flank

	return math.max(height, 0)
end

-- Depth of the pond bowl at (x, z), 0 outside it.
function Heightmap.Pond(x: number, z: number): number
	local pond = M.Pond
	local dx, dz = x - pond.Center.X, z - pond.Center.Z
	local d = math.sqrt(dx * dx + dz * dz) / pond.Radius
	if d >= 1 then
		return 0
	end
	return pond.Depth * (1 - d * d)
end

function Heightmap.Height(x: number, z: number): number
	local plains = math.noise(x / 90, z / 90, SEED + 7.7) * M.PlainsNoise
	-- Flatten the village square so buildings sit level.
	local vc = M.VillageCenter
	local vdx, vdz = x - vc.X, z - vc.Z
	local villageFlat = 1 - smoothstep(M.VillageRadius + 10, M.VillageRadius + 40, math.sqrt(vdx * vdx + vdz * vdz))
	plains *= 1 - 0.8 * villageFlat
	return plains + Heightmap.Volcano(x, z) - Heightmap.Pond(x, z)
end

-- Surface material for a column. `cone` is the volcano's contribution to the height.
function Heightmap.SurfaceMaterial(x: number, z: number): Enum.Material
	local cone = Heightmap.Volcano(x, z)
	local pond = Heightmap.Pond(x, z)
	if pond > 0.8 then
		return Enum.Material.Mud
	elseif pond > 0 then
		return Enum.Material.Sand
	end
	local f = cone / V.Height
	local n = math.noise(x / 18, z / 18, SEED + 11.3) * 0.12
	if f + n > 0.72 then
		return Enum.Material.Basalt
	elseif f + n > 0.42 then
		return Enum.Material.Rock
	elseif f + n > 0.12 then
		return Enum.Material.Ground
	end
	if math.noise(x / 40, z / 40, SEED + 2.2) > 0.32 then
		return Enum.Material.LeafyGrass
	end
	return Enum.Material.Grass
end

function Heightmap.DeepMaterial(x: number, z: number): Enum.Material
	if Heightmap.Volcano(x, z) > V.Height * 0.4 then
		return Enum.Material.Basalt
	end
	return Enum.Material.Rock
end

return Heightmap
