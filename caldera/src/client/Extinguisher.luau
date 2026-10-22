--[[
	Extinguisher (client)
	Spray aiming. While the trigger is held, the character turns to face where the player aims (the
	point under the mouse on a computer, straight ahead of the camera on touch and gamepad). The
	server sprays along the character's facing, so this is all the aiming there is. The extinguisher
	is sold in the Shop panel.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local TOOL_ATTRIBUTE = "FireExtinguisher"

local player = Players.LocalPlayer

local Extinguisher = {}

--------------------------------------------------------------------------------------------
-- Aiming
--------------------------------------------------------------------------------------------

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude

local aimConnection: RBXScriptConnection? = nil
local aimHumanoid: Humanoid? = nil

local function stopAiming()
	if aimConnection then
		aimConnection:Disconnect()
		aimConnection = nil
	end
	if aimHumanoid then
		aimHumanoid.AutoRotate = true
		aimHumanoid = nil
	end
end

-- The point being aimed at: under the mouse if there is one, otherwise straight ahead of the camera.
local function aimPoint(camera: Camera): Vector3
	if UserInputService.MouseEnabled then
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 500, aimParams)
		return if hit then hit.Position else ray.Origin + ray.Direction * 500
	end
	return camera.CFrame.Position + camera.CFrame.LookVector * 500
end

local function startAiming(character: Model)
	stopAiming()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return
	end
	aimHumanoid = humanoid
	humanoid.AutoRotate = false
	aimParams.FilterDescendantsInstances = { character }
	aimConnection = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if humanoid.Health <= 0 or not root.Parent or not camera then
			stopAiming()
			return
		end
		local position = root.Position
		local target = aimPoint(camera)
		local flat = Vector3.new(target.X - position.X, 0, target.Z - position.Z)
		if flat.Magnitude > 0.5 then
			root.CFrame = CFrame.lookAt(position, position + flat)
		end
	end)
end

local watched: { [Tool]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function watchTool(tool: Tool)
	if watched[tool] then
		return
	end
	watched[tool] = true
	tool.Activated:Connect(function()
		local foam = player:GetAttribute("ExtinguisherFoam")
		local character = player.Character
		if typeof(foam) == "number" and foam > 0 and character and tool.Parent == character then
			startAiming(character)
		end
	end)
	tool.Deactivated:Connect(stopAiming)
	tool.Unequipped:Connect(stopAiming)
	tool.AncestryChanged:Connect(function()
		if tool.Parent ~= player.Character then
			stopAiming()
		end
	end)
end

local function onCharacter(character: Model)
	stopAiming()
	local function check(child: Instance)
		if child:IsA("Tool") and child:GetAttribute(TOOL_ATTRIBUTE) then
			watchTool(child)
		end
	end
	character.ChildAdded:Connect(check)
	for _, child in character:GetChildren() do
		check(child)
	end
end

function Extinguisher.Start()
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
	-- An empty tank ends the spray even if the trigger is still held.
	player:GetAttributeChangedSignal("ExtinguisherFoam"):Connect(function()
		if player:GetAttribute("ExtinguisherFoam") == nil then
			stopAiming()
		end
	end)
end

return Extinguisher
