--[[
	Config
	Every tunable number for the Caldera disaster lives here so the eruption can be
	rebalanced without touching system code. Times are in seconds, distances in studs.
]]

local Config = {}

Config.Debug = {
	-- Shorter intermission while testing in Studio.
	StudioIntermission = 8,
	-- Prints timing information for the lava simulation and other systems.
	Verbose = false,
}

Config.Round = {
	Intermission = 25,
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
	BoulderDamageSpeed = 16, -- minimum impact speed before a boulder hurts anything
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
	DamagePerSecond = 42,
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
	Damage = 75,
	ShelteredDamage = 8,
	Knockback = 95,
	IgniteChance = 0.55,
	StructureDamage = 30,
	PropForce = 55,
	-- Shelter test (shared with the HUD so players see the same verdict the server uses).
	ShelterProbe = 28,
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
	PlayerRadius = 5.5,
	PlayerDamagePerSecond = 9,
	PlayerIgniteChance = 0.12,
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
	BurnDuration = 4,
	BurnDamagePerSecond = 7,
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
	Whoosh = "rbxasset://sounds/Rocket whoosh 01.wav",
	Glass = "rbxasset://sounds/glassbreak.wav",
}

return Config
