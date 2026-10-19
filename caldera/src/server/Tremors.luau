--[[
	Tremors
	Ground shaking. The intensity is replicated as an attribute for client camera shake; on the
	server it jolts loose props, cracks windows and shakes boulders loose from the summit, which
	then roll down the flanks under real physics.

	Boulders burst every time they land hard: each frame the server compares a boulder's velocity
	with the last frame's, and a sudden change (a bounce, a landing, smashing into a wall) sets off
	a blast with falloff. Rolling smoothly does nothing, so a tumbling rock thumps down the slope.
	The blast is capped well below a one-shot: it is there to scare people off the flanks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Hazards = require(script.Parent.Hazards)
local Structures = require(script.Parent.Structures)

local T = Config.Tremor
local BB = T.BoulderBlast
local V = Config.Volcano

local Tremors = {}

type Boulder = {
	Part: BasePart,
	-- 0.55 for the smallest boulder up to 1 for the largest; scales blast radius and damage.
	Scale: number,
	LastVelocity: Vector3,
	NextBlast: number,
	-- When this boulder last hurt each character, so one rock can't land two blasts back to back.
	LastHit: { [Model]: number },
}

local intensity = 0
local bouldersEnabled = false
local boulders: { Boulder } = {}
local folders
local rng = Random.new()
local rockImpactEvent = Net.Event("RockImpact")

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }

function Tremors.SetIntensity(value: number)
	intensity = math.clamp(value, 0, 1)
	Net.SetState("Tremor", math.floor(intensity * 100) / 100)
end

function Tremors.GetIntensity(): number
	return intensity
end

function Tremors.SetBoulders(enabled: boolean)
	bouldersEnabled = enabled
end

local function pulse()
	if intensity <= 0 then
		return
	end
	for _, part in folders.Props:GetChildren() do
		if part:IsA("BasePart") and not part.Anchored then
			local jolt = T.PropJolt * intensity
			part.AssemblyLinearVelocity += Vector3.new(
				rng:NextNumber(-jolt, jolt),
				rng:NextNumber(0, jolt * 0.6),
				rng:NextNumber(-jolt, jolt)
			)
		end
	end
	if intensity > 0.45 then
		for _, pane in Structures.Fragile() do
			if Structures.IsTracked(pane) and rng:NextNumber() < T.GlassCrackChance * intensity then
				Structures.Damage(pane, 6)
			end
		end
	end
end

local function blast(boulder: Boulder, power: number)
	local now = os.clock()
	if now < boulder.NextBlast then
		return
	end
	boulder.NextBlast = now + BB.Cooldown

	local part = boulder.Part
	local position = part.Position
	local radius = BB.Radius * (0.7 + 0.3 * boulder.Scale)
	local function canHit(state): boolean
		local last = boulder.LastHit[state.Character]
		if last and now - last < BB.PlayerCooldown then
			return false
		end
		boulder.LastHit[state.Character] = now
		return true
	end
	Hazards.Explode(
		position,
		radius,
		BB.Damage * boulder.Scale * power,
		BB.Knockback * power,
		"a falling boulder",
		{ workspace.Terrain, folders.Structures },
		false,
		canHit
	)
	Structures.DamageRadius(position, radius * 0.6, 45 * power, 25)
	rockImpactEvent:FireAllClients(position, part.Size.X, power)
end

-- Harder hits give a bigger blast, from 45% at the threshold to full strength.
local function impactPower(speed: number): number
	return math.clamp(speed / 60, 0.45, 1)
end

local function watchImpacts()
	for i = #boulders, 1, -1 do
		local boulder = boulders[i]
		if not boulder.Part.Parent then
			table.remove(boulders, i)
		else
			local velocity = boulder.Part.AssemblyLinearVelocity
			local change = (velocity - boulder.LastVelocity).Magnitude
			boulder.LastVelocity = velocity
			if change >= BB.ImpactSpeed then
				blast(boulder, impactPower(change))
			end
		end
	end
end

-- Mostly random, but some boulders come loose on the flank facing the players.
local function pickAngle(): number
	local targets = Hazards.Participants()
	if #targets > 0 and rng:NextNumber() < T.BoulderAimChance then
		local offset = targets[rng:NextInteger(1, #targets)].Root.Position - V.Center
		return math.atan2(offset.Z, offset.X) + rng:NextNumber(-0.3, 0.3)
	end
	return rng:NextNumber(-math.pi, math.pi)
end

local function spawnBoulder()
	if #boulders >= T.MaxBoulders then
		return
	end

	local angle = pickAngle()
	local distance = rng:NextNumber(V.SummitRadius + 4, V.SummitRadius + 30)
	local x = V.Center.X + math.cos(angle) * distance
	local z = V.Center.Z + math.sin(angle) * distance
	local result = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), terrainParams)
	if not result then
		return
	end

	local size = rng:NextNumber(T.BoulderSize.Min, T.BoulderSize.Max)
	local part = Instance.new("Part")
	part.Name = "Boulder"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * size
	part.Material = Enum.Material.Basalt
	part.Color = Color3.fromRGB(58, 52, 50)
	part.CFrame = CFrame.new(result.Position + result.Normal * (size / 2 + 0.5))
	part.CustomPhysicalProperties = PhysicalProperties.new(2.6, 0.5, 0.15)
	part.Parent = folders.Effects
	pcall(part.SetNetworkOwner, part, nil)

	local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
	part.AssemblyLinearVelocity = outward * rng:NextNumber(12, 24)
	part.AssemblyAngularVelocity = outward:Cross(Vector3.yAxis) * -rng:NextNumber(2, 5)

	local sizeAlpha = (size - T.BoulderSize.Min) / (T.BoulderSize.Max - T.BoulderSize.Min)
	local boulder: Boulder = {
		Part = part,
		Scale = 0.55 + 0.45 * sizeAlpha,
		LastVelocity = part.AssemblyLinearVelocity,
		NextBlast = 0,
		LastHit = {},
	}
	table.insert(boulders, boulder)

	part.Touched:Connect(function(other)
		local speed = part.AssemblyLinearVelocity.Magnitude
		local model = other:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			-- Barely slows a heavy boulder, so the velocity check would miss it: burst on contact instead.
			if speed >= BB.HitSpeed then
				blast(boulder, impactPower(speed))
			end
		elseif speed > 25 and Structures.IsTracked(other) then
			Structures.Damage(other, speed * 1.2, part.AssemblyLinearVelocity * 0.4)
		end
	end)

	task.delay(T.BoulderLifetime, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

function Tremors.Init(mapFolders)
	folders = mapFolders
	Tremors.SetIntensity(0)
	RunService.Heartbeat:Connect(watchImpacts)

	task.spawn(function()
		while true do
			task.wait(T.PulseInterval)
			local ok, err = pcall(pulse)
			if not ok then
				warn("[Tremors]", err)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(rng:NextNumber(T.BoulderInterval.Min, T.BoulderInterval.Max))
			if bouldersEnabled then
				local ok, err = pcall(spawnBoulder)
				if not ok then
					warn("[Tremors]", err)
				end
			end
		end
	end)
end

function Tremors.Reset()
	Tremors.SetIntensity(0)
	bouldersEnabled = false
	for _, boulder in boulders do
		boulder.Part:Destroy()
	end
	table.clear(boulders)
end

return Tremors
