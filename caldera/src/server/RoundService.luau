--[[
	RoundService
	The game loop: intermission -> eruption phases -> results -> rebuild.

	Round state is published as attributes on the replicated state folder:
		RoundState    "Waiting" | "Intermission" | "Disaster" | "Results" | "Resetting"
		Phase         display name of the current phase
		PhaseId       id of the current eruption phase
		PhaseEndsAt   server time (workspace:GetServerTimeNow()) when the phase ends
		Alive / Participants   survivor counts
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Combustion = require(script.Parent.Combustion)
local Hazards = require(script.Parent.Hazards)
local LavaFlow = require(script.Parent.LavaFlow)
local MapBuilder = require(script.Parent.MapBuilder)
local Pyroclastic = require(script.Parent.Pyroclastic)
local Structures = require(script.Parent.Structures)
local Tremors = require(script.Parent.Tremors)
local Volcano = require(script.Parent.Volcano)

local R = Config.Round

local RoundService = {}

local participants: { [Player]: boolean } = {}
local survivors: { [Player]: boolean } = {}
local forceStart = false
local rng = Random.new()

local resultsEvent = Net.Event("Results")
local announceEvent = Net.Event("Announce")

local function count(set: { [Player]: boolean }): number
	local n = 0
	for _ in set do
		n += 1
	end
	return n
end

local function publishCounts()
	Net.SetState("Alive", count(survivors))
	Net.SetState("Participants", count(participants))
end

local function setState(state: string, phaseName: string)
	Net.SetState("RoundState", state)
	Net.SetState("Phase", phaseName)
end

-- Waits `seconds`, publishing the end time. Returns false if `abort` fired first.
local function countdown(seconds: number, abort: (() -> boolean)?): boolean
	local endsAt = workspace:GetServerTimeNow() + seconds
	Net.SetState("PhaseEndsAt", endsAt)
	while workspace:GetServerTimeNow() < endsAt do
		if abort and abort() then
			return false
		end
		task.wait(0.25)
	end
	return true
end

local function enoughPlayers(): boolean
	return #Players:GetPlayers() >= R.MinPlayers
end

local function intermission()
	local length = if RunService:IsStudio() then Config.Debug.StudioIntermission else R.Intermission
	while true do
		if not enoughPlayers() then
			setState("Waiting", "Waiting for players")
			repeat
				task.wait(1)
			until enoughPlayers()
		end
		setState("Intermission", "Intermission")
		forceStart = false
		countdown(length, function()
			return forceStart or not enoughPlayers()
		end)
		if enoughPlayers() then
			return
		end
	end
end

local function playRound()
	table.clear(participants)
	table.clear(survivors)

	local spawns = MapBuilder.VillageSpawns
	local slot = rng:NextInteger(1, #spawns)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and humanoid and humanoid.Health > 0 then
			participants[player] = true
			survivors[player] = true
			player:SetAttribute("InRound", true)
			slot = slot % #spawns + 1
			character:PivotTo(CFrame.new(spawns[slot]) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))
		end
	end
	publishCounts()
	announceEvent:FireAllClients("Welcome to Emberfall. Survive the eruption!", Config.Colors.Intermission, 3, "normal")

	for _, phase in R.Phases do
		setState("Disaster", phase.Name)
		Net.SetState("PhaseId", phase.Id)
		Volcano.EnterPhase(phase.Id, phase.Duration)
		local finished = countdown(phase.Duration, function()
			return next(survivors) == nil
		end)
		if not finished then
			break
		end
	end

	Volcano.EndRound()
	Net.SetState("PhaseId", "")
end

local function results()
	local names = {}
	for player in survivors do
		if player.Parent then
			table.insert(names, player.DisplayName)
		end
	end
	table.sort(names)
	resultsEvent:FireAllClients(names, count(participants))
	setState("Results", "Results")
	countdown(R.Results)
	for player in participants do
		if player.Parent then
			player:SetAttribute("InRound", nil)
		end
	end
	table.clear(participants)
	table.clear(survivors)
	publishCounts()
end

local function resetMap()
	setState("Resetting", "Rebuilding Emberfall")
	Net.SetState("PhaseEndsAt", 0)

	-- Get everyone out before the village is torn down and rebuilt under them.
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			character:PivotTo(MapBuilder.LobbySpawn)
		end
	end

	Pyroclastic.Stop()
	LavaFlow.Reset()
	Combustion.Reset()
	Structures.Reset()
	Tremors.Reset()
	Hazards.Reset()

	MapBuilder.Reset()
	Structures.RegisterAll()
	Combustion.RegisterAll()
	LavaFlow.RebuildGround()
end

local function onChat(player: Player, message: string)
	-- Testing shortcut for the place owner (or anyone in Studio).
	if string.lower(message) == "!erupt" and (RunService:IsStudio() or player.UserId == game.CreatorId) then
		forceStart = true
	end
end

function RoundService.Init()
	Players.RespawnTime = 4

	Hazards.PlayerKilled:Connect(function(player)
		if survivors[player] then
			survivors[player] = nil
			-- They respawn in the lobby as a spectator; bombs must stop hunting them.
			player:SetAttribute("InRound", nil)
			publishCounts()
		end
	end)

	local function onPlayer(player: Player)
		player.Chatted:Connect(function(message)
			onChat(player, message)
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		participants[player] = nil
		survivors[player] = nil
		publishCounts()
	end)

	publishCounts()
end

function RoundService.Run()
	while true do
		local ok, err = pcall(function()
			intermission()
			playRound()
			results()
		end)
		if not ok then
			warn("[RoundService] round failed:", err)
			Volcano.EndRound()
		end
		resetMap()
	end
end

return RoundService
