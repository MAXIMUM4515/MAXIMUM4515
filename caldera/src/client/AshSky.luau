--[[
	AshSky
	Drives the sky from the replicated "Ash" level: thicker, browner atmosphere, an orange cast
	from the glow of the eruption, and ash flakes falling around the camera.
	Values blend smoothly over a few seconds instead of snapping between phases.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Net = require(Shared.Net)

local AshSky = {}

local BLEND_SPEED = 0.6
local ASH_COLOR = Color3.fromRGB(150, 112, 92)
local ASH_DECAY = Color3.fromRGB(70, 40, 30)
local ASH_TINT = Color3.fromRGB(255, 212, 186)
local ASH_AMBIENT = Color3.fromRGB(128, 76, 58)

local current = 0
local applied = -1

-- Extra darkening requested by other effects (the pyroclastic cloud), 0..1.
local smother = 0
local smotherTarget = 0

function AshSky.SetSmother(value: number)
	smotherTarget = math.clamp(value, 0, 1)
end

function AshSky.Start()
	local atmosphere = Lighting:WaitForChild("MountIgnisAtmosphere", 20) :: Atmosphere?
	local grade = Lighting:WaitForChild("MountIgnisGrade", 20) :: ColorCorrectionEffect?
	if not atmosphere or not grade then
		warn("[AshSky] lighting effects missing")
		return
	end

	local base = {
		Density = atmosphere.Density,
		Haze = atmosphere.Haze,
		Color = atmosphere.Color,
		Decay = atmosphere.Decay,
		Glare = atmosphere.Glare,
		Brightness = Lighting.Brightness,
		Ambient = Lighting.OutdoorAmbient,
		Saturation = grade.Saturation,
		Contrast = grade.Contrast,
	}

	local blur = Instance.new("BlurEffect")
	blur.Name = "MountIgnisSmother"
	blur.Size = 0
	blur.Parent = Lighting

	-- Ash flakes: an emitter on an invisible plate that follows the camera.
	local plate = Instance.new("Part")
	plate.Name = "AshFall"
	plate.Anchored = true
	plate.CanCollide = false
	plate.CanQuery = false
	plate.CanTouch = false
	plate.Transparency = 1
	plate.Size = Vector3.new(140, 1, 140)
	plate.Parent = workspace
	local flakes = Instance.new("ParticleEmitter")
	flakes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	flakes.Color = ColorSequence.new(Color3.fromRGB(70, 66, 64))
	flakes.LightEmission = 0
	flakes.LightInfluence = 1
	flakes.Size = NumberSequence.new(0.35, 0.2)
	flakes.Transparency = NumberSequence.new(0.2, 0.6)
	flakes.Lifetime = NumberRange.new(5, 8)
	flakes.Speed = NumberRange.new(6, 10)
	flakes.EmissionDirection = Enum.NormalId.Bottom
	flakes.Acceleration = Vector3.new(3, 0, 1.5)
	flakes.RotSpeed = NumberRange.new(-90, 90)
	flakes.Rate = 0
	flakes.Parent = plate

	RunService.RenderStepped:Connect(function(dt)
		local target = Net.GetState("Ash") or 0
		current += (target - current) * math.min(1, dt * BLEND_SPEED)
		smother += (smotherTarget - smother) * math.min(1, dt * 2.5)

		local camera = workspace.CurrentCamera
		if camera then
			plate.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, 28, 0))
		end

		local ash = math.clamp(current + smother * 0.6, 0, 1.4)
		if math.abs(ash - applied) < 0.002 then
			return
		end
		applied = ash
		local a = math.min(ash, 1)

		atmosphere.Density = base.Density + (0.5 - base.Density) * a + 0.2 * smother
		atmosphere.Haze = base.Haze + (6 - base.Haze) * a
		atmosphere.Color = base.Color:Lerp(ASH_COLOR, a)
		atmosphere.Decay = base.Decay:Lerp(ASH_DECAY, a)
		atmosphere.Glare = base.Glare * (1 - a)
		Lighting.Brightness = base.Brightness + (1.25 - base.Brightness) * a - smother * 0.6
		Lighting.OutdoorAmbient = base.Ambient:Lerp(ASH_AMBIENT, a)
		grade.TintColor = Color3.new(1, 1, 1):Lerp(ASH_TINT, a)
		grade.Saturation = base.Saturation - 0.15 * a
		grade.Contrast = base.Contrast + 0.08 * a
		grade.Brightness = -0.05 * a - 0.15 * smother
		blur.Size = 14 * smother
		flakes.Rate = 70 * a
	end)
end

return AshSky
