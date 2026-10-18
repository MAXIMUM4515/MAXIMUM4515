--[[
	Tremors
	Ground shaking. The intensity is replicated as an attribute for client camera shake; on the
	server it jolts loose props, cracks windows and shakes boulders loose from the summit, which
	then roll down the flanks under real physics.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Hazards = require(script.Parent.Hazards)
local Structures = require(script.Parent.Structures)

local T = Config.Tremor
local V = Config.Volcano

local Tremors = {}

local intensity = 0
local bouldersEnabled = false
local boulders: { BasePart } = {}
local folders
local rng = Random.new()

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

local function spawnBoulder()
	-- Clean up the list and respect the cap.
	for i = #boulders, 1, -1 do
		if not boulders[i].Parent then
			table.remove(boulders, i)
		end
	end
	if #boulders >= T.MaxBoulders then
		return
	end

	local angle = rng:NextNumber(-math.pi, math.pi)
	local distance = rng:NextNumber(V.SummitRadius + 4, V.SummitRadius + 30)
	local x = V.Center.X + math.cos(angle) * distance
	local z = V.Center.Z + math.sin(angle) * distance
	local result = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), terrainParams)
	if not result then
		return
	end

	local size = rng:NextNumber(T.BoulderSize.Min, T.BoulderSize.Max)
	local boulder = Instance.new("Part")
	boulder.Name = "Boulder"
	boulder.Shape = Enum.PartType.Ball
	boulder.Size = Vector3.one * size
	boulder.Material = Enum.Material.Basalt
	boulder.Color = Color3.fromRGB(58, 52, 50)
	boulder.CFrame = CFrame.new(result.Position + result.Normal * (size / 2 + 0.5))
	boulder.CustomPhysicalProperties = PhysicalProperties.new(2.6, 0.5, 0.15)
	boulder.Parent = folders.Effects
	pcall(boulder.SetNetworkOwner, boulder, nil)

	local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
	boulder.AssemblyLinearVelocity = outward * rng:NextNumber(12, 24)
	boulder.AssemblyAngularVelocity = outward:Cross(Vector3.yAxis) * -rng:NextNumber(2, 5)
	table.insert(boulders, boulder)

	local cooldown: { [Instance]: number } = {}
	boulder.Touched:Connect(function(other)
		local speed = boulder.AssemblyLinearVelocity.Magnitude
		if speed < T.BoulderDamageSpeed then
			return
		end
		local model = other:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local now = os.clock()
			if (cooldown[humanoid] or 0) > now then
				return
			end
			cooldown[humanoid] = now + 1
			Hazards.Damage(humanoid, math.clamp(speed * 0.9, 10, 45), "a falling boulder")
			local player = Players:GetPlayerFromCharacter(model)
			if player then
				Hazards.Knockback(player, boulder.AssemblyLinearVelocity * 0.8 + Vector3.new(0, 25, 0), true)
			end
		elseif Structures.IsTracked(other) and speed > 25 then
			Structures.Damage(other, speed * 1.2, boulder.AssemblyLinearVelocity * 0.4)
		end
	end)

	task.delay(T.BoulderLifetime, function()
		if boulder.Parent then
			boulder:Destroy()
		end
	end)
end

function Tremors.Init(mapFolders)
	folders = mapFolders
	Tremors.SetIntensity(0)

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
		boulder:Destroy()
	end
	table.clear(boulders)
end

return Tremors
