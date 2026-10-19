--[[
	Volcano
	The director. Each phase of the eruption switches the underlying systems on, off or up:

		Rumbling     tremors build, steam vents hiss, boulders shake loose from the summit
		Eruption     the crater explodes, lava pours through the breach, bombs rain down,
		             a flank fissure tears open, ash darkens the sky
		Pyroclastic  the eruption column collapses into a pyroclastic flow
		Aftermath    vents die down and the flows crust over

	Anything a phase starts goes into the phase janitor, so switching phases (or ending the
	round early) always leaves a clean slate.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Heightmap = require(Shared.Heightmap)
local Janitor = require(Shared.Janitor)
local Net = require(Shared.Net)
local Hazards = require(script.Parent.Hazards)
local LavaFlow = require(script.Parent.LavaFlow)
local LavaBombs = require(script.Parent.LavaBombs)
local MapBuilder = require(script.Parent.MapBuilder)
local Pyroclastic = require(script.Parent.Pyroclastic)
local Tremors = require(script.Parent.Tremors)

local B = Config.Bombs
local L = Config.Lava
local T = Config.Tremor
local C = Config.Colors

local Volcano = {}

local phase = Janitor.new()
local rng = Random.new()
local announceEvent = Net.Event("Announce")
local impulseEvent = Net.Event("CameraImpulse")

local crater = Vector3.zero
local bombRate = 0
local mainVent: LavaFlow.Source? = nil

type Features = {
	Light: PointLight,
	Plume: Smoke,
	Fountain: ParticleEmitter,
	Vents: { Smoke },
}
local features: Features

local function announce(text: string, color: Color3, duration: number, style: string?)
	announceEvent:FireAllClients(text, color, duration, style or "normal")
end

local function blast(position: Vector3, radius: number)
	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = radius
	explosion.BlastPressure = 0
	explosion.DestroyJointRadiusPercent = 0
	explosion.ExplosionType = Enum.ExplosionType.NoCraters
	explosion.Parent = workspace
end

local function anchor(name: string, position: Vector3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(8, 1, 8)
	part.Position = position
	part.Parent = parent
	return part
end

local function createFeatures(effects: Folder)
	local lightPart = anchor("CraterGlow", crater + Vector3.new(0, 6, 0), effects)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 120, 50)
	light.Range = 60
	light.Brightness = 0.6
	light.Shadows = false
	light.Parent = lightPart

	local plumePart = anchor("Plume", crater + Vector3.new(0, 16, 0), effects)
	local plume = Instance.new("Smoke")
	plume.Color = Color3.fromRGB(96, 88, 84)
	plume.Opacity = 0.12
	plume.RiseVelocity = 18
	plume.Size = 40
	plume.Parent = plumePart

	local fountainPart = anchor("Fountain", crater + Vector3.new(0, 2, 0), effects)
	local fountain = Instance.new("ParticleEmitter")
	fountain.Texture = "rbxasset://textures/particles/fire_main.dds"
	fountain.Rate = 0
	fountain.Lifetime = NumberRange.new(2.4, 3.6)
	fountain.Speed = NumberRange.new(55, 95)
	fountain.SpreadAngle = Vector2.new(16, 16)
	fountain.EmissionDirection = Enum.NormalId.Top
	fountain.Acceleration = Vector3.new(0, -workspace.Gravity * 0.32, 0)
	fountain.Drag = 0.3
	fountain.LightEmission = 1
	fountain.LightInfluence = 0
	fountain.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.4),
		NumberSequenceKeypoint.new(0.7, 1.4),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	fountain.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 120)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 110, 30)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 30, 20)),
	})
	fountain.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	fountain.Parent = fountainPart

	-- Steam vents dotted around the upper flanks.
	local vents = {}
	for i = 1, 5 do
		local angle = (i / 5) * math.pi * 2 + 0.4
		local distance = Config.Volcano.SummitRadius + 18 + (i % 2) * 14
		local x = crater.X + math.cos(angle) * distance
		local z = crater.Z + math.sin(angle) * distance
		local ventPart = anchor("SteamVent", Vector3.new(x, Heightmap.Height(x, z) + 1, z), effects)
		local smoke = Instance.new("Smoke")
		smoke.Color = Color3.fromRGB(220, 220, 220)
		smoke.Opacity = 0.25
		smoke.RiseVelocity = 12
		smoke.Size = 8
		smoke.Enabled = false
		smoke.Parent = ventPart
		table.insert(vents, smoke)
	end

	features = { Light = light, Plume = plume, Fountain = fountain, Vents = vents }
end

local function setDormant()
	features.Light.Brightness = 0.6
	features.Plume.Opacity = 0.12
	features.Plume.Size = 40
	features.Fountain.Rate = 0
	for _, vent in features.Vents do
		vent.Enabled = false
	end
end

-- Players still alive in the round; bombs only hunt these.
local function participantRoots(): { BasePart }
	local roots = {}
	for _, state in Hazards.Participants() do
		table.insert(roots, state.Root)
	end
	return roots
end

local function launchBomb()
	local origin = crater + Vector3.new(rng:NextNumber(-8, 8), 6, rng:NextNumber(-8, 8))
	local flightTime = rng:NextNumber(B.FlightTime.Min, B.FlightTime.Max)
	local target = LavaBombs.PickTarget(crater, flightTime, participantRoots())
	if target then
		LavaBombs.Launch(origin, target, flightTime, rng:NextNumber(B.Size.Min, B.Size.Max))
	end
end

local function compass(direction: Vector3): string
	if math.abs(direction.X) > math.abs(direction.Z) then
		return if direction.X > 0 then "eastern" else "western"
	end
	-- Roblox convention: -Z is north.
	return if direction.Z < 0 then "northern" else "southern"
end

local function openFissure()
	-- Tear open the flank roughly toward the players, so it matters.
	local toward = Pyroclastic.ChooseDirection(crater, Vector3.zAxis)
	local angle = math.atan2(toward.Z, toward.X) + rng:NextNumber(-0.9, 0.9)
	local distance = rng:NextNumber(64, 92)
	local x = crater.X + math.cos(angle) * distance
	local z = crater.Z + math.sin(angle) * distance
	local position = Vector3.new(x, Heightmap.Height(x, z), z)

	workspace.Terrain:FillBall(position, 6, Enum.Material.Air)
	MapBuilder.MarkTerrainDirty(position, 10)
	LavaFlow.RefreshGround(position, 10)
	blast(position + Vector3.new(0, 2, 0), 18)
	impulseEvent:FireAllClients(position, 0.8, 350)

	local source = LavaFlow.AddSource(position, L.FissureRadius, L.FissureRate)
	local smokePart = anchor("Fissure", position + Vector3.new(0, 3, 0), MapBuilder.Folders.Effects)
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(70, 64, 60)
	smoke.Opacity = 0.4
	smoke.RiseVelocity = 16
	smoke.Size = 16
	smoke.Parent = smokePart

	announce(
		`A fissure tore open on the {compass(Vector3.new(math.cos(angle), 0, math.sin(angle)))} flank!`,
		C.Eruption,
		4
	)

	local function close()
		LavaFlow.RemoveSource(source)
		smokePart:Destroy()
	end
	phase:Add(task.delay(L.FissureDuration, close))
	phase:Add(close)
end

-- Gradually moves a value from `from` to `to` over `seconds`, cancelled with the phase.
local function ramp(seconds: number, from: number, to: number, apply: (number) -> ())
	phase:Add(task.spawn(function()
		local started = os.clock()
		while true do
			local alpha = math.clamp((os.clock() - started) / seconds, 0, 1)
			apply(from + (to - from) * alpha)
			if alpha >= 1 then
				break
			end
			task.wait(0.25)
		end
	end))
end

local handlers: { [string]: (number) -> () } = {}

function handlers.Rumbling(duration: number)
	announce(`The ground is shaking... {Config.Volcano.Name} is waking up!`, C.Rumbling, 4)
	Tremors.SetBoulders(true)
	for _, vent in features.Vents do
		vent.Enabled = true
	end
	features.Plume.Opacity = 0.25
	ramp(duration, T.RumblingIntensity.From, T.RumblingIntensity.To, Tremors.SetIntensity)
	ramp(duration, 0.6, 1.8, function(value)
		features.Light.Brightness = value
	end)
	Net.SetState("Ash", 0.15)
end

function handlers.Eruption(_duration: number)
	announce("ERUPTION! Watch for red rings: lava bombs are incoming!", C.Eruption, 5, "big")
	blast(crater + Vector3.new(0, 4, 0), 40)
	impulseEvent:FireAllClients(crater, 1.4, 900)
	Tremors.SetIntensity(T.EruptionIntensity)
	features.Fountain.Rate = 150
	features.Plume.Opacity = 0.55
	features.Plume.Size = 70
	features.Light.Brightness = 3.2
	Net.SetState("Ash", 1)

	-- Output builds up over the first seconds instead of switching on at full blast.
	local vent = LavaFlow.AddSource(crater, L.VentRadius, L.VentRate * 0.3)
	mainVent = vent
	ramp(14, L.VentRate * 0.3, L.VentRate, function(value)
		vent.Rate = value
	end)
	ramp(8, B.Rate.Eruption * 0.3, B.Rate.Eruption, function(value)
		bombRate = value
	end)

	phase:Add(task.delay(L.FissureDelay, openFissure))
	phase:Add(task.delay(16, function()
		announce("Lava is pouring through the breach toward Emberfall!", C.Eruption, 4)
	end))
end

function handlers.Pyroclastic(_duration: number)
	announce("PYROCLASTIC FLOW!", C.Pyroclastic, 4, "big")
	blast(crater + Vector3.new(0, 10, 0), 50)
	impulseEvent:FireAllClients(crater, 1.1, 900)
	Tremors.SetIntensity(T.PyroclasticIntensity)
	if mainVent then
		mainVent.Rate = L.VentRate * 0.35
	end
	bombRate = B.Rate.Pyroclastic
	features.Fountain.Rate = 60
	Pyroclastic.Launch(crater + Vector3.new(0, 8, 0), Config.Map.VillageCenter - crater)
	phase:Add(Pyroclastic.Stop)
end

function handlers.Aftermath(duration: number)
	announce("The eruption is fading. Glowing rock is still deadly...", C.Aftermath, 4)
	if mainVent then
		LavaFlow.RemoveSource(mainVent)
		mainVent = nil
	end
	bombRate = 0
	Tremors.SetBoulders(false)
	ramp(duration * 0.5, T.PyroclasticIntensity * 0.4, 0, Tremors.SetIntensity)
	LavaFlow.SetCooling(L.AftermathCooling)
	features.Fountain.Rate = 0
	features.Plume.Opacity = 0.22
	for _, vent in features.Vents do
		vent.Enabled = true
	end
	Net.SetState("Ash", 0.45)
end

function Volcano.Init()
	crater = MapBuilder.CraterPosition
	createFeatures(MapBuilder.Folders.Effects)
	setDormant()
	Net.SetState("Ash", 0)

	-- Bomb spawner: a rate accumulator so fractional rates (0.8 bombs/s) work.
	task.spawn(function()
		local pending = 0
		while true do
			local dt = task.wait(0.1)
			if bombRate > 0 then
				pending += bombRate * dt
				while pending >= 1 do
					pending -= 1
					local ok, err = pcall(launchBomb)
					if not ok then
						warn("[Volcano] bomb launch failed:", err)
					end
				end
			else
				pending = 0
			end
		end
	end)
end

function Volcano.EnterPhase(id: string, duration: number)
	phase:Cleanup()
	local handler = handlers[id]
	if handler then
		handler(duration)
	else
		warn(`[Volcano] no handler for phase "{id}"`)
	end
end

function Volcano.EndRound()
	phase:Cleanup()
	bombRate = 0
	if mainVent then
		LavaFlow.RemoveSource(mainVent)
		mainVent = nil
	end
	Pyroclastic.Stop()
	Tremors.SetIntensity(0)
	Tremors.SetBoulders(false)
	setDormant()
	Net.SetState("Ash", 0)
end

return Volcano
