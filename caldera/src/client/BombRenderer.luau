--[[
	BombRenderer
	Animates lava bombs from the arc the server sent, using the shared Ballistics formula and
	the synced server clock. A warning ring appears where each bomb will land and tightens as it
	falls, which is what gives players a fair chance to dodge.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Ballistics = require(Shared.Ballistics)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local CameraShake = require(script.Parent.CameraShake)

local BombRenderer = {}

type Bomb = {
	Data: { [string]: any },
	Ball: Part,
	Marker: Part,
}

local active: { Bomb } = {}
local folder: Folder
local rng = Random.new()

local function makeBall(size: number): Part
	local ball = Instance.new("Part")
	ball.Name = "LavaBomb"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * size
	ball.Material = Enum.Material.Neon
	ball.Color = Color3.fromRGB(255, 122, 36)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false

	local fire = Instance.new("Fire")
	fire.Size = size * 1.6
	fire.Heat = 0
	fire.Color = Color3.fromRGB(255, 150, 50)
	fire.SecondaryColor = Color3.fromRGB(120, 40, 20)
	fire.Parent = ball

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 130, 50)
	light.Range = 14
	light.Brightness = 2
	light.Parent = ball

	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, size * 0.4, 0)
	top.Parent = ball
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -size * 0.4, 0)
	bottom.Parent = ball
	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = 0.7
	trail.FaceCamera = true
	trail.LightEmission = 0.8
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 160, 60), Color3.fromRGB(60, 50, 48))
	trail.Transparency = NumberSequence.new(0.1, 1)
	trail.Parent = ball
	return ball
end

local function makeMarker(position: Vector3, normal: Vector3, radius: number): Part
	local marker = Instance.new("Part")
	marker.Name = "ImpactWarning"
	marker.Shape = Enum.PartType.Cylinder
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.CastShadow = false
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(255, 50, 30)
	marker.Transparency = 0.7
	marker.Size = Vector3.new(0.15, radius * 2, radius * 2)
	-- A cylinder's flat faces point along its X axis; align X with the surface normal.
	local side = if math.abs(normal.Y) < 0.95 then Vector3.yAxis else Vector3.zAxis
	local yAxis = normal:Cross(side).Unit
	marker.CFrame = CFrame.fromMatrix(position + normal * 0.1, normal, yAxis)
	return marker
end

local function burst(position: Vector3, normal: Vector3, size: number)
	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = size * 3
	explosion.BlastPressure = 0
	explosion.DestroyJointRadiusPercent = 0
	explosion.ExplosionType = Enum.ExplosionType.NoCraters
	explosion.Parent = workspace

	-- Molten chunks thrown out of the impact.
	for _ = 1, 7 do
		local chunk = Instance.new("Part")
		chunk.Name = "Spatter"
		chunk.Size = Vector3.one * rng:NextNumber(0.5, 1.2)
		chunk.Material = if rng:NextNumber() < 0.5 then Enum.Material.Neon else Enum.Material.Basalt
		chunk.Color = Color3.fromRGB(255, rng:NextInteger(80, 150), 30)
		chunk.CanQuery = false
		chunk.CanTouch = false
		chunk.CastShadow = false
		-- Same group as server debris, so spatter never shoves the player.
		chunk.CollisionGroup = Config.CollisionGroups.Debris
		chunk.CFrame = CFrame.new(position + normal * 1.5)
		local spray = (normal * rng:NextNumber(0.8, 1.4) + Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))).Unit
		chunk.AssemblyLinearVelocity = spray * rng:NextNumber(25, 55)
		chunk.Parent = folder
		Debris:AddItem(chunk, rng:NextNumber(1.5, 3))
	end
	CameraShake.Impulse(position, 0.5 * size / 4.6, 140)
end

local function onLaunched(data)
	local ball = makeBall(data.Size)
	ball.CFrame = CFrame.new(data.Origin)
	ball.Parent = folder
	local marker = makeMarker(data.Impact, data.Normal, data.Radius)
	marker.Parent = folder
	table.insert(active, { Data = data, Ball = ball, Marker = marker })
end

local function update()
	local now = workspace:GetServerTimeNow()
	for i = #active, 1, -1 do
		local bomb = active[i]
		local data = bomb.Data
		local t = now - data.Start
		if t >= data.Duration then
			table.remove(active, i)
			bomb.Ball:Destroy()
			bomb.Marker:Destroy()
			-- Skip the effect if this client was so far behind that the impact is old news.
			if t - data.Duration < 1 then
				burst(data.Impact, data.Normal, data.Size)
			end
		elseif t >= 0 then
			bomb.Ball.CFrame = CFrame.new(Ballistics.PositionAt(data.Origin, data.Velocity, data.Gravity, t))
			local progress = t / data.Duration
			-- The ring shrinks to the blast radius and flashes faster as the bomb closes in.
			local radius = data.Radius * (1.6 - 0.6 * progress)
			bomb.Marker.Size = Vector3.new(0.15, radius * 2, radius * 2)
			bomb.Marker.Transparency = 0.45 + 0.35 * (0.5 + 0.5 * math.sin(now * (6 + progress * 18)))
		end
	end
end

function BombRenderer.Start()
	folder = Instance.new("Folder")
	folder.Name = "MountIgnisBombs"
	folder.Parent = workspace
	Net.Event("BombLaunched").OnClientEvent:Connect(onLaunched)
	RunService.RenderStepped:Connect(update)
end

return BombRenderer
