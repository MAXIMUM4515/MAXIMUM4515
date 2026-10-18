--[[
	Structures
	Health, collapse and structural support for buildings and trees.

	Every registered group (a house, a tree, ...) gets a support graph built from which parts
	touch which. A part stays up only while a chain of intact parts connects it to something
	grounded. When a wall burns through or a bomb blows out a corner, a breadth-first search
	from the grounded parts finds everything that just lost support and drops it, with a short
	random delay so buildings crumble instead of vanishing in one frame.
]]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Signal = require(Shared.Signal)

local S = Config.Structures

local Structures = {}

-- Fired with (part, position) whenever something collapses; LavaFlow listens to re-scan the ground.
Structures.Collapsed = Signal.new()

type State = {
	Health: number,
	MaxHealth: number,
	Group: Instance,
	Neighbors: { BasePart },
	Grounded: boolean,
	Destroyed: boolean,
	BaseColor: Color3,
}

local states: { [BasePart]: State } = {}
local groups: { [Instance]: { BasePart } } = {}
local pendingChecks: { [Instance]: boolean } = {}
local fragile: { BasePart } = {}
local debrisQueue: { BasePart } = {}

local folders: { Structures: Folder, Nature: Folder, Debris: Folder }
local rng = Random.new()

local DEBRIS_GROUP = "CalderaDebris"
local PLAYER_GROUP = "CalderaPlayers"
local WEAR_COLOR = Color3.fromRGB(45, 38, 34)

Structures.DebrisGroup = DEBRIS_GROUP
Structures.PlayerGroup = PLAYER_GROUP

local function registerCollisionGroups()
	for _, name in { DEBRIS_GROUP, PLAYER_GROUP } do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	-- Debris still piles up on the ground and on itself, but cannot fling players around.
	PhysicsService:CollisionGroupSetCollidable(DEBRIS_GROUP, PLAYER_GROUP, false)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }

local function restsOnGround(part: BasePart): boolean
	local bottom = part.Position.Y - part.ExtentsSize.Y / 2
	local origin = Vector3.new(part.Position.X, bottom + 0.5, part.Position.Z)
	return workspace:Raycast(origin, Vector3.new(0, -2, 0), groundParams) ~= nil
end

function Structures.Init(mapFolders: { Structures: Folder, Nature: Folder, Debris: Folder })
	folders = mapFolders
	registerCollisionGroups()
end

-- Builds health and the support graph for one group (a Model of parts).
function Structures.Register(group: Instance)
	local parts = {}
	for _, descendant in group:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and (descendant:GetAttribute("Destructible") or descendant:GetAttribute("Support"))
		then
			table.insert(parts, descendant)
		end
	end
	if #parts == 0 then
		return
	end
	groups[group] = parts

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { group }

	for _, part in parts do
		local indestructible = part:GetAttribute("Indestructible") == true or part:GetAttribute("Support") == true
		local health = if indestructible then math.huge else (S.Health[part.Material] or S.DefaultHealth)
		states[part] = {
			Health = health,
			MaxHealth = health,
			Group = group,
			Neighbors = {},
			Grounded = part:GetAttribute("Support") == true or part:GetAttribute("Grounded") == true or restsOnGround(
				part
			),
			Destroyed = false,
			BaseColor = part.Color,
		}
		if part:GetAttribute("Fragile") then
			table.insert(fragile, part)
		end
	end

	-- Two parts are connected when their (slightly inflated) bounds overlap.
	for _, part in parts do
		local state = states[part]
		for _, other in workspace:GetPartBoundsInBox(part.CFrame, part.Size + Vector3.one * 0.3, overlap) do
			if other ~= part and states[other] and states[other].Group == group then
				table.insert(state.Neighbors, other)
			end
		end
	end
end

function Structures.RegisterAll()
	for _, root in { folders.Structures, folders.Nature } do
		for _, group in root:GetChildren() do
			Structures.Register(group)
		end
	end
end

function Structures.IsTracked(part: BasePart): boolean
	local state = states[part]
	return state ~= nil and not state.Destroyed
end

function Structures.Fragile(): { BasePart }
	return fragile
end

local function trackDebris(part: BasePart)
	table.insert(debrisQueue, part)
	while #debrisQueue > S.MaxDebris do
		local oldest = table.remove(debrisQueue, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end
end

local function shatter(part: BasePart)
	-- Glass bursts into a few shards instead of falling as one slab.
	for _ = 1, 5 do
		local shard = Instance.new("Part")
		shard.Name = "Shard"
		shard.Size = Vector3.new(rng:NextNumber(0.3, 0.9), rng:NextNumber(0.3, 0.9), 0.15)
		shard.CFrame = part.CFrame
			* CFrame.new(rng:NextNumber(-0.4, 0.4) * part.Size.X, rng:NextNumber(-0.4, 0.4) * part.Size.Y, 0)
		shard.Material = Enum.Material.Glass
		shard.Color = part.Color
		shard.Transparency = part.Transparency
		shard.CollisionGroup = DEBRIS_GROUP
		shard.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(2, 10), rng:NextNumber(-8, 8))
		shard.Parent = folders.Debris
		trackDebris(shard)
	end
	local sound = Instance.new("Sound")
	sound.SoundId = Config.Sounds.Glass
	sound.Volume = 0.6
	sound.RollOffMaxDistance = 120
	sound.Parent = part
	sound:Play()
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	task.delay(1, function()
		part:Destroy()
	end)
end

local scheduleSupportCheck: (Instance) -> ()

function Structures.Collapse(part: BasePart, impulse: Vector3?)
	local state = states[part]
	if not state or state.Destroyed then
		return
	end
	state.Destroyed = true
	local position = part.Position

	if part.Material == Enum.Material.Glass then
		shatter(part)
	else
		part.Anchored = false
		part.CanCollide = true
		part.CollisionGroup = DEBRIS_GROUP
		part.Parent = folders.Debris
		pcall(part.SetNetworkOwner, part, nil)
		part.AssemblyLinearVelocity = impulse or Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3))
		part.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-2, 2), rng:NextNumber(-2, 2), rng:NextNumber(-2, 2))
		trackDebris(part)
	end

	Structures.Collapsed:Fire(part, position)
	scheduleSupportCheck(state.Group)
end

-- Removes a part entirely (burnt-away leaves) while still letting the rest of the group react.
function Structures.Remove(part: BasePart)
	local state = states[part]
	if state and not state.Destroyed then
		state.Destroyed = true
		scheduleSupportCheck(state.Group)
	end
	part:Destroy()
end

local function checkSupport(group: Instance)
	local parts = groups[group]
	if not parts then
		return
	end

	local supported: { [BasePart]: boolean } = {}
	local queue = {}
	for _, part in parts do
		local state = states[part]
		if not state.Destroyed and state.Grounded then
			supported[part] = true
			table.insert(queue, part)
		end
	end

	local head = 1
	while head <= #queue do
		local part = queue[head]
		head += 1
		for _, neighbor in states[part].Neighbors do
			local neighborState = states[neighbor]
			if not supported[neighbor] and neighborState and not neighborState.Destroyed then
				supported[neighbor] = true
				table.insert(queue, neighbor)
			end
		end
	end

	for _, part in parts do
		local state = states[part]
		if not state.Destroyed and not supported[part] then
			task.delay(rng:NextNumber(S.CascadeDelay.Min, S.CascadeDelay.Max), Structures.Collapse, part)
		end
	end
end

scheduleSupportCheck = function(group: Instance)
	if pendingChecks[group] then
		return
	end
	pendingChecks[group] = true
	-- Batch several hits in the same moment into one search.
	task.delay(0.1, function()
		pendingChecks[group] = nil
		checkSupport(group)
	end)
end

-- Returns true if the part collapsed.
function Structures.Damage(part: BasePart, amount: number, impulse: Vector3?): boolean
	local state = states[part]
	if not state or state.Destroyed or state.Health == math.huge then
		return false
	end
	state.Health -= amount
	if state.Health <= 0 then
		Structures.Collapse(part, impulse)
		return true
	end
	-- Scorch the part as it weakens, unless the fire system is already charring it.
	if part.Material ~= Enum.Material.Glass and not part:GetAttribute("Burning") then
		local wear = 1 - state.Health / state.MaxHealth
		part.Color = state.BaseColor:Lerp(WEAR_COLOR, wear * 0.55)
	end
	return false
end

local radiusParams = OverlapParams.new()
radiusParams.FilterType = Enum.RaycastFilterType.Include

-- Damage with linear falloff; anything that breaks is thrown away from the centre.
function Structures.DamageRadius(position: Vector3, radius: number, amount: number, push: number)
	radiusParams.FilterDescendantsInstances = { folders.Structures, folders.Nature }
	for _, part in workspace:GetPartBoundsInRadius(position, radius, radiusParams) do
		if states[part] then
			local offset = part.Position - position
			local distance = offset.Magnitude
			local falloff = 1 - math.clamp(distance / radius, 0, 1)
			local direction = if distance > 0.01 then offset.Unit else Vector3.yAxis
			local impulse = direction * push * falloff + Vector3.new(0, push * 0.5 * falloff, 0)
			Structures.Damage(part, amount * (0.35 + 0.65 * falloff), impulse)
		end
	end
end

function Structures.Reset()
	table.clear(states)
	table.clear(groups)
	table.clear(pendingChecks)
	table.clear(fragile)
	table.clear(debrisQueue)
	folders.Debris:ClearAllChildren()
end

return Structures
