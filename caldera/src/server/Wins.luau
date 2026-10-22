--[[
	Wins
	A win is surviving a round. Every player's all-time total lives in one OrderedDataStore (key:
	UserId), which is also what the lobby board ranks, and is shown in the player list through
	leaderstats.

	Wins are saved as increments and never overwritten, so a failed load can't wipe anyone's total:
	the player list shows this session's wins until a load or save returns the real one. Unsaved
	wins are retried on the next win, when the player leaves and when the server shuts down.

	Without DataStore access (an unpublished place, or Studio without API access) wins still count
	for the session, and the board ranks the players in this server instead.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local LB = Config.Leaderboard

local ATTEMPTS = 3

local Wins = {}

local store: OrderedDataStore? = nil
local stored: { [number]: number } = {} -- the total last read from or written to the store, by UserId
local pending: { [number]: number } = {} -- wins not saved yet
local session: { [number]: number } = {} -- wins earned in this server
local saving: { [number]: boolean } = {}
local present: { [number]: boolean } = {}
local values: { [Player]: IntValue } = {}

local announceEvent = Net.Event("Announce")

local function total(userId: number): number
	local known = stored[userId]
	if known then
		return known + (pending[userId] or 0)
	end
	return session[userId] or 0
end

local function show(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	local value = player and values[player]
	if value then
		value.Value = total(userId)
	end
end

-- Writes a player's unsaved wins. One save per player at a time: wins that arrive while it waits
-- are picked up by the same loop.
local function save(userId: number)
	local dataStore = store
	if not dataStore or saving[userId] then
		return
	end
	saving[userId] = true
	local failures = 0
	while (pending[userId] or 0) > 0 and failures < ATTEMPTS do
		local amount = pending[userId]
		local ok, result = pcall(function()
			return (dataStore:IncrementAsync(tostring(userId), amount))
		end)
		if ok then
			local left = (pending[userId] or 0) - amount
			pending[userId] = if left > 0 then left else nil
			stored[userId] = result
			show(userId)
		else
			failures += 1
			warn(`[Wins] could not save {amount} win(s) for {userId}:`, result)
			task.wait(2 ^ failures)
		end
	end
	saving[userId] = nil
end

local function load(player: Player)
	local dataStore = store :: OrderedDataStore
	local userId = player.UserId
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(function()
			return (dataStore:GetAsync(tostring(userId)))
		end)
		if ok then
			-- A save that finished first already knows the real total.
			if stored[userId] == nil then
				stored[userId] = tonumber(result) or 0
			end
			show(userId)
			return
		end
		warn(`[Wins] could not load wins for {player.Name}:`, result)
		if not present[userId] then
			return
		end
		task.wait(2 ^ attempt)
	end
end

local function onPlayerAdded(player: Player)
	present[player.UserId] = true
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local value = Instance.new("IntValue")
	value.Name = "Wins"
	value.Value = total(player.UserId)
	value.Parent = leaderstats
	values[player] = value
	leaderstats.Parent = player
	if store and stored[player.UserId] == nil then
		task.spawn(load, player)
	end
end

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	values[player] = nil
	present[userId] = nil
	save(userId)
	-- Unsaved wins stay for the shutdown flush. Otherwise forget the player so a later rejoin
	-- reloads their total, unless they are already back.
	if pending[userId] == nil and not saving[userId] and not present[userId] then
		stored[userId] = nil
		session[userId] = nil
	end
end

-- Total wins shown for a player in this server.
function Wins.Get(player: Player): number
	return total(player.UserId)
end

-- The global wins store, or nil when DataStores are not available here.
function Wins.Store(): OrderedDataStore?
	return store
end

function Wins.Award(player: Player)
	local userId = player.UserId
	session[userId] = (session[userId] or 0) + 1
	if store then
		pending[userId] = (pending[userId] or 0) + 1
		task.spawn(save, userId)
	end
	show(userId)
	announceEvent:FireClient(player, "+1 Win!", Config.Colors.Good, 3, "small")
end

function Wins.Init()
	-- An unpublished place has no DataStores at all.
	if game.GameId ~= 0 then
		local ok, result = pcall(function()
			return DataStoreService:GetOrderedDataStore(LB.StoreName)
		end)
		if ok then
			store = result
		else
			warn("[Wins] DataStores unavailable:", result)
		end
	end
	if not store then
		warn(
			"[Wins] wins are not saved here and the board shows this server only (publish the place and enable API access)."
		)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	game:BindToClose(function()
		local userIds = {}
		for userId in pending do
			table.insert(userIds, userId)
		end
		for _, userId in userIds do
			task.spawn(save, userId)
		end
		local deadline = os.clock() + 20
		while next(saving) ~= nil and os.clock() < deadline do
			task.wait(0.25)
		end
	end)
end

return Wins
