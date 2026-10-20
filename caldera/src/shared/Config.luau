--[[
	Config
	Every tunable number for the Mount Ignis disaster lives here so the eruption can be
	rebalanced without touching system code. Times are in seconds, distances in studs.
]]

local Config = {}

Config.Debug = {
	-- Prints timing information for the lava simulation and other systems.
	Verbose = false,
}

Config.Round = {
	Intermission = 30,
	-- Seconds left in the intermission at which the countdown starts ticking.
	CountdownFrom = 5,
	Results = 10,
	MinPlayers = 1,
	-- Phases run in order. `Name` is shown on the HUD, `Id` is what systems switch on.
	Phases = {
		{ Id = "Rumbling", Name = "Rumbling", Duration = 18 },
		{ Id = "Eruption", Name = "Eruption", Duration = 55 },
		{ Id = "Pyroclastic", Name = "Pyroclastic Flow", Duration = 22 },
		{ Id = "Aftermath", Name = "Aftermath", Duration = 15 },
	},
}

Config.Map = {
	Seed = 4515,
	-- Half-width of the generated terrain square.
	TerrainHalfSize = 512,
	BedrockDepth = 16,
	-- Gentle noise on the plains. Kept under one voxel so it never leaves holes.
	PlainsNoise = 1.4,
	VillageCenter = Vector3.new(232, 0, 0),
	VillageRadius = 44,
	HouseCount = 7,
	-- A second, wider ring of houses around the first. Every third one is brick.
	OuterHouseCount = 9,
	OuterRadius = 80,
	-- Concrete bunkers, as offsets from the village centre (the first sits just east of the square).
	Bunkers = { Vector3.new(64, 0, -26), Vector3.new(-6, 0, -104), Vector3.new(74, 0, 66) },
	TreeCount = 70,
	Pond = { Center = Vector3.new(232, 0, 118), Radius = 26, Depth = 7 },
	Lobby = { Position = Vector3.new(0, 34, -470), Size = Vector3.new(70, 2, 46) },
}

Config.Volcano = {
	Name = "Mount Ignis",
	Center = Vector3.new(0, 0, 0),
	BaseRadius = 160,
	Height = 104,
	-- Radius of the flat top before the crater is cut into it.
	SummitRadius = 36,
	CraterRadius = 27,
	CraterDepth = 16,
	-- Profile exponent. Higher = steeper summit, wider foot (stratovolcano shape).
	Profile = 1.7,
	-- A breach in the crater rim that steers the main lava flow toward the village (+X).
	Breach = { Angle = 0, Width = 0.5, Depth = 14, Slope = 0.55, ChannelDepth = 3, ChannelWidth = 0.2 },
	SurfaceNoise = 3,
}

Config.Tremor = {
	RumblingIntensity = { From = 0.15, To = 0.6 },
	EruptionIntensity = 0.75,
	PyroclasticIntensity = 0.55,
	PulseInterval = 0.5,
	PropJolt = 9, -- max velocity added to loose props per pulse at full intensity
	GlassCrackChance = 0.08,
	BoulderInterval = { Min = 1.0, Max = 2.4 },
	MaxBoulders = 14,
	BoulderSize = { Min = 3.5, Max = 7.5 },
	BoulderLifetime = 22,
	-- Fraction of boulders shaken loose on the flank facing the players instead of a random one.
	BoulderAimChance = 0.35,
	-- Boulders burst on every hard landing or bounce: a blast with falloff that hurts and throws
	-- people, but is capped well below a one-shot so it scares rather than kills outright.
	BoulderBlast = {
		ImpactSpeed = 28, -- sudden change in velocity that counts as a hard hit
		HitSpeed = 12, -- minimum speed for a direct hit on a player to burst
		Radius = 12, -- for the largest boulder; smaller ones shrink toward 70%
		Damage = 38, -- point blank, largest boulder, hardest hit
		Knockback = 55,
		Cooldown = 0.6, -- per boulder, so a bouncing rock thumps instead of buzzing
		PlayerCooldown = 1.5, -- the same boulder can't hurt the same player again within this
	},
}

Config.Lava = {
	-- Simulation grid, centred on the volcano.
	GridSize = 160, -- cells per side
	CellSize = 4,
	TickRate = 10, -- simulation steps per second
	Substeps = 3, -- flow iterations per step
	SendEvery = 2, -- steps between network updates

	-- Flow conductance per stud of depth, per step. Flux is also capped for stability, so this
	-- mostly controls how fast thin, cooling lava slows down.
	FlowRate = 0.12,
	-- Lava is a Bingham fluid: it only moves once the surface step exceeds its yield height.
	YieldHot = 0.18,
	YieldCold = 0.6,
	MinFlowDepth = 0.06,
	EdgeLimit = 0.125,
	MaxOutFraction = 0.35,
	Epsilon = 0.004,

	-- Temperature runs 1 (fresh) -> 0. It solidifies into basalt crust below SolidifyTemp.
	CoolRate = 0.012,
	SolidifyTemp = 0.14,
	AftermathCooling = 14,

	-- Vent output, in "depth units per second" (1 unit = one cell filled 1 stud deep).
	VentRate = 44,
	VentRadius = 9,
	FissureRate = 34,
	FissureRadius = 5,
	FissureDelay = 22,
	FissureDuration = 18,
	BombSplat = 3.5,

	-- Hazard thresholds.
	HarmfulTemp = 0.2,
	HarmfulDepth = 0.12,
	-- Touching molten lava: a short burst of hits, then the player is set on fire (see Config.Player).
	BurstHits = 3,
	BurstHitDamage = 8, -- per hit at full temperature (cooler lava does down to 60%)
	BurstHitInterval = 0.1,
	BurstCooldown = 1.25, -- still standing in it after this long? Another burst.
	WadeSpeed = 9,

	-- Network quantisation thresholds (centistuds / temperature bytes).
	SendDepthStep = 8,
	SendTempStep = 16,

	-- Client rendering.
	SlabThickness = 4,
	SlabOverlap = 1.32,
	MaxTilt = 1.15,
	LightEvery = 9,
	MaxLights = 70,
	Smoothing = 9,
}

Config.Bombs = {
	-- Bombs per second during each phase.
	Rate = { Eruption = 2.4, Pyroclastic = 0.8 },
	FlightTime = { Min = 3.2, Max = 5.6 },
	GravityScale = 0.55,
	TargetPlayerChance = 0.45,
	-- Fraction of the target's velocity to lead by, so standing still is dangerous but so is running in a line.
	LeadFactor = 0.55,
	Inaccuracy = 16,
	ScatterRadius = { Min = 55, Max = 290 },
	Size = { Min = 2.6, Max = 4.6 },
	BlastRadius = 13,
	Damage = 48,
	Knockback = 70,
	StructureDamage = 70,
	IgniteChance = 0.65,
	CraterRadius = 3.6,
	ScorchRadius = 9,
}

Config.Pyroclastic = {
	WarnTime = 4.5,
	Speed = 30,
	MaxRadius = 390,
	HalfAngle = math.rad(70),
	FrontWidth = 14,
	-- Out in the open the flow is fatal; only a proper building lets you live through it.
	Damage = 150,
	ShelteredDamage = 8,
	Knockback = 95,
	IgniteChance = 0.55,
	StructureDamage = 30,
	PropForce = 55,
	-- Shelter test (shared with the HUD so players see the same verdict the server uses).
	-- The wall probe is short so it only finds walls of the building you are standing in.
	ShelterProbe = 20,
	RoofProbe = 40,
}

Config.Fire = {
	TickInterval = 0.4,
	SpreadRadius = 6.5,
	SpreadHeat = 0.55,
	MaxBurning = 140,
	-- How readily each material catches. Anything missing does not burn.
	Flammability = {
		[Enum.Material.WoodPlanks] = 1.0,
		[Enum.Material.Wood] = 0.75,
		[Enum.Material.Grass] = 1.6,
		[Enum.Material.LeafyGrass] = 1.6,
		[Enum.Material.Fabric] = 1.8,
	},
	-- Seconds a typical 4-stud part burns before it is spent.
	Fuel = {
		[Enum.Material.WoodPlanks] = 16,
		[Enum.Material.Wood] = 22,
		[Enum.Material.Grass] = 7,
		[Enum.Material.LeafyGrass] = 7,
		[Enum.Material.Fabric] = 6,
	},
	CharColor = Color3.fromRGB(38, 30, 26),
	-- Standing next to flames: a poke of damage every interval, with a chance to catch fire.
	PlayerRadius = 5.5,
	PlayerTickDamage = 4,
	PlayerTickInterval = 0.6,
	PlayerIgniteChance = 0.25,
}

Config.Structures = {
	Health = {
		[Enum.Material.Glass] = 8,
		[Enum.Material.WoodPlanks] = 55,
		[Enum.Material.Wood] = 80,
		[Enum.Material.Grass] = 25,
		[Enum.Material.LeafyGrass] = 25,
		[Enum.Material.Fabric] = 15,
		[Enum.Material.Brick] = 160,
		[Enum.Material.Cobblestone] = 200,
		[Enum.Material.Slate] = 120,
	},
	DefaultHealth = 100,
	MaxDebris = 450,
	CascadeDelay = { Min = 0.04, Max = 0.35 },
}

Config.Player = {
	-- The burn meter (0..1). While it is up you are on fire. Molten lava fills it, and nothing
	-- but the lake empties it: it never cools down on its own.
	MeterFillTime = 4, -- seconds of continuous lava contact to reach MAX
	MeterDrainTime = 3, -- seconds for the lake to empty it, from whatever level it is at
	-- Other things that set you alight raise the meter to at least this level.
	IgniteMeter = { Blast = 0.2, Fire = 0.15, Pyroclastic = 0.5 },
	-- On fire: a poke of damage every interval, harder the fuller the meter.
	BurnTickInterval = 0.5,
	BurnTickDamage = { Min = 2, Max = 6 },
	HazardTick = 0.1,
}

Config.Colors = {
	Rumbling = Color3.fromRGB(255, 176, 74),
	Eruption = Color3.fromRGB(255, 72, 38),
	Pyroclastic = Color3.fromRGB(196, 186, 176),
	Aftermath = Color3.fromRGB(150, 200, 255),
	Intermission = Color3.fromRGB(235, 235, 235),
	Good = Color3.fromRGB(120, 230, 140),
	Bad = Color3.fromRGB(255, 90, 70),
}

-- Built-in engine sounds (rbxasset://) so the place works with no uploads. Swap freely.
Config.Sounds = {
	-- Both ship with every Roblox client (checked against the client's file manifest).
	Tick = "rbxasset://sounds/volume_slider.ogg",
	Whoosh = "rbxasset://sounds/action_falling.ogg",
}

-- Shared by the server (which registers them) and the client (which puts local effects in them).
Config.CollisionGroups = {
	Debris = "MountIgnisDebris",
	Players = "MountIgnisPlayers",
}

return Config
