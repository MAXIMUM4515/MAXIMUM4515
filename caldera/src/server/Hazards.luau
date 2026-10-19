--[[
	Hazards
	Everything the disaster does to players: damage with death causes, the burn meter, lava
	wading, flames nearby, blasts with line-of-sight falloff, and knockback.

	Damage comes in distinct hits rather than a per-frame drain, so every hit reads (the client
	flashes the screen on each one):
		molten lava    a short burst of hits on contact (repeated while you stay in it), and it fills
		               the burn meter: empty to MAX in 4 s of continuous contact
		burn meter     while it is up you are on fire and take a poke every half second, harder the
		               fuller it is. It never cools down on its own.
		the lake       puts the fire out at once (flames and pokes stop, queued lava hits are
		               cancelled) and empties the meter over 3 s
		flames nearby  a poke every so often, with a chance to catch fire
		blasts         hurt with falloff; close ones set you alight

	Knockback is applied by the owning client (characters are client-simulated, so velocity set
	on the server would be overwritten); the server only decides the velocity.

	Characters are tracked once they reach the Workspace (CharacterAdded fires before that), and
	the update loop picks up any character that was missed: an untracked character would be
	immune to everything.
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

	-- Burn meter, 0..1. On fire while it is above zero, until the lake puts it out.
	Meter: number,
	SentMeter: number,
	Draining: boolean,
	DrainRate: number,
	BurnEffect: Fire?,
	BurnCause: string,
	NextBurnTick: number,

	-- Lava contact bursts.
	BurstHitsLeft: number,
	BurstHitDamage: number,
	NextBurstHit: number,
	NextBurstAllowed: number,

	NextFireTick: number,
	InWater: boolean,
	Wading: boolean,
	LastCause: string?,
	LastCauseAt: number,
}

local characters: { [Model]: CharacterState } = {}
local knockbackEvent = Net.Event("Knockback")
local killFeedEvent = Net.Event("KillFeed")
local announceEvent = Net.Event("Announce")
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

--------------------------------------------------------------------------------------------
-- Burn meter
--------------------------------------------------------------------------------------------

-- Replicates the meter for the HUD, skipping changes too small to see but always sending the ends.
local function publishMeter(state: CharacterState)
	local meter = state.Meter
	local atEnd = (meter <= 0 or meter >= 1) and meter ~= state.SentMeter
	if atEnd or math.abs(meter - state.SentMeter) >= 0.02 then
		state.SentMeter = if meter >= 1 then 1 elseif meter <= 0 then 0 else math.floor(meter * 100 + 0.5) / 100
		state.Player:SetAttribute("BurnMeter", state.SentMeter)
	end
end

local function putOutFlames(state: CharacterState)
	if state.BurnEffect then
		state.BurnEffect:Destroy()
		state.BurnEffect = nil
	end
	state.Player:SetAttribute("Burning", nil)
end

-- Removes every trace of burning at once (death, round reset).
local function clearBurn(state: CharacterState)
	putOutFlames(state)
	state.BurstHitsLeft = 0
	state.Meter = 0
	state.Draining = false
	publishMeter(state)
end

--[[
	Sets a player alight with the burn meter at least at `meter` (0..1). Nothing catches fire
	underwater. Lava calls this every tick with a rising value; blasts and flames with a small one.
]]
function Hazards.SetOnFire(state: CharacterState, meter: number, cause: string)
	if state.InWater or state.Humanoid.Health <= 0 then
		return
	end
	state.Meter = math.clamp(math.max(state.Meter, meter), 0, 1)
	state.Draining = false
	state.BurnCause = cause
	state.LastCause = cause
	state.LastCauseAt = os.clock()
	if state.BurnEffect then
		return
	end
	-- The first poke lands one interval after catching fire, not on top of the hit that lit it.
	state.NextBurnTick = os.clock() + PL.BurnTickInterval
	local fire = Instance.new("Fire")
	fire.Size = 5
	fire.Heat = 9
	fire.Color = Color3.fromRGB(255, 140, 40)
	fire.SecondaryColor = Color3.fromRGB(255, 70, 20)
	fire.Parent = state.Root
	state.BurnEffect = fire
	state.Player:SetAttribute("Burning", true)
end

-- The lake: flames and pokes stop at once, queued lava hits are cancelled, the meter drains.
local function douse(state: CharacterState)
	local wasHurting = state.BurnEffect ~= nil or state.BurstHitsLeft > 0
	state.BurstHitsLeft = 0
	putOutFlames(state)
	if state.Meter > 0 and not state.Draining then
		-- A fixed time to empty, whatever the level: a full meter drains as fast as a nearly empty one.
		state.Draining = true
		state.DrainRate = state.Meter / PL.MeterDrainTime
	end
	if not wasHurting then
		return
	end
	local steam = Instance.new("Smoke")
	steam.Color = Color3.fromRGB(235, 235, 235)
	steam.Opacity = 0.35
	steam.RiseVelocity = 9
	steam.Size = 4
	steam.Parent = state.Root
	task.delay(0.8, function()
		steam.Enabled = false
		task.wait(3)
		steam:Destroy()
	end)
	announceEvent:FireClient(state.Player, "Extinguished!", Color3.fromRGB(140, 200, 255), 1.5, "small")
end

-- On fire: a poke every interval, from BurnTickDamage.Min on an empty meter to Max on a full one.
local function tickBurning(state: CharacterState, now: number)
	if state.BurnEffect and now >= state.NextBurnTick then
		state.NextBurnTick = now + PL.BurnTickInterval
		local damage = PL.BurnTickDamage
		Hazards.Damage(state.Humanoid, damage.Min + (damage.Max - damage.Min) * state.Meter, state.BurnCause)
	end
end

-- Once doused, the meter runs down to empty (it finishes even if they step out of the water).
local function tickMeter(state: CharacterState, dt: number)
	if state.Draining then
		state.Meter = math.max(0, state.Meter - state.DrainRate * dt)
		if state.Meter == 0 then
			state.Draining = false
		end
	end
end

--------------------------------------------------------------------------------------------
-- Lava
--------------------------------------------------------------------------------------------

--[[
	Lava's damage. Contact starts a short burst of hits (another one every BurstCooldown while they
	stay in it), and every moment of contact pushes the burn meter up: empty to MAX in
	MeterFillTime seconds. The fire keeps poking, harder as the meter rises, until the lake.
]]
local function lavaContact(state: CharacterState, now: number, dt: number, temperature: number)
	if now >= state.NextBurstAllowed then
		state.NextBurstAllowed = now + L.BurstCooldown
		state.BurstHitsLeft = L.BurstHits
		state.BurstHitDamage = L.BurstHitDamage * (0.6 + 0.4 * temperature)
		state.NextBurstHit = now
	end
	Hazards.SetOnFire(state, state.Meter + dt / PL.MeterFillTime, "molten lava")
end

-- Lands the next hit of a lava burst once its interval has passed.
local function tickBurst(state: CharacterState, now: number)
	if state.BurstHitsLeft > 0 and now >= state.NextBurstHit then
		state.BurstHitsLeft -= 1
		state.NextBurstHit = now + L.BurstHitInterval
		Hazards.Damage(state.Humanoid, state.BurstHitDamage, "molten lava")
	end
end

--------------------------------------------------------------------------------------------
-- Blasts
--------------------------------------------------------------------------------------------

--[[
	A blast that hurts with distance falloff. Walls between the blast and a player halve the damage.
	Close, unshielded blasts set people on fire unless `ignite` is false (falling rocks).
	`canHit`, if given, is asked before each player in range is hurt (used for per-source cooldowns).
]]
function Hazards.Explode(
	position: Vector3,
	radius: number,
	damage: number,
	knockback: number,
	cause: string,
	losRoots: { Instance },
	ignite: boolean?,
	canHit: ((CharacterState) -> boolean)?
)
	losParams.FilterDescendantsInstances = losRoots
	for _, state in Hazards.Alive() do
		local offset = state.Root.Position - position
		local distance = offset.Magnitude
		if distance < radius and (canHit == nil or canHit(state)) then
			local falloff = 1 - distance / radius
			local blocked = workspace:Raycast(position + Vector3.new(0, 1, 0), offset, losParams) ~= nil
			local scale = if blocked then 0.45 else 1
			Hazards.Damage(state.Humanoid, damage * falloff * scale, cause)
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local direction = if flat.Magnitude > 0.1 then flat.Unit else Vector3.xAxis
			local push = knockback * falloff * scale
			Hazards.Knockback(state.Player, direction * push + Vector3.new(0, push * 0.55, 0), push > 40)
			if ignite ~= false and falloff > 0.45 and not blocked then
				Hazards.SetOnFire(state, PL.IgniteMeter.Blast, cause)
			end
		end
	end
end

--------------------------------------------------------------------------------------------
-- Per-tick update
--------------------------------------------------------------------------------------------

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
	local now = os.clock()
	local position = root.Position

	state.InWater = inWater(position)
	if state.InWater then
		douse(state)
	end

	-- Molten lava under the player's feet.
	local surface, depth, temperature = LavaFlow.Sample(position)
	local molten = surface ~= nil and depth > L.HarmfulDepth and temperature > L.HarmfulTemp
	local wading = molten and not state.InWater and feetHeight(state) < (surface :: number) + 0.75
	if wading then
		lavaContact(state, now, dt, temperature)
	end
	if wading ~= state.Wading then
		state.Wading = wading
		humanoid.WalkSpeed = if wading then L.WadeSpeed else DEFAULT_WALK_SPEED
	end
	tickBurst(state, now)

	-- Standing next to a burning building: a poke every interval, with a chance to catch fire.
	local burningParts = Combustion.BurningParts()
	if #burningParts > 0 and not state.InWater then
		if fireParamsVersion ~= Combustion.Version then
			fireParamsVersion = Combustion.Version
			fireParams.FilterDescendantsInstances = burningParts
		end
		if #workspace:GetPartBoundsInRadius(position, F.PlayerRadius, fireParams) > 0 and now >= state.NextFireTick then
			state.NextFireTick = now + F.PlayerTickInterval
			Hazards.Damage(humanoid, F.PlayerTickDamage, "fire")
			if rng:NextNumber() < F.PlayerIgniteChance then
				Hazards.SetOnFire(state, PL.IgniteMeter.Fire, "fire")
			end
		end
	end

	tickBurning(state, now)
	tickMeter(state, dt)
	publishMeter(state)
end

--------------------------------------------------------------------------------------------
-- Character tracking
--------------------------------------------------------------------------------------------

-- Starts tracking a character. It must already be in the Workspace with its parts; never yields.
local function track(player: Player, character: Model, humanoid: Humanoid, root: BasePart)
	local state: CharacterState = {
		Player = player,
		Character = character,
		Humanoid = humanoid,
		Root = root,
		Meter = 0,
		SentMeter = 0,
		Draining = false,
		DrainRate = 0,
		BurnEffect = nil,
		BurnCause = "burns",
		NextBurnTick = 0,
		BurstHitsLeft = 0,
		BurstHitDamage = 0,
		NextBurstHit = 0,
		NextBurstAllowed = 0,
		NextFireTick = 0,
		InWater = false,
		Wading = false,
		LastCause = nil,
		LastCauseAt = 0,
	}
	characters[character] = state
	player:SetAttribute("BurnMeter", 0)
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
		clearBurn(state)
		killFeedEvent:FireAllClients(player.DisplayName, cause)
		Hazards.PlayerKilled:Fire(player, cause)
	end)

	character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			characters[character] = nil
		end
	end)
end

-- Tracks the player's current character if it is ready. Returns true once it is tracked.
local function tryTrack(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	if characters[character] then
		return true
	end
	if not character:IsDescendantOf(workspace) then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return false
	end
	track(player, character, humanoid, root)
	return true
end

-- CharacterAdded fires before the new character is parented to the Workspace, so keep trying
-- until it arrives (or the player gets a different character).
local function onCharacterAdded(player: Player, character: Model)
	local deadline = os.clock() + 15
	while player.Character == character and os.clock() < deadline do
		if tryTrack(player) then
			return
		end
		task.wait()
	end
end

function Hazards.Init()
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	task.spawn(function()
		while true do
			local dt = task.wait(PL.HazardTick)
			-- Safety net: never leave a living character untracked (and therefore immune).
			for _, player in Players:GetPlayers() do
				tryTrack(player)
			end
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
		clearBurn(state)
		if state.Wading then
			state.Wading = false
			state.Humanoid.WalkSpeed = DEFAULT_WALK_SPEED
		end
	end
end

return Hazards
