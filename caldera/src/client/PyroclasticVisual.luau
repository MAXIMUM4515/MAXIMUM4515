--[[
	PyroclasticVisual
	Renders the pyroclastic flow as a churning wall of ash that rolls outward across the sector
	the server chose, hugging the ground (heights come from the shared Heightmap, so no
	raycasts are needed). When the front reaches the camera the screen is smothered in ash.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Heightmap = require(Shared.Heightmap)
local Net = require(Shared.Net)
local AshSky = require(script.Parent.AshSky)
local CameraShake = require(script.Parent.CameraShake)

local PyroclasticVisual = {}

local PUFFS = 46
local CLOUD_COLORS = { Color3.fromRGB(96, 88, 82), Color3.fromRGB(78, 72, 68), Color3.fromRGB(112, 102, 94) }

type Puff = {
	Part: Part,
	Angle: number,
	Lag: number,
	Lift: number,
	Size: number,
	Seed: number,
}

local rng = Random.new()
local folder: Folder
local connection: RBXScriptConnection? = nil

local function makePuff(size: number): Part
	local part = Instance.new("Part")
	part.Name = "AshCloud"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.Material = Enum.Material.SmoothPlastic
	part.Color = CLOUD_COLORS[rng:NextInteger(1, #CLOUD_COLORS)]
	part.Transparency = 0.08
	part.Size = Vector3.one * size

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(88, 80, 74), Color3.fromRGB(60, 56, 52))
	emitter.Size = NumberSequence.new(size * 0.45, size * 0.9)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.6, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(2.5, 4)
	emitter.Speed = NumberRange.new(3, 8)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.RotSpeed = NumberRange.new(-30, 30)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LightInfluence = 0.7
	emitter.Rate = 5
	emitter.Parent = part
	return part
end

local function stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	folder:ClearAllChildren()
	AshSky.SetSmother(0)
end

local function onFlow(data)
	stop()
	local origin: Vector3 = data.Origin
	local direction: Vector3 = data.Direction
	local baseAngle = math.atan2(direction.Z, direction.X)

	local puffs: { Puff } = {}
	for i = 1, PUFFS do
		local size = rng:NextNumber(20, 34)
		local part = makePuff(size)
		part.Parent = folder
		local spread = (i / PUFFS) * 2 - 1
		table.insert(puffs, {
			Part = part,
			Angle = baseAngle + spread * data.HalfAngle + rng:NextNumber(-0.03, 0.03),
			-- A second, trailing row and some taller billows give the wall depth.
			Lag = if i % 3 == 0 then rng:NextNumber(14, 26) else rng:NextNumber(0, 8),
			Lift = if i % 4 == 0 then rng:NextNumber(14, 22) else rng:NextNumber(2, 8),
			Size = size,
			Seed = rng:NextNumber(0, 100),
		})
	end

	local whoosh = Instance.new("Sound")
	whoosh.SoundId = Config.Sounds.Whoosh
	whoosh.Volume = 1
	whoosh.PlaybackSpeed = 0.35
	SoundService:PlayLocalSound(whoosh)
	Debris:AddItem(whoosh, 10)

	local finalRadius = data.MaxRadius
	local engulfed = false
	local lastShakeRadius = 0

	connection = RunService.RenderStepped:Connect(function()
		local now = workspace:GetServerTimeNow()
		local elapsed = now - data.Start
		-- Before the start time the cloud boils up out of the crater.
		local radius = data.StartRadius + data.Speed * math.max(elapsed, 0)
		local rising = math.clamp((elapsed + Config.Pyroclastic.WarnTime) / Config.Pyroclastic.WarnTime, 0, 1)
		local fade = math.clamp((radius - finalRadius) / 40, 0, 1)
		if fade >= 1 then
			stop()
			return
		end

		for _, puff in puffs do
			local r = math.max(data.StartRadius, radius - puff.Lag)
			local x = origin.X + math.cos(puff.Angle) * r
			local z = origin.Z + math.sin(puff.Angle) * r
			local churn = math.noise(puff.Seed, now * 0.6)
			local y = if elapsed < 0
				then origin.Y + rising * 30 + puff.Lift
				else Heightmap.Height(x, z) + puff.Lift + puff.Size * 0.25 + churn * 4
			local scale = puff.Size * (0.85 + 0.25 * math.noise(puff.Seed + 7, now * 0.8))
			puff.Part.Size = Vector3.one * scale * (if elapsed < 0 then 0.4 + 0.6 * rising else 1)
			puff.Part.CFrame = CFrame.new(x, y, z)
			puff.Part.Transparency = 0.08 + 0.9 * fade
		end

		-- The rumble of the front follows it outward.
		if elapsed > 0 and radius - lastShakeRadius > 20 then
			lastShakeRadius = radius
			local front = origin + direction * radius
			CameraShake.Impulse(front, 0.35, 120)
		end

		-- Engulfed: inside the sector and behind the front.
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and elapsed > 0 then
			local offset = Vector3.new(root.Position.X - origin.X, 0, root.Position.Z - origin.Z)
			local distance = offset.Magnitude
			local inside = distance > 1 and offset.Unit:Dot(direction) >= math.cos(data.HalfAngle)
			local behindFront = distance <= radius and distance > radius - 70
			local nowEngulfed = inside and behindFront
			if nowEngulfed ~= engulfed then
				engulfed = nowEngulfed
				AshSky.SetSmother(if engulfed then 1 else 0)
				if engulfed then
					CameraShake.Impulse(root.Position, 0.8, 50)
				end
			end
		end
	end)
end

function PyroclasticVisual.Start()
	folder = Instance.new("Folder")
	folder.Name = "CalderaPyroclastic"
	folder.Parent = workspace
	Net.Event("Pyroclastic").OnClientEvent:Connect(onFlow)
	-- Make sure a flow never outlives its round.
	Net.OnState("RoundState", function(state)
		if state ~= "Disaster" then
			stop()
		end
	end)
end

return PyroclasticVisual
