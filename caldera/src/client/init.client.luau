--[[
	Mount Ignis - client bootstrap.
	Starts the visual controllers and applies server-requested knockback to the local
	character (which this client simulates, so it is the only place velocity can be set).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Net = require(Shared.Net)

local CameraShake = require(script.CameraShake)
local LavaRenderer = require(script.LavaRenderer)
local BombRenderer = require(script.BombRenderer)
local AshSky = require(script.AshSky)
local PyroclasticVisual = require(script.PyroclasticVisual)
local RockfallEffects = require(script.RockfallEffects)
local GuidePopup = require(script.GuidePopup)
local HUD = require(script.HUD)

local player = Players.LocalPlayer

-- Each controller starts on its own thread so one that waits (or fails) never holds up the rest.
local function start(name: string, controller: { Start: () -> () })
	task.spawn(function()
		local ok, err = pcall(controller.Start)
		if not ok then
			warn(`[Mount Ignis] {name} failed to start:`, err)
		end
	end)
end

start("HUD", HUD)
start("GuidePopup", GuidePopup)
start("CameraShake", CameraShake)
start("LavaRenderer", LavaRenderer)
start("BombRenderer", BombRenderer)
start("PyroclasticVisual", PyroclasticVisual)
start("RockfallEffects", RockfallEffects)
start("AshSky", AshSky)

Net.Event("Knockback").OnClientEvent:Connect(function(velocity: Vector3, tumble: boolean)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	-- Sanity limit: never trust a velocity big enough to fling someone across the map.
	if velocity.Magnitude > 200 then
		velocity = velocity.Unit * 200
	end
	if tumble then
		humanoid:ChangeState(Enum.HumanoidStateType.FallingDown)
		task.delay(1.1, function()
			if humanoid.Health > 0 and humanoid:GetState() == Enum.HumanoidStateType.FallingDown then
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end)
	else
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
	root.AssemblyLinearVelocity += velocity
end)
