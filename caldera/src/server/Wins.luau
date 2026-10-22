--[[
	Wins
	A win is surviving a round. All-time wins are a SavedCounter (saved globally, ranked by the
	"Most Wins" board in the lobby) and are shown in the player list through leaderstats.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local SavedCounter = require(script.Parent.SavedCounter)

local Wins = {}

Wins.Counter = (nil :: any) :: SavedCounter.SavedCounter

local values: { [Player]: IntValue } = {}
local announceEvent = Net.Event("Announce")

local function onPlayerAdded(player: Player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local value = Instance.new("IntValue")
	value.Name = "Wins"
	value.Value = Wins.Counter:Get(player)
	value.Parent = leaderstats
	values[player] = value
	leaderstats.Parent = player
end

function Wins.Award(player: Player)
	Wins.Counter:Add(player, 1)
	announceEvent:FireClient(player, "+1 Win!", Config.Colors.Good, 3, "small")
end

function Wins.Init()
	Wins.Counter = SavedCounter.new("Wins", Config.Leaderboards.Wins.StoreName)
	Wins.Counter.Changed:Connect(function(player: Player, total: number)
		local value = values[player]
		if value then
			value.Value = total
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		values[player] = nil
	end)
end

return Wins
