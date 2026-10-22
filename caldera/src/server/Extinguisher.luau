--[[
	Extinguisher
	The fire extinguisher developer product. Each purchase adds a tank of foam (TankSeconds of
	spraying). The player keeps the extinguisher through deaths and rounds until the foam runs out
	or they leave the server; buying again tops it up with another tank.

	Holding the trigger sprays a cone of foam, a portable lake that takes its time: everyone in it,
	the holder included, can't catch fire while it hits them, and their heat meter falls until the
	flames go out (Hazards.Spray). The owning client turns the character toward where the player
	aims, so the spray simply follows the character's facing here. Walls block it.

	The tool is built in code like everything else. A copy sits in the player's StarterGear, so a
	fresh one comes back with every respawn; the foam is tracked here, per player, not on the tool.
	Purchases arrive through the Shop.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local SprayCone = require(Shared.SprayCone)
local Hazards = require(script.Parent.Hazards)
local Shop = require(script.Parent.Shop)

local EX = Config.Extinguisher

-- Marks the tool so the client and the equip hook can tell it apart from anything else.
local TOOL_ATTRIBUTE = "FireExtinguisher"
local FOAM_COLOR = Color3.fromRGB(140, 200, 255)

local Extinguisher = {}

local foam: { [Player]: number } = {}
local sprayers: { [Player]: Tool } = {}
local hooked: { [Tool]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local template: Tool

local announceEvent = Net.Event("Announce")
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Include

--------------------------------------------------------------------------------------------
-- The tool
--------------------------------------------------------------------------------------------

local RED = Color3.fromRGB(196, 32, 28)
local BLACK = Color3.fromRGB(30, 30, 32)
local STEEL = Color3.fromRGB(160, 160, 168)
local LABEL = Color3.fromRGB(236, 232, 224)

local VERTICAL = CFrame.Angles(0, 0, math.pi / 2) -- turns a cylinder's axis (X) upright
local FORWARD = CFrame.Angles(0, math.pi / 2, 0) -- turns it to point forward (-Z)

local function toolPart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

--[[
	Laid out in the Handle's space as it is held with the default grip: +Y up, -Z where the character
	faces. The hand closes on the carry handle at the origin, the cylinder hangs below it and the
	horn points forward. The foam comes out of the Nozzle attachment at the horn's mouth.
]]
local function buildTemplate(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Fire Extinguisher"
	tool.ToolTip = "Hold to spray. Puts out anyone it hits, you included."
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool:SetAttribute(TOOL_ATTRIBUTE, true)

	local handle = toolPart("Handle", Vector3.new(0.35, 0.35, 1.1), BLACK, Enum.Material.Metal)
	handle.Parent = tool

	local function piece(name: string, shape: Enum.PartType, size: Vector3, offset: CFrame, color: Color3)
		local painted = color == RED or color == LABEL
		local part = toolPart(name, size, color, if painted then Enum.Material.SmoothPlastic else Enum.Material.Metal)
		part.Shape = shape
		part.CFrame = offset
		local weld = Instance.new("Weld")
		weld.Part0 = handle
		weld.Part1 = part
		weld.C0 = offset
		weld.Parent = part
		part.Parent = tool
	end

	local cylinder, ball, block = Enum.PartType.Cylinder, Enum.PartType.Ball, Enum.PartType.Block
	piece("Lever", block, Vector3.new(0.3, 0.12, 1), CFrame.new(0, 0.26, -0.1), STEEL)
	piece("Neck", cylinder, Vector3.new(0.3, 0.36, 0.36), CFrame.new(0, -0.2, 0.1) * VERTICAL, STEEL)
	piece("Dome", ball, Vector3.new(0.85, 0.85, 0.85), CFrame.new(0, -0.55, 0.1), RED)
	piece("Body", cylinder, Vector3.new(1.8, 0.85, 0.85), CFrame.new(0, -1.45, 0.1) * VERTICAL, RED)
	piece("Label", cylinder, Vector3.new(0.5, 0.87, 0.87), CFrame.new(0, -1.35, 0.1) * VERTICAL, LABEL)
	piece("Base", cylinder, Vector3.new(0.1, 0.88, 0.88), CFrame.new(0, -2.3, 0.1) * VERTICAL, BLACK)
	piece("Hose", cylinder, Vector3.new(0.75, 0.18, 0.18), CFrame.new(0, -0.3, -0.4) * FORWARD, BLACK)
	piece("Horn", cylinder, Vector3.new(0.5, 0.36, 0.36), CFrame.new(0, -0.3, -0.95) * FORWARD, BLACK)

	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, -0.3, -1.25)
	nozzle.Parent = handle

	-- Off until the trigger is held. Front = the attachment's -Z, out of the horn.
	local spray = Instance.new("ParticleEmitter")
	spray.Name = "Spray"
	spray.Enabled = false
	spray.Texture = "rbxasset://textures/particles/smoke_main.dds"
	spray.EmissionDirection = Enum.NormalId.Front
	spray.Rate = 110
	-- Drag 1 over this lifetime carries the foam about Config.Extinguisher.Range studs.
	spray.Speed = NumberRange.new(36, 44)
	spray.Drag = 1
	spray.Lifetime = NumberRange.new(0.5, 0.65)
	spray.SpreadAngle = Vector2.new(14, 14)
	spray.Acceleration = Vector3.new(0, -10, 0)
	spray.Rotation = NumberRange.new(0, 360)
	spray.RotSpeed = NumberRange.new(-120, 120)
	spray.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 3.4),
	})
	spray.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.7, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	spray.Color = ColorSequence.new(Color3.fromRGB(245, 250, 255), Color3.fromRGB(200, 222, 240))
	spray.LightEmission = 0.1
	spray.Parent = nozzle

	return tool
end

local function findTool(container: Instance?): Tool?
	if container then
		for _, child in container:GetChildren() do
			if child:IsA("Tool") and child:GetAttribute(TOOL_ATTRIBUTE) then
				return child
			end
		end
	end
	return nil
end

-- One copy in StarterGear for respawns, and one to use now unless they already have it.
local function give(player: Player)
	local gear = player:FindFirstChildOfClass("StarterGear")
	if gear and not findTool(gear) then
		template:Clone().Parent = gear
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack and not findTool(backpack) and not findTool(player.Character) then
		template:Clone().Parent = backpack
	end
end

local function takeAway(player: Player)
	local containers: { Instance? } =
		{ player:FindFirstChildOfClass("StarterGear"), player:FindFirstChildOfClass("Backpack"), player.Character }
	for index = 1, 3 do
		local tool = findTool(containers[index])
		if tool then
			tool:Destroy()
		end
	end
end

--------------------------------------------------------------------------------------------
-- Foam and spraying
--------------------------------------------------------------------------------------------

-- Replicates the foam left (seconds) for the shop panel; nil when they have no extinguisher.
local function publishFoam(player: Player)
	local left = foam[player]
	player:SetAttribute("ExtinguisherFoam", if left then math.ceil(left * 10) / 10 else nil)
end

local function setSpraying(tool: Tool, on: boolean)
	local spray = tool:FindFirstChild("Spray", true)
	if spray and spray:IsA("ParticleEmitter") then
		spray.Enabled = on
	end
end

local function stopSpraying(player: Player)
	local tool = sprayers[player]
	if tool then
		sprayers[player] = nil
		setSpraying(tool, false)
	end
end

local function startSpraying(player: Player, tool: Tool)
	if (foam[player] or 0) > 0 and tool.Parent == player.Character then
		sprayers[player] = tool
		setSpraying(tool, true)
	end
end

local function runDry(player: Player)
	stopSpraying(player)
	foam[player] = nil
	publishFoam(player)
	takeAway(player)
	announceEvent:FireClient(player, "Your fire extinguisher is empty.", FOAM_COLOR, 2.5, "small")
end

-- Every copy of the tool (StarterGear hands out new ones) is hooked the first time it is equipped.
local function hook(player: Player, tool: Tool)
	if hooked[tool] then
		return
	end
	hooked[tool] = true
	tool.Activated:Connect(function()
		startSpraying(player, tool)
	end)
	local function release()
		if sprayers[player] == tool then
			stopSpraying(player)
		end
	end
	tool.Deactivated:Connect(release)
	tool.Unequipped:Connect(release)
end

local function wallBetween(from: Vector3, to: Vector3): boolean
	return workspace:Raycast(from, to - from, wallParams) ~= nil
end

local function sprayTick(dt: number)
	for player, tool in sprayers do
		local character = player.Character
		local state = character and Hazards.GetState(character)
		local left = foam[player]
		if not state or not left or tool.Parent ~= character or state.Humanoid.Health <= 0 then
			stopSpraying(player)
			continue
		end

		-- The holder is always in their own spray.
		Hazards.Spray(state)
		local origin = state.Root.Position
		local facing = state.Root.CFrame.LookVector
		for _, other in Hazards.Alive() do
			local target = other.Root.Position
			if
				other ~= state
				and SprayCone.Contains(origin, facing, target, EX)
				and not wallBetween(origin, target)
			then
				Hazards.Spray(other)
			end
		end

		left = math.max(0, left - dt)
		foam[player] = left
		if left <= 0 then
			runDry(player)
		else
			publishFoam(player)
		end
	end
end

--------------------------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------------------------

local function grant(player: Player)
	foam[player] = (foam[player] or 0) + EX.TankSeconds
	publishFoam(player)
	give(player)
	announceEvent:FireClient(player, "Fire extinguisher ready! Hold to spray.", FOAM_COLOR, 3, "small")
end

--------------------------------------------------------------------------------------------

function Extinguisher.Init(folders: { Structures: Folder })
	template = buildTemplate()
	wallParams.FilterDescendantsInstances = { workspace.Terrain, folders.Structures }

	Shop.Register("Extinguisher", EX.ProductId, nil, grant)

	local function onCharacter(player: Player, character: Model)
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child:GetAttribute(TOOL_ATTRIBUTE) then
				hook(player, child)
			end
		end)
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		sprayers[player] = nil
		foam[player] = nil
	end)

	task.spawn(function()
		while true do
			local dt = task.wait(EX.Tick)
			local ok, err = pcall(sprayTick, dt)
			if not ok then
				warn("[Extinguisher]", err)
			end
		end
	end)
end

return Extinguisher
