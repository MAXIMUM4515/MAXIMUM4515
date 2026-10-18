--[[
	Combustion
	Heat-based fire spread. Flammable parts collect heat from nearby flames (more from flames
	below them, since fire climbs) and ignite once they pass a threshold. Burning parts char,
	run out of fuel and then give way, which hands them over to Structures for collapse.

	Ignition sources: lava bombs, molten lava touching a building, the pyroclastic flow,
	and other burning parts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Structures = require(script.Parent.Structures)

local F = Config.Fire

local Combustion = {}

type FireState = {
	Heat: number,
	Burning: boolean,
	Burnt: boolean,
	Fuel: number,
	MaxFuel: number,
	Flammability: number,
	BaseColor: Color3,
	Effects: { Instance },
}

local states: { [BasePart]: FireState } = {}
local burning: { BasePart } = {}
local heated: { [BasePart]: boolean } = {}
local folders: { Structures: Folder, Nature: Folder, Props: Folder }
local rng = Random.new()
local lightToggle = 0

local spreadParams = OverlapParams.new()
spreadParams.FilterType = Enum.RaycastFilterType.Include

-- Bumped whenever the burning set changes, so Hazards knows when to refresh its query list.
Combustion.Version = 0

local function isFoliage(part: BasePart): boolean
	return part.Material == Enum.Material.Grass or part.Material == Enum.Material.LeafyGrass
end

function Combustion.Track(part: BasePart)
	local flammability = F.Flammability[part.Material]
	if not flammability or states[part] then
		return
	end
	-- Bigger parts carry more fuel and burn for longer.
	local scale = math.clamp((part.Size.X * part.Size.Y * part.Size.Z) ^ (1 / 3) / 4, 0.6, 2)
	local fuel = (F.Fuel[part.Material] or 10) * scale * rng:NextNumber(0.8, 1.2)
	states[part] = {
		Heat = 0,
		Burning = false,
		Burnt = false,
		Fuel = fuel,
		MaxFuel = fuel,
		Flammability = flammability,
		BaseColor = part.Color,
		Effects = {},
	}
end

function Combustion.RegisterAll()
	for _, root in { folders.Structures, folders.Nature, folders.Props } do
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("BasePart") then
				Combustion.Track(descendant)
			end
		end
	end
end

function Combustion.IsBurning(part: BasePart): boolean
	local state = states[part]
	return state ~= nil and state.Burning
end

function Combustion.BurningParts(): { BasePart }
	return burning
end

function Combustion.Ignite(part: BasePart): boolean
	local state = states[part]
	if not state or state.Burning or state.Burnt or not part.Parent then
		return false
	end
	if #burning >= F.MaxBurning then
		return false
	end
	state.Burning = true
	state.Heat = 1
	heated[part] = nil
	part:SetAttribute("Burning", true)
	table.insert(burning, part)
	Combustion.Version += 1

	local largest = math.max(part.Size.X, part.Size.Y, part.Size.Z)
	local fire = Instance.new("Fire")
	fire.Size = math.clamp(largest * 0.8, 3, 14)
	fire.Heat = math.clamp(largest, 6, 14)
	fire.Color = Color3.fromRGB(255, 142, 44)
	fire.SecondaryColor = Color3.fromRGB(255, 62, 12)
	fire.Parent = part
	table.insert(state.Effects, fire)

	-- Only some fires cast light; dozens of overlapping lights cost a lot and add little.
	lightToggle += 1
	if lightToggle % 3 == 0 then
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 136, 60)
		light.Range = 16
		light.Brightness = 1.6
		light.Shadows = false
		light.Parent = part
		table.insert(state.Effects, light)
	end
	return true
end

-- Adds heat; ignites when it crosses 1. Returns true if the part caught fire.
function Combustion.AddHeat(part: BasePart, amount: number): boolean
	local state = states[part]
	if not state or state.Burning or state.Burnt then
		return false
	end
	state.Heat += amount * state.Flammability
	if state.Heat >= 1 then
		return Combustion.Ignite(part)
	end
	heated[part] = true
	return false
end

local function smolder(part: BasePart)
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(60, 56, 54)
	smoke.Opacity = 0.12
	smoke.RiseVelocity = 4
	smoke.Size = 3
	smoke.Parent = part
	task.delay(8, function()
		smoke.Enabled = false
		task.wait(3)
		smoke:Destroy()
	end)
end

local function burnOut(part: BasePart, state: FireState)
	state.Burning = false
	state.Burnt = true
	part:SetAttribute("Burning", nil)
	for _, effect in state.Effects do
		effect:Destroy()
	end
	table.clear(state.Effects)
	part.Color = F.CharColor
	Combustion.Version += 1

	if isFoliage(part) then
		Structures.Remove(part)
	elseif Structures.IsTracked(part) then
		-- Burnt timber can no longer carry load.
		smolder(part)
		Structures.Damage(part, math.huge)
	elseif not part.Anchored then
		-- Loose props crumble to nothing.
		task.delay(1.5, function()
			part:Destroy()
		end)
	end
end

local function step(dt: number)
	spreadParams.FilterDescendantsInstances = { folders.Structures, folders.Nature, folders.Props }

	for i = #burning, 1, -1 do
		local part = burning[i]
		local state = states[part]
		if not part.Parent or not state then
			table.remove(burning, i)
			Combustion.Version += 1
			continue
		end

		state.Fuel -= dt
		local spent = 1 - math.clamp(state.Fuel / state.MaxFuel, 0, 1)
		part.Color = state.BaseColor:Lerp(F.CharColor, spent * 0.85)

		-- Radiate heat to anything flammable nearby.
		local reach = F.SpreadRadius + math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.25
		for _, other in workspace:GetPartBoundsInRadius(part.Position, reach, spreadParams) do
			if other ~= part and states[other] then
				local distance = (other.Position - part.Position).Magnitude
				local closeness = 1 - math.clamp(distance / reach, 0, 1)
				local climb = if other.Position.Y > part.Position.Y + 1 then 1.7 else 1
				Combustion.AddHeat(other, F.SpreadHeat * dt * (0.35 + closeness) * climb)
			end
		end

		if state.Fuel <= 0 then
			table.remove(burning, i)
			burnOut(part, state)
		end
	end

	-- Parts that were warmed but never caught slowly cool back down.
	for part in heated do
		local state = states[part]
		if not state or state.Burning then
			heated[part] = nil
		else
			state.Heat = math.max(0, state.Heat - 0.04 * dt)
			if state.Heat == 0 then
				heated[part] = nil
			end
		end
	end
end

local igniteParams = OverlapParams.new()
igniteParams.FilterType = Enum.RaycastFilterType.Include

-- Ignites flammable parts in a sphere, each with the given chance.
function Combustion.IgniteRadius(position: Vector3, radius: number, chance: number)
	igniteParams.FilterDescendantsInstances = { folders.Structures, folders.Nature, folders.Props }
	for _, part in workspace:GetPartBoundsInRadius(position, radius, igniteParams) do
		if states[part] and rng:NextNumber() < chance then
			Combustion.Ignite(part)
		end
	end
end

-- Heats everything flammable inside a box (used where molten lava meets buildings).
function Combustion.HeatBox(cframe: CFrame, size: Vector3, heat: number)
	igniteParams.FilterDescendantsInstances = { folders.Structures, folders.Nature, folders.Props }
	for _, part in workspace:GetPartBoundsInBox(cframe, size, igniteParams) do
		if states[part] then
			Combustion.AddHeat(part, heat)
		end
	end
end

function Combustion.Init(mapFolders: { Structures: Folder, Nature: Folder, Props: Folder })
	folders = mapFolders
	task.spawn(function()
		while true do
			local dt = task.wait(F.TickInterval)
			local ok, err = pcall(step, dt)
			if not ok then
				warn("[Combustion]", err)
			end
		end
	end)
end

function Combustion.Reset()
	for _, part in burning do
		local state = states[part]
		if state then
			for _, effect in state.Effects do
				effect:Destroy()
			end
		end
	end
	table.clear(burning)
	table.clear(states)
	table.clear(heated)
	Combustion.Version += 1
end

return Combustion
