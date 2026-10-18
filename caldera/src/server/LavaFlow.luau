--[[
	LavaFlow
	Runs the LavaSim on a fixed tick, feeds it from vents, streams changes to clients as
	packed buffers, and lets other systems ask "how much lava is here?".

	The ground under every cell is found by raycasting against terrain and buildings, so lava
	naturally flows around houses (a house cell's "ground" is its roof). When a building
	collapses, the cells under it are re-sampled and lava can pour into the gap.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local LavaGrid = require(Shared.LavaGrid)
local Net = require(Shared.Net)
local Signal = require(Shared.Signal)
local LavaSim = require(script.Parent.LavaSim)

local P = Config.Lava
local STEP = 1 / P.TickRate
local MAX_STEPS_PER_FRAME = 3
local HEAT_CHECKS_PER_STEP = 24

local LavaFlow = {}

LavaFlow.Sim = LavaSim.new(LavaGrid.N, P :: any, LavaGrid.Void)

-- Fired with (cframe, size) for freshly molten cells so fire can catch on whatever they touch.
LavaFlow.Scorching = Signal.new()

export type Source = {
	Cells: { number },
	Rate: number,
	Temperature: number,
}

local sim = LavaFlow.Sim
local sources: { Source } = {}
local cooling = 1
local accumulator = 0
local stepCount = 0

local heatQueue: { number } = {}
local heatQueued: { [number]: boolean } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.IgnoreWater = true

local deltaEvent = Net.Event("LavaDelta")
local clearEvent = Net.Event("LavaClear")
local snapshotEvent = Net.Event("LavaSnapshot")
local lastSnapshot: { [Player]: number } = {}

local function sampleGround(index: number): number
	local x, z = LavaGrid.CellCenter(index)
	local result = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), groundParams)
	return if result then result.Position.Y else LavaGrid.Void
end

-- Re-samples every cell. Yields periodically; takes a fraction of a second.
function LavaFlow.RebuildGround()
	local started = os.clock()
	for index = 1, LavaGrid.Count do
		sim:SetGround(index, sampleGround(index))
		if index % 3000 == 0 then
			task.wait()
		end
	end
	if Config.Debug.Verbose then
		print(`[LavaFlow] ground rebuilt in {math.floor((os.clock() - started) * 1000)} ms`)
	end
end

function LavaFlow.RefreshGround(position: Vector3, radius: number)
	for _, index in LavaGrid.CellsInRadius(position.X, position.Z, radius) do
		sim:SetGround(index, sampleGround(index))
	end
end

function LavaFlow.AddSource(position: Vector3, radius: number, rate: number): Source
	local source: Source = {
		Cells = LavaGrid.CellsInRadius(position.X, position.Z, radius),
		Rate = rate,
		Temperature = 1,
	}
	table.insert(sources, source)
	return source
end

function LavaFlow.RemoveSource(source: Source)
	local index = table.find(sources, source)
	if index then
		table.remove(sources, index)
	end
end

-- A one-off splash of lava (bomb impacts).
function LavaFlow.Splash(position: Vector3, amount: number, radius: number)
	local cells = LavaGrid.CellsInRadius(position.X, position.Z, radius)
	for _, index in cells do
		sim:Add(index, amount / #cells, 1)
	end
end

function LavaFlow.SetCooling(multiplier: number)
	cooling = multiplier
end

--[[
	Returns surfaceY, moltenDepth, temperature, crustTopY for the cell under a position,
	or nil outside the grid.
]]
function LavaFlow.Sample(position: Vector3): (number?, number, number, number)
	local index = LavaGrid.FromWorld(position.X, position.Z)
	if not index then
		return nil, 0, 0, 0
	end
	local ground = sim.Ground[index]
	if ground <= LavaGrid.Void then
		return nil, 0, 0, 0
	end
	local crustTop = ground + sim.Crust[index]
	return crustTop + sim.Lava[index], sim.Lava[index], sim.Temp[index], crustTop
end

local function queueHeatChecks(changed: { number })
	for _, index in changed do
		if not heatQueued[index] and sim.Lava[index] > P.HarmfulDepth and sim.Temp[index] > 0.45 then
			heatQueued[index] = true
			table.insert(heatQueue, index)
		end
	end
end

local function processHeatChecks()
	local count = math.min(#heatQueue, HEAT_CHECKS_PER_STEP)
	for _ = 1, count do
		local index = table.remove(heatQueue) :: number
		local x, z = LavaGrid.CellCenter(index)
		local surface = sim.Ground[index] + sim.Crust[index] + sim.Lava[index]
		-- A box a little wider than the cell, reaching a few studs above the surface,
		-- catches walls the lava is pressing against.
		LavaFlow.Scorching:Fire(CFrame.new(x, surface, z), Vector3.new(P.CellSize + 3, 7, P.CellSize + 3))
	end
end

local function tick()
	for _, source in sources do
		if source.Rate > 0 and #source.Cells > 0 then
			local each = source.Rate * STEP / #source.Cells
			for _, index in source.Cells do
				sim:Add(index, each, source.Temperature)
			end
		end
	end

	sim:Step(STEP, cooling)
	stepCount += 1

	if stepCount % P.SendEvery == 0 then
		local changed = sim:CollectChanges()
		if #changed > 0 then
			deltaEvent:FireAllClients(LavaGrid.Encode(changed, sim.Ground, sim.Crust, sim.Lava, sim.Temp))
			queueHeatChecks(changed)
		end
	end
	processHeatChecks()
end

function LavaFlow.Init(groundRoots: { Instance })
	groundParams.FilterDescendantsInstances = groundRoots

	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		local steps = 0
		while accumulator >= STEP and steps < MAX_STEPS_PER_FRAME do
			accumulator -= STEP
			steps += 1
			local started = os.clock()
			tick()
			if Config.Debug.Verbose and stepCount % (P.TickRate * 5) == 0 then
				print(
					`[LavaFlow] step {math.floor((os.clock() - started) * 10000) / 10} ms, {sim:ActiveCount()} molten cells`
				)
			end
		end
		-- If the server stalls, drop the backlog instead of fast-forwarding.
		if accumulator > STEP * MAX_STEPS_PER_FRAME then
			accumulator = 0
		end
	end)

	-- Players who join mid-eruption ask for the full state once.
	snapshotEvent.OnServerEvent:Connect(function(player)
		local now = os.clock()
		if lastSnapshot[player] and now - lastSnapshot[player] < 5 then
			return
		end
		lastSnapshot[player] = now
		snapshotEvent:FireClient(player, LavaGrid.Encode(sim:Snapshot(), sim.Ground, sim.Crust, sim.Lava, sim.Temp))
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastSnapshot[player] = nil
	end)
end

function LavaFlow.Reset()
	table.clear(sources)
	table.clear(heatQueue)
	table.clear(heatQueued)
	sim:Clear()
	cooling = 1
	clearEvent:FireAllClients()
end

return LavaFlow
