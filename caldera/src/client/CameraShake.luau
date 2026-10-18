--[[
	CameraShake
	Noise-driven camera shake from two sources: the continuous tremor intensity (scaled by how
	close you are to the volcano) and short impulses from impacts and explosions.

	The offset is applied right after the default camera updates and removed right before its
	next update, so it never accumulates into the player's actual camera rotation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local CameraShake = {}

local MAX_ANGLE = math.rad(2.2)
local MAX_OFFSET = 0.55
local FREQUENCY = 14

local trauma = 0
local applied: CFrame? = nil

-- Adds a burst of shake that fades with distance from `position`.
function CameraShake.Impulse(position: Vector3, strength: number, radius: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	local falloff = 1 - math.clamp(distance / radius, 0, 1)
	trauma = math.min(1.4, trauma + strength * falloff * falloff)
end

function CameraShake.Start()
	RunService:BindToRenderStep("CalderaShakeUndo", Enum.RenderPriority.Camera.Value - 1, function()
		local camera = workspace.CurrentCamera
		if applied and camera then
			camera.CFrame = camera.CFrame * applied:Inverse()
		end
		applied = nil
	end)

	RunService:BindToRenderStep("CalderaShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		trauma = math.max(0, trauma - dt * 1.1)

		local tremor = Net.GetState("Tremor") or 0
		local distance = (camera.CFrame.Position - Config.Volcano.Center).Magnitude
		local proximity = math.clamp(1 - distance / 700, 0.3, 1)
		local amount = math.min(1, tremor * 0.42 * proximity + trauma)
		local shake = amount * amount
		if shake < 0.0005 then
			return
		end

		local t = os.clock() * FREQUENCY
		local offset = CFrame.new(
			math.noise(t, 0, 0.5) * MAX_OFFSET * shake,
			math.noise(0, t, 1.5) * MAX_OFFSET * shake,
			math.noise(t, 2.5, 0) * MAX_OFFSET * shake * 0.5
		) * CFrame.Angles(
			math.noise(t, 3.5, 7) * MAX_ANGLE * shake,
			math.noise(4.5, t, 9) * MAX_ANGLE * shake,
			math.noise(5.5, 11, t) * MAX_ANGLE * shake * 0.6
		)
		camera.CFrame = camera.CFrame * offset
		applied = offset
	end)

	Net.Event("CameraImpulse").OnClientEvent:Connect(CameraShake.Impulse)
end

return CameraShake
