--[[
	RockfallEffects
	What a boulder impact looks and sounds like: a burst of dust, a spray of rock chips, a crunch
	at the impact point, and a mild camera jolt for anyone near where it came down (stronger the
	closer and harder the hit), plus a jolt and crunch when a rock hits you directly. Rocks are
	silent while they roll; only impacts make a sound. The damage is dealt by the server (Tremors).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local CameraShake = require(script.Parent.CameraShake)

local RockfallEffects = {}

local T = Config.Tremor
local BB = T.BoulderBlast
local JOLT_DURATION = 0.45

-- Impact sounds: heard clearly up close, fading out by ROLLOFF_MAX studs. Capped so a slope full
-- of bouncing rocks never turns into a wall of noise.
local ROLLOFF_MIN = 12
local ROLLOFF_MAX = 220
local MAX_IMPACT_SOUNDS = 6
local SOUND_LIFETIME = 5
-- A direct hit right after an impact this close to the player already made its sound.
local NEAR_IMPACT = 15

local activeSounds = 0
local lastNearImpact = 0

local rng = Random.new()
local folder: Folder

local function dust(position: Vector3, size: number, power: number): BasePart
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
	-- Kept around long enough to carry the impact sound too.
	Debris:AddItem(anchor, SOUND_LIFETIME)
	return anchor
end

-- A crunch from `parent`'s position: bigger rocks sound deeper, harder hits louder.
local function playImpactSound(parent: Instance, size: number, power: number)
	if activeSounds >= MAX_IMPACT_SOUNDS then
		return
	end
	activeSounds += 1
	task.delay(SOUND_LIFETIME, function()
		activeSounds -= 1
	end)

	local sizeAlpha = math.clamp((size - T.BoulderSize.Min) / (T.BoulderSize.Max - T.BoulderSize.Min), 0, 1)
	local sound = Instance.new("Sound")
	sound.Name = "RockImpact"
	sound.SoundId = Config.Sounds.RockImpact
	sound.PlaybackSpeed = (0.95 - 0.25 * sizeAlpha) * rng:NextNumber(0.94, 1.06)
	sound.Volume = 0.5 + 0.6 * power
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = ROLLOFF_MIN
	sound.RollOffMaxDistance = ROLLOFF_MAX
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, SOUND_LIFETIME)
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
	local anchor = dust(position, size, power)
	chips(position, power)
	playImpactSound(anchor, size, power)

	local here = listenerPosition()
	if here then
		local distance = (here - position).Magnitude
		if distance < NEAR_IMPACT then
			lastNearImpact = os.clock()
		end
		if distance < BB.ShakeRadius then
			local closeness = 1 - distance / BB.ShakeRadius
			CameraShake.Kick(BB.ShakeStrength * (0.35 + 0.65 * closeness) * (0.6 + 0.4 * power), JOLT_DURATION)
		end
	end
end

-- A rock hit this player directly.
local function onHit(power: number)
	CameraShake.Kick(BB.HitShakeStrength * (0.6 + 0.4 * power), JOLT_DURATION + 0.15)
	-- The broadcast impact usually just played its crunch right here; only fill in if it didn't
	-- (the boulder's blast can be cooling down from a bounce).
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and os.clock() - lastNearImpact > 0.3 then
		playImpactSound(root, T.BoulderSize.Max, power)
	end
end

function RockfallEffects.Start()
	folder = Instance.new("Folder")
	folder.Name = "MountIgnisRockfall"
	folder.Parent = workspace
	Net.Event("RockImpact").OnClientEvent:Connect(onImpact)
	Net.Event("RockHit").OnClientEvent:Connect(onHit)
end

return RockfallEffects
