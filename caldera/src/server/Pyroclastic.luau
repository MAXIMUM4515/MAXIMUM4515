--[[
	Pyroclastic
	A searing avalanche of ash and gas that bursts from the crater and races outward across a
	wide sector. It is the climax of the eruption and the one hazard you cannot outrun:
	you survive it by getting solid geometry between you and the volcano.

	The front is an expanding arc. Everything is pre-sorted by distance from the crater, so as
	the radius grows the server simply walks a pointer through the list instead of scanning
	the map every tick.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Shelter = require(Shared.Shelter)
local Hazards = require(script.Parent.Hazards)
local Structures = require(script.Parent.Structures)
local Combustion = require(script.Parent.Combustion)

local PF = Config.Pyroclastic
local PL = Config.Player

local Pyroclastic = {}

local flowEvent = Net.Event("Pyroclastic")
local announceEvent = Net.Event("Announce")
local rng = Random.new()
local folders
local running: thread? = nil

local shelterParams = RaycastParams.new()
shelterParams.FilterType = Enum.RaycastFilterType.Include

local function horizontal(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function inSector(offset: Vector3, direction: Vector3): boolean
	local flat = horizontal(offset)
	if flat.Magnitude < 1 then
		return true
	end
	return flat.Unit:Dot(direction) >= math.cos(PF.HalfAngle)
end

-- Aims at the middle of the survivors so the flow always threatens someone.
function Pyroclastic.ChooseDirection(origin: Vector3, fallback: Vector3): Vector3
	local sum = Vector3.zero
	local count = 0
	for _, state in Hazards.Participants() do
		local flat = horizontal(state.Root.Position - origin)
		if flat.Magnitude > 1 then
			sum += flat.Unit
			count += 1
		end
	end
	if count > 0 and sum.Magnitude > 0.2 then
		return sum.Unit
	end
	return horizontal(fallback).Unit
end

type Entry = { Part: BasePart, Distance: number }

local function collectEnvironment(origin: Vector3, direction: Vector3): { Entry }
	local entries = {}
	for _, root in { folders.Structures, folders.Nature, folders.Props } do
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("BasePart") then
				local offset = descendant.Position - origin
				if inSector(offset, direction) then
					table.insert(entries, { Part = descendant, Distance = horizontal(offset).Magnitude })
				end
			end
		end
	end
	table.sort(entries, function(a, b)
		return a.Distance < b.Distance
	end)
	return entries
end

local function strikeEnvironment(part: BasePart, origin: Vector3)
	if not part.Parent then
		return
	end
	local outward = horizontal(part.Position - origin)
	outward = if outward.Magnitude > 0.1 then outward.Unit else Vector3.xAxis
	if not part.Anchored then
		part.AssemblyLinearVelocity += outward * PF.PropForce + Vector3.new(0, PF.PropForce * 0.35, 0)
	end
	if not Combustion.IsBurning(part) and rng:NextNumber() < PF.IgniteChance then
		Combustion.Ignite(part)
	end
	if Structures.IsTracked(part) then
		Structures.Damage(part, PF.StructureDamage * rng:NextNumber(0.6, 1.4), outward * 30)
	end
end

local function strikePlayer(state, origin: Vector3)
	local sheltered = Shelter.Evaluate(state.Root.Position, origin, shelterParams)
	if sheltered then
		Hazards.Damage(state.Humanoid, PF.ShelteredDamage, "the pyroclastic flow")
		announceEvent:FireClient(state.Player, "Your shelter held!", Config.Colors.Good, 2.5, "small")
	else
		Hazards.Damage(state.Humanoid, PF.Damage, "the pyroclastic flow")
		Hazards.SetOnFire(state, PL.BurnDuration + 2, "the pyroclastic flow")
		local outward = horizontal(state.Root.Position - origin)
		outward = if outward.Magnitude > 0.1 then outward.Unit else Vector3.xAxis
		Hazards.Knockback(state.Player, outward * PF.Knockback + Vector3.new(0, PF.Knockback * 0.4, 0), true)
		announceEvent:FireClient(state.Player, "Caught in the open!", Config.Colors.Bad, 2.5, "small")
	end
end

function Pyroclastic.Launch(origin: Vector3, fallbackDirection: Vector3)
	Pyroclastic.Stop()
	local direction = Pyroclastic.ChooseDirection(origin, fallbackDirection)
	local startTime = workspace:GetServerTimeNow() + PF.WarnTime
	local startRadius = Config.Volcano.CraterRadius

	flowEvent:FireAllClients({
		Origin = origin,
		Direction = direction,
		HalfAngle = PF.HalfAngle,
		Start = startTime,
		Speed = PF.Speed,
		StartRadius = startRadius,
		MaxRadius = PF.MaxRadius,
	})

	running = task.spawn(function()
		local environment = collectEnvironment(origin, direction)
		local pointer = 1
		local struck: { [Model]: boolean } = {}
		local duration = (PF.MaxRadius - startRadius) / PF.Speed

		while true do
			local elapsed = workspace:GetServerTimeNow() - startTime
			if elapsed > duration then
				break
			end
			if elapsed >= 0 then
				local radius = startRadius + PF.Speed * elapsed

				while pointer <= #environment and environment[pointer].Distance <= radius do
					strikeEnvironment(environment[pointer].Part, origin)
					pointer += 1
				end

				for _, state in Hazards.Alive() do
					if not struck[state.Character] then
						local offset = state.Root.Position - origin
						if horizontal(offset).Magnitude <= radius and inSector(offset, direction) then
							struck[state.Character] = true
							strikePlayer(state, origin)
						end
					end
				end
			end
			task.wait(0.1)
		end
		running = nil
	end)
end

function Pyroclastic.Stop()
	if running then
		pcall(task.cancel, running)
		running = nil
	end
end

function Pyroclastic.Init(mapFolders)
	folders = mapFolders
	shelterParams.FilterDescendantsInstances = { workspace.Terrain, mapFolders.Structures }
end

return Pyroclastic
