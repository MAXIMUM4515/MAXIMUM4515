--[[
	RockfallEffects
	What a boulder impact looks like: a burst of dust, a spray of rock chips, and a mild camera
	jolt for anyone near where it came down (stronger the closer and harder the hit), plus a jolt
	when a rock hits you directly. The damage itself is dealt by the server (Tremors).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local CameraShake = require(script.Parent.CameraShake)

local RockfallEffects = {}

local BB = Config.Tremor.BoulderBlast
local JOLT_DURATION = 0.45

local rng = Random.new()
local folder: Folder

local function dust(position: Vector3, size: number, power: number)
	local anchor = Instance.new("Part")
	anchor.Name = "RockDust"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = position
	anchor.Parent = folder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(122, 108, 96), Color3.fromRGB(84, 76, 70))
	emitter.Size = NumberSequence.new(size * 0.6, size * 1.6)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(0.7, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(1, 1.8)
	emitter.Speed = NumberRange.new(8, 18 * power + 6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 3
	emitter.Acceleration = Vector3.new(0, 2, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.LightInfluence = 1
	emitter.Rate = 0
	emitter.Parent = anchor
	emitter:Emit(math.floor(10 + 10 * power))
	Debris:AddItem(anchor, 2.5)
end

local function chips(position: Vector3, power: number)
	for _ = 1, 6 do
		local chip = Instance.new("Part")
		chip.Name = "RockChip"
		chip.Size = Vector3.one * rng:NextNumber(0.5, 1.3)
		chip.Material = Enum.Material.Basalt
		chip.Color = Color3.fromRGB(64, 58, 55)
		chip.CanQuery = false
		chip.CanTouch = false
		chip.CastShadow = false
		chip.CollisionGroup = Config.CollisionGroups.Debris
		chip.CFrame = CFrame.new(position + Vector3.new(0, 1.5, 0))
			* CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0)
		local spray = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0.6, 1.4), rng:NextNumber(-1, 1)).Unit
		chip.AssemblyLinearVelocity = spray * rng:NextNumber(18, 40) * (0.6 + 0.4 * power)
		chip.Parent = folder
		Debris:AddItem(chip, rng:NextNumber(1.5, 2.5))
	end
end

-- Where "near" is measured from: the character if there is one, else the camera.
local function listenerPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		return root.Position
	end
	local camera = workspace.CurrentCamera
	return camera and camera.CFrame.Position
end

local function onImpact(position: Vector3, size: number, power: number)
	dust(position, size, power)
	chips(position, power)

	local here = listenerPosition()
	if here then
		local distance = (here - position).Magnitude
		if distance < BB.ShakeRadius then
			local closeness = 1 - distance / BB.ShakeRadius
			CameraShake.Kick(BB.ShakeStrength * (0.35 + 0.65 * closeness) * (0.6 + 0.4 * power), JOLT_DURATION)
		end
	end
end

-- A rock hit this player directly.
local function onHit(power: number)
	CameraShake.Kick(BB.HitShakeStrength * (0.6 + 0.4 * power), JOLT_DURATION + 0.15)
end

function RockfallEffects.Start()
	folder = Instance.new("Folder")
	folder.Name = "MountIgnisRockfall"
	folder.Parent = workspace
	Net.Event("RockImpact").OnClientEvent:Connect(onImpact)
	Net.Event("RockHit").OnClientEvent:Connect(onHit)
end

return RockfallEffects
