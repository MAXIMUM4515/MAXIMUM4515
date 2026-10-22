--[[
	Extinguisher (client)
	The fire extinguisher shop panel and spray aiming.

	The panel on the right edge sells the developer product and shows the foam left in the tank.
	While the trigger is held, the character turns to face where the player aims (the point under
	the mouse on a computer, straight ahead of the camera on touch and gamepad). The server sprays
	along the character's facing, so this is all the aiming there is.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local UiKit = require(script.Parent.UiKit)

local EX = Config.Extinguisher
local FOAM = Color3.fromRGB(140, 200, 255)
local TOOL_ATTRIBUTE = "FireExtinguisher"

local player = Players.LocalPlayer
local create = UiKit.create
local corner = UiKit.corner

local Extinguisher = {}

--------------------------------------------------------------------------------------------
-- Shop panel
--------------------------------------------------------------------------------------------

local function buildShop()
	-- With no product set up there is nothing to buy, except in Studio where it is free for testing.
	local testing = EX.ProductId == 0
	if testing and not RunService:IsStudio() then
		return
	end

	local gui = create("ScreenGui", {
		Name = "MountIgnisShop",
		ResetOnSpawn = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local panel = create("Frame", {
		Name = "Extinguisher",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(196, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = UiKit.Panel,
		BackgroundTransparency = 0.2,
		Parent = gui,
	}, {
		corner(12),
		UiKit.padding(10),
		create("UIStroke", { Thickness = 2, Color = FOAM, Transparency = 0.35 }),
		create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	create("TextLabel", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		TextSize = 16,
		TextColor3 = FOAM,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "FIRE EXTINGUISHER",
		Parent = panel,
	})
	create("TextLabel", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextWrapped = true,
		TextColor3 = UiKit.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Spray to cool down and put out anyone on fire, you included.",
		Parent = panel,
	})

	-- Foam gauge, shown while they own one. A full bar is one tank (extra tanks keep it full).
	local gaugeFill = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = FOAM,
		BorderSizePixel = 0,
	}, { corner(4) })
	local gaugeText = create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(20, 30, 40),
		ZIndex = 2,
		Text = "",
	})
	local gauge = create("Frame", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundColor3 = Color3.fromRGB(50, 60, 70),
		BorderSizePixel = 0,
		Visible = false,
		Parent = panel,
	}, { corner(4), gaugeFill, gaugeText })

	local button = create("TextButton", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = FOAM,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(20, 30, 40),
		Text = "BUY",
		Parent = panel,
	}, { corner(8), UiKit.padding(8), create("UITextSizeConstraint", { MaxTextSize = 16 }) })

	local price: string? = nil
	local function refresh()
		local foam = player:GetAttribute("ExtinguisherFoam")
		local owned = typeof(foam) == "number" and foam > 0
		gauge.Visible = owned
		if owned then
			gaugeFill.Size = UDim2.fromScale(math.clamp(foam / EX.TankSeconds, 0, 1), 1)
			gaugeText.Text = `{math.ceil(foam)}s of foam`
		end
		local action = if owned then "ADD FOAM" else "BUY"
		button.Text = if testing then `{action} (FREE IN STUDIO)` elseif price then `{action} · {price}` else action
	end
	player:GetAttributeChangedSignal("ExtinguisherFoam"):Connect(refresh)
	refresh()

	if not testing then
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(EX.ProductId, Enum.InfoType.Product)
			end)
			if ok and info and info.PriceInRobux then
				price = `R$ {info.PriceInRobux}`
				refresh()
			end
		end)
	end

	button.Activated:Connect(function()
		if testing then
			Net.Event("ExtinguisherTest"):FireServer()
		else
			MarketplaceService:PromptProductPurchase(player, EX.ProductId)
		end
	end)
end

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
	buildShop()
end

return Extinguisher
