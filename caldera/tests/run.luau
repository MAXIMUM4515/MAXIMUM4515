--[[
	Offline tests for the pure-Luau parts of Caldera.
	Run from the `caldera` folder with any Luau runner that provides `__loadfile`
	(see tests/README.md).
]]

local H = __loadfile("tests/harness.luau")
local test, near, check = H.test, H.near, H.check

local Config = require("src/shared/Config.luau")
local LavaSim = require("src/server/LavaSim.luau")
local LavaGrid = require("src/shared/LavaGrid.luau")
local Ballistics = require("src/shared/Ballistics.luau")
local Heightmap = require("src/shared/Heightmap.luau")
local Shelter = require("src/shared/Shelter.luau")

local P = Config.Lava
local DT = 1 / P.TickRate

local function newSim(size: number)
	return LavaSim.new(size, P, LavaGrid.Void)
end

local function idx(sim, ix: number, iz: number): number
	return ix * sim.N + iz + 1
end

local function run(sim, seconds: number, cooling: number?)
	for _ = 1, math.floor(seconds * P.TickRate) do
		sim:Step(DT, cooling or 1)
	end
end

print("LavaSim")

test("conserves volume on flat ground", function()
	local sim = newSim(40)
	sim:Add(idx(sim, 20, 20), 120, 1)
	run(sim, 30)
	near(sim:TotalVolume() + sim.Lost, 120, 1e-6, "volume")
end)

test("spreads on flat ground, then stops and freezes", function()
	local sim = newSim(60)
	sim:Add(idx(sim, 30, 30), 80, 1)
	run(sim, 10)
	check(sim:ActiveCount() > 9, "lava should have spread to many cells")
	run(sim, 240)
	check(sim:ActiveCount() == 0, `everything should have frozen, {sim:ActiveCount()} cells still molten`)
	-- Yield strength keeps the flow thick: it must not have thinned out across the whole grid.
	local covered = 0
	for i = 1, sim.Count do
		if sim.Crust[i] > 0.05 then
			covered += 1
		end
	end
	check(covered > 20 and covered < 600, `unexpected footprint {covered}`)
end)

test("flows downhill", function()
	local sim = newSim(40)
	for ix = 0, 39 do
		for iz = 0, 39 do
			sim:SetGround(idx(sim, ix, iz), (40 - ix) * 0.8)
		end
	end
	sim:Add(idx(sim, 5, 20), 40, 1)
	run(sim, 20)
	local weighted, total = 0, 0
	for i = 1, sim.Count do
		local amount = sim.Lava[i] + sim.Crust[i]
		local ix = (i - 1) // sim.N
		weighted += amount * ix
		total += amount
	end
	check(weighted / total > 12, `centre of mass should move downhill, got column {weighted / total}`)
end)

test("lava falling into the void is removed, not duplicated", function()
	local sim = newSim(20)
	for iz = 0, 19 do
		sim:SetGround(idx(sim, 19, iz), LavaGrid.Void)
	end
	for ix = 0, 18 do
		for iz = 0, 19 do
			sim:SetGround(idx(sim, ix, iz), (20 - ix) * 2)
		end
	end
	sim:Add(idx(sim, 2, 10), 50, 1)
	run(sim, 30)
	check(sim.Lost > 0, "some lava should have poured off the edge")
	near(sim:TotalVolume() + sim.Lost, 50, 1e-6, "volume")
end)

test("hot lava mixing raises the temperature of cooler lava", function()
	local sim = newSim(10)
	local i = idx(sim, 5, 5)
	sim:Add(i, 1, 0.3)
	sim:Add(i, 1, 1)
	near(sim.Temp[i], 0.65, 1e-9, "mixed temperature")
end)

test("only meaningful changes are queued for the network", function()
	local sim = newSim(10)
	local i = idx(sim, 5, 5)
	sim:Add(i, 2, 1)
	local first = sim:CollectChanges()
	check(#first == 1, "new lava must be sent")
	sim.Lava[i] += 0.01
	sim.Dirty[i] = true
	check(#sim:CollectChanges() == 0, "a 1 cm change should be skipped")
	sim.Lava[i] += 0.2
	sim.Dirty[i] = true
	check(#sim:CollectChanges() == 1, "a 21 cm change should be sent")
end)

print("LavaGrid")

test("index <-> coordinates round trip", function()
	for _, pair in { { 0, 0 }, { 159, 159 }, { 17, 92 }, { 159, 0 } } do
		local i = LavaGrid.Index(pair[1], pair[2])
		local ix, iz = LavaGrid.Coords(i)
		check(ix == pair[1] and iz == pair[2], `round trip failed for {pair[1]},{pair[2]}`)
		local x, z = LavaGrid.CellCenter(i)
		check(LavaGrid.FromWorld(x, z) == i, "world round trip failed")
	end
	check(LavaGrid.FromWorld(10000, 0) == nil, "outside the grid should be nil")
end)

test("buffer codec round trip", function()
	local ground, crust, lava, temp = {}, {}, {}, {}
	local cells = { 1, 500, 25600 }
	for n, i in cells do
		ground[i] = 87.43 - n * 50
		crust[i] = 0.5 * n
		lava[i] = 3.21 * n
		temp[i] = 0.25 * n
	end
	local buf = LavaGrid.Encode(cells, ground, crust, lava, temp)
	check(buffer.len(buf) == 2 + #cells * LavaGrid.EntrySize, "unexpected packet size")
	local seen = 0
	LavaGrid.Decode(buf, function(i, g, c, l, t)
		seen += 1
		near(g, ground[i], 0.006, "ground")
		near(c, crust[i], 0.006, "crust")
		near(l, lava[i], 0.006, "lava")
		near(t, math.min(temp[i], 1), 0.003, "temp")
	end)
	check(seen == #cells, "every cell should decode")
end)

test("decoder rejects truncated packets", function()
	local buf = buffer.create(4)
	buffer.writeu16(buf, 0, 50)
	local seen = 0
	LavaGrid.Decode(buf, function()
		seen += 1
	end)
	check(seen == 0, "truncated packet must be ignored")
end)

print("Ballistics")

test("solved launch velocity hits the target", function()
	local origin = Vector3.new(0, 110, 0)
	local target = Vector3.new(180, 2, -40)
	local gravity = Vector3.new(0, -196.2 * 0.55, 0)
	local v = Ballistics.SolveVelocity(origin, target, gravity, 4.2)
	local landed = Ballistics.PositionAt(origin, v, gravity, 4.2)
	near((landed - target).Magnitude, 0, 1e-6, "miss distance")
end)

test("trace reports the first obstruction", function()
	local origin = Vector3.new(0, 10, 0)
	local velocity = Vector3.new(20, 0, 0)
	local gravity = Vector3.new(0, 0, 0)
	-- A wall at x = 50.
	local t, result = Ballistics.Trace(origin, velocity, gravity, 10, 0.1, function(a, b)
		if a.X <= 50 and b.X >= 50 then
			return { Position = Vector3.new(50, 10, 0) } :: any
		end
		return nil
	end)
	check(result ~= nil, "should hit the wall")
	near(t, 2.5, 1e-6, "impact time")
end)

print("Heightmap")

test("volcano shape: crater below rim, breach gorge descends toward the village", function()
	local V = Config.Volcano
	local rimBack = Heightmap.Volcano(-(V.SummitRadius - 2), 0)
	local rimBreach = Heightmap.Volcano(V.SummitRadius - 2, 0)
	local floor = Heightmap.Volcano(0, 0)
	check(floor < rimBack - 10, `crater floor {floor} should sit well below the rim {rimBack}`)
	check(rimBreach < rimBack - 6, `breach {rimBreach} should be lower than the far rim {rimBack}`)
	-- The gorge must keep going downhill, or lava would pond in it and spill over the rim elsewhere.
	local previous = math.huge
	for d = V.CraterRadius, 90, 4 do
		local h = Heightmap.Volcano(d, 0)
		check(h < previous + 1.5, `breach climbs at d={d} ({h} after {previous})`)
		previous = h
	end
	check(Heightmap.Volcano(V.BaseRadius + 30, 0) == 0, "plains outside the cone")
end)

print("Shelter")

-- A scripted stand-in for workspace:Raycast. `world.roof` is what the upward probe hits and
-- `world.walls[i]` what the i-th horizontal probe (knees, chest, head) hits; nil means open air.
local function model(isShelter: boolean)
	return {
		GetAttribute = function(_, name)
			return if name == "Shelter" and isShelter then true else nil
		end,
	}
end
local function part(owner, material: string?)
	return {
		Material = material or "Enum.Material.WoodPlanks",
		IsA = function(_, className)
			return className == "BasePart"
		end,
		FindFirstAncestorOfClass = function()
			return owner
		end,
	}
end
local terrainBump = part(nil, "Enum.Material.Rock")

local function evaluate(world): boolean
	local probe = 0
	workspace = {
		Raycast = function(_, _origin, direction)
			local hit
			if direction.X == 0 and direction.Z == 0 then
				hit = world.roof
			else
				probe += 1
				hit = world.walls[probe]
			end
			return if hit then { Instance = hit } else nil
		end,
	}
	local sheltered = Shelter.Evaluate(Vector3.new(200, 4, 0), Vector3.new(0, 100, 0), {} :: any)
	workspace = nil
	return sheltered
end

local house, otherHouse, well = model(true), model(true), model(false)

test("open ground is exposed", function()
	check(not evaluate({ walls = {} }), "nothing overhead or in the way")
end)

test("terrain, rocks and loose parts never count as shelter", function()
	check(not evaluate({ roof = terrainBump, walls = { terrainBump, terrainBump, terrainBump } }), "terrain")
	local wellPart = part(well, "Enum.Material.Cobblestone")
	check(not evaluate({ roof = wellPart, walls = { wellPart, wellPart, wellPart } }), "the well")
end)

test("inside a house behind a solid wall is sheltered", function()
	check(evaluate({ roof = part(house), walls = { part(house), part(house), part(house) } }), "solid wall")
end)

test("glass does not stop the flow, but a window's sill and lintel still count", function()
	local glass = part(house, "Enum.Material.Glass")
	check(evaluate({ roof = part(house), walls = { part(house), glass, part(house) } }), "behind a window")
	check(not evaluate({ roof = part(house), walls = { glass, glass, part(house) } }), "mostly glass")
end)

test("an open doorway facing the volcano is exposed", function()
	check(not evaluate({ roof = part(house), walls = { nil, nil, part(house) } }), "doorway")
end)

test("a wall needs a roof over it, from the same building", function()
	check(not evaluate({ walls = { part(house), part(house), part(house) } }), "behind a house, no roof")
	check(
		not evaluate({ roof = part(otherHouse), walls = { part(house), part(house), part(house) } }),
		"mixed buildings"
	)
end)

print("Scenario: a full eruption on the generated volcano")

test("main flow leaves through the breach and reaches the village, but not the far side", function()
	local sim = newSim(LavaGrid.N)
	for i = 1, sim.Count do
		local x, z = LavaGrid.CellCenter(i)
		sim:SetGround(i, Heightmap.Height(x, z))
	end
	local V = Config.Volcano
	local vents = LavaGrid.CellsInRadius(V.Center.X, V.Center.Z, P.VentRadius)
	local village = Config.Map.VillageCenter

	local eruption = Config.Round.Phases[2].Duration
	local pyro = Config.Round.Phases[3].Duration
	local aftermath = Config.Round.Phases[4].Duration
	local steps = math.floor((eruption + pyro + aftermath) * P.TickRate)
	local reachedVillageAt = nil
	local maxSent = 0
	for step = 1, steps do
		local t = step * DT
		local rate = if t < eruption then P.VentRate elseif t < eruption + pyro then P.VentRate * 0.35 else 0
		for _, i in vents do
			sim:Add(i, rate * DT / #vents, 1)
		end
		sim:Step(DT, if t < eruption + pyro then 1 else P.AftermathCooling)
		if step % P.SendEvery == 0 then
			maxSent = math.max(maxSent, #sim:CollectChanges())
		end
		if not reachedVillageAt then
			for i in sim.Active do
				local x, _ = LavaGrid.CellCenter(i)
				if x > village.X - Config.Map.VillageRadius - 10 then
					reachedVillageAt = t
					break
				end
			end
		end
	end

	local farthestEast, farthestOther = 0, 0
	local covered = 0
	local hottestOutsideCrater = 0
	for i in sim.Active do
		local x, z = LavaGrid.CellCenter(i)
		if math.sqrt(x * x + z * z) > V.SummitRadius + 30 then
			hottestOutsideCrater = math.max(hottestOutsideCrater, sim.Temp[i])
		end
	end
	for i = 1, sim.Count do
		if sim.Lava[i] + sim.Crust[i] > 0.1 then
			covered += 1
			local x, z = LavaGrid.CellCenter(i)
			local d = math.sqrt(x * x + z * z)
			if x > math.abs(z) then
				farthestEast = math.max(farthestEast, d)
			else
				farthestOther = math.max(farthestOther, d)
			end
		end
	end
	print(
		`       village reached at {reachedVillageAt and string.format("%.1f", reachedVillageAt) or "never"}s,`
			.. ` east reach {math.floor(farthestEast)}, other reach {math.floor(farthestOther)},`
			.. ` covered cells {covered}, still molten {sim:ActiveCount()}, busiest tick {maxSent} cells`
			.. ` ({maxSent * LavaGrid.EntrySize} bytes)`
	)
	check(
		reachedVillageAt ~= nil and reachedVillageAt < eruption + pyro,
		"lava should reach the village during the round"
	)
	check(farthestOther < V.SummitRadius + 30, `lava escaped the wrong side of the crater ({farthestOther})`)
	check(farthestEast < village.X + Config.Map.VillageRadius + 60, `lava ran far past the village ({farthestEast})`)
	check(
		hottestOutsideCrater < P.HarmfulTemp + 0.1,
		`the aftermath should crust over the flow outside the crater (hottest {hottestOutsideCrater})`
	)
end)

H.finish()
