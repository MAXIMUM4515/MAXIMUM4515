--[[
	Mount Ignis - server bootstrap.
	Builds the map, starts every system in dependency order, wires the cross-system events,
	then hands control to the round loop.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
require(Shared.Net) -- creates the remotes and state folder before any client asks for them

local MapBuilder = require(script.MapBuilder)
local Structures = require(script.Structures)
local Combustion = require(script.Combustion)
local LavaFlow = require(script.LavaFlow)
local Hazards = require(script.Hazards)
local LavaBombs = require(script.LavaBombs)
local Tremors = require(script.Tremors)
local Pyroclastic = require(script.Pyroclastic)
local Volcano = require(script.Volcano)
local RoundService = require(script.RoundService)

local started = os.clock()

MapBuilder.Build()
local folders = MapBuilder.Folders

Structures.Init(folders)
Combustion.Init(folders)
Hazards.Init()
LavaFlow.Init({ workspace.Terrain, folders.Structures })
LavaBombs.Init(folders)
Tremors.Init(folders)
Pyroclastic.Init(folders)
Volcano.Init()
RoundService.Init()

Structures.RegisterAll()
Combustion.RegisterAll()
LavaFlow.RebuildGround()

-- When a building falls, the lava can see the ground it was standing on.
local pendingRefresh: { Vector3 } = {}
Structures.Collapsed:Connect(function(_part, position)
	table.insert(pendingRefresh, position)
	if #pendingRefresh == 1 then
		task.delay(0.5, function()
			for _, point in pendingRefresh do
				LavaFlow.RefreshGround(point, 6)
			end
			table.clear(pendingRefresh)
		end)
	end
end)

-- Molten lava sets fire to whatever it presses against.
LavaFlow.Scorching:Connect(function(cframe, size)
	Combustion.HeatBox(cframe, size, 1.4)
end)

if Config.Debug.Verbose then
	print(`[Mount Ignis] ready in {math.floor((os.clock() - started) * 1000)} ms`)
end

RoundService.Run()
