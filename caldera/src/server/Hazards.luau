--[[
	Hazards
	Everything the disaster does to players: damage with death causes, burning, lava wading,
	heat from nearby fires, blasts with line-of-sight falloff, and knockback.

	Knockback is applied by the owning client (characters are client-simulated, so velocity set
	on the server would be overwritten); the server only decides the velocity.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Signal = require(Shared.Signal)
local Structures = require(script.Parent.Structures)
local Combustion = require(script.Parent.Combustion)
local LavaFlow = require(script.Parent.LavaFlow)

local L = Config.Lava
local F = Config.Fire
local PL = Config.Player

local Hazards = {}

-- (player, cause) when a player dies to the disaster.
Hazards.PlayerKilled = Signal.new()

type CharacterState = {
	Player: Player,
	Character: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	BurnTime: number,
	BurnEffect: Fire?,
	LastCause: string?,
	LastCauseAt: number,
	Wading: boolean,
	Heat: number,
	SentHeat: number,
}

local characters: { [Model]: CharacterState } = {}
local knockbackEvent = Net.Event("Knockback")
local killFeedEvent = Net.Event("KillFeed")
local rng = Random.new()

local fireParams = OverlapParams.new()
fireParams.FilterType = Enum.RaycastFilterType.Include
local fireParamsVersion = -1

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Include

local DEFAULT_WALK_SPEED = 16

local function feetHeight(state: CharacterState): number
	local humanoid, root = state.Humanoid, state.Root
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return root.Position.Y - 3
	end
	return root.Position.Y - root.Size.Y / 2 - humanoid.HipHeight
end

function Hazards.GetState(character: Model): CharacterState?
	return characters[character]
end

function Hazards.Alive(): { CharacterState }
	local list = {}
	for _, state in characters do
		if state.Humanoid.Health > 0 and state.Root.Parent then
			table.insert(list, state)
		end
	end
	return list
end

-- Alive characters of players who are taking part in the current round (not lobby spectators).
function Hazards.Participants(): { CharacterState }
	local list = {}
	for _, state in Hazards.Alive() do
		if state.Player:GetAttribute("InRound") then
			table.insert(list, state)
		end
	end
	return list
end

function Hazards.Damage(humanoid: Humanoid, amount: number, cause: string)
	local state = humanoid.Parent and characters[humanoid.Parent :: Model]
	if humanoid.Health <= 0 or amount <= 0 then
		return
	end
	if state then
		state.LastCause = cause
		state.LastCauseAt = os.clock()
	end
	-- TakeDamage respects ForceFields, so freshly spawned players are protected.
	humanoid:TakeDamage(amount)
end

function Hazards.Knockback(player: Player, velocity: Vector3, tumble: boolean)
	knockbackEvent:FireClient(player, velocity, tumble)
end

function Hazards.SetOnFire(state: CharacterState, duration: number, cause: string)
	state.BurnTime = math.max(state.BurnTime, duration)
	state.LastCause = cause
	state.LastCauseAt = os.clock()
	if not state.BurnEffect then
		local fire = Instance.new("Fire")
		fire.Size = 5
		fire.Heat = 9
		fire.Color = Color3.fromRGB(255, 140, 40)
		fire.SecondaryColor = Color3.fromRGB(255, 70, 20)
		fire.Parent = state.Root
		state.BurnEffect = fire
		state.Player:SetAttribute("Burning", true)
	end
end

local function extinguish(state: CharacterState)
	state.BurnTime = 0
	if state.BurnEffect then
		state.BurnEffect:Destroy()
		state.BurnEffect = nil
	end
	state.Player:SetAttribute("Burning", nil)
end

--[[
	A blast that hurts with distance falloff. Walls between the blast and a player halve the damage.
]]
function Hazards.Explode(
	position: Vector3,
	radius: number,
	damage: number,
	knockback: number,
	cause: string,
	losRoots: { Instance }
)
	losParams.FilterDescendantsInstances = losRoots
	for _, state in Hazards.Alive() do
		local offset = state.Root.Position - position
		local distance = offset.Magnitude
		if distance < radius then
			local falloff = 1 - distance / radius
			local blocked = workspace:Raycast(position + Vector3.new(0, 1, 0), offset, losParams) ~= nil
			local scale = if blocked then 0.45 else 1
			Hazards.Damage(state.Humanoid, damage * falloff * scale, cause)
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local direction = if flat.Magnitude > 0.1 then flat.Unit else Vector3.xAxis
			local push = knockback * falloff * scale
			Hazards.Knockback(state.Player, direction * push + Vector3.new(0, push * 0.55, 0), push > 40)
			if falloff > 0.45 and not blocked then
				Hazards.SetOnFire(state, PL.BurnDuration, cause)
			end
		end
	end
end

local function inWater(position: Vector3): boolean
	local region = Region3.new(position - Vector3.new(2, 3, 2), position + Vector3.new(2, 1, 2)):ExpandToGrid(4)
	local materials = workspace.Terrain:ReadVoxels(region, 4)
	local size = materials.Size
	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if materials[x][y][z] == Enum.Material.Water then
					return true
				end
			end
		end
	end
	return false
end

local function updateCharacter(state: CharacterState, dt: number)
	local humanoid, root = state.Humanoid, state.Root
	if humanoid.Health <= 0 then
		return
	end
	local position = root.Position
	local heat = 0

	-- Molten lava under the player's feet.
	local surface, depth, temperature = LavaFlow.Sample(position)
	local wading = false
	if surface and depth > L.HarmfulDepth and temperature > L.HarmfulTemp and feetHeight(state) < surface + 0.75 then
		wading = true
		heat = 1
		Hazards.Damage(humanoid, L.DamagePerSecond * (0.4 + 0.6 * temperature) * dt, "molten lava")
		Hazards.SetOnFire(state, PL.BurnDuration, "molten lava")
	elseif surface and depth > L.HarmfulDepth and temperature > L.HarmfulTemp and feetHeight(state) < surface + 6 then
		heat = 0.55
	end
	if wading ~= state.Wading then
		state.Wading = wading
		humanoid.WalkSpeed = if wading then L.WadeSpeed else DEFAULT_WALK_SPEED
	end

	-- Standing next to a burning building.
	local burningParts = Combustion.BurningParts()
	if #burningParts > 0 then
		if fireParamsVersion ~= Combustion.Version then
			fireParamsVersion = Combustion.Version
			fireParams.FilterDescendantsInstances = burningParts
		end
		if #workspace:GetPartBoundsInRadius(position, F.PlayerRadius, fireParams) > 0 then
			heat = math.max(heat, 0.6)
			Hazards.Damage(humanoid, F.PlayerDamagePerSecond * dt, "fire")
			if rng:NextNumber() < F.PlayerIgniteChance * dt then
				Hazards.SetOnFire(state, PL.BurnDuration, "fire")
			end
		end
	end

	-- Burning status: damage over time unless the player finds water.
	if state.BurnTime > 0 then
		if inWater(position) then
			extinguish(state)
		else
			state.BurnTime -= dt
			heat = math.max(heat, 0.75)
			Hazards.Damage(humanoid, PL.BurnDamagePerSecond * dt, state.LastCause or "burns")
			if state.BurnTime <= 0 then
				extinguish(state)
			end
		end
	end

	-- Smooth the heat value and only replicate meaningful changes.
	state.Heat += (heat - state.Heat) * math.min(1, dt * 6)
	if math.abs(state.Heat - state.SentHeat) > 0.04 or (heat == 0 and state.SentHeat ~= 0 and state.Heat < 0.02) then
		state.SentHeat = if state.Heat < 0.02 then 0 else math.floor(state.Heat * 100) / 100
		state.Player:SetAttribute("Heat", state.SentHeat)
	end
end

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not root or character.Parent == nil then
		return
	end

	local state: CharacterState = {
		Player = player,
		Character = character,
		Humanoid = humanoid,
		Root = root,
		BurnTime = 0,
		BurnEffect = nil,
		LastCause = nil,
		LastCauseAt = 0,
		Wading = false,
		Heat = 0,
		SentHeat = 0,
	}
	characters[character] = state
	player:SetAttribute("Heat", 0)
	player:SetAttribute("Burning", nil)

	-- Keep character parts in the player collision group so falling debris passes through them.
	local function assign(part: Instance)
		if part:IsA("BasePart") then
			part.CollisionGroup = Structures.PlayerGroup
		end
	end
	for _, descendant in character:GetDescendants() do
		assign(descendant)
	end
	character.DescendantAdded:Connect(assign)

	humanoid.Died:Connect(function()
		local recent = state.LastCause ~= nil and os.clock() - state.LastCauseAt < 12
		local cause = if recent then state.LastCause :: string else "the eruption"
		extinguish(state)
		killFeedEvent:FireAllClients(player.DisplayName, cause)
		Hazards.PlayerKilled:Fire(player, cause)
	end)

	character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			characters[character] = nil
		end
	end)
end

function Hazards.Init()
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	task.spawn(function()
		while true do
			local dt = task.wait(PL.HazardTick)
			for _, state in characters do
				local ok, err = pcall(updateCharacter, state, dt)
				if not ok then
					warn("[Hazards]", err)
				end
			end
		end
	end)
end

function Hazards.Reset()
	for _, state in characters do
		extinguish(state)
		if state.Wading then
			state.Wading = false
			state.Humanoid.WalkSpeed = DEFAULT_WALK_SPEED
		end
	end
end

return Hazards
