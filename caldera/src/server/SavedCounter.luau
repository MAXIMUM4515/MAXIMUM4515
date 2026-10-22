--[[
	SavedCounter
	A per-player number that only ever goes up (wins, Robux spent), saved globally in an
	OrderedDataStore keyed by UserId so a lobby board can rank everyone who ever played.

	Totals are saved as increments and never overwritten, so a failed load can't wipe anyone: until
	a load or save returns the real total, the player's value is what they earned in this session.
	Unsaved amounts are retried on the next Add, when the player leaves and when the server shuts
	down.

	Without DataStore access (an unpublished place, or Studio without API access) the counter still
	works for the session; Store() returns nil and boards fall back to the players in the server.
	Studio saves into separate "_Studio" stores, so testing never touches the live boards.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Signal = require(Shared.Signal)

local ATTEMPTS = 3

local SavedCounter = {}
SavedCounter.__index = SavedCounter

export type SavedCounter = typeof(setmetatable(
	{} :: {
		Name: string,
		-- (player, total) whenever the value shown for a player in this server changes.
		Changed: typeof(Signal.new()),
		_store: OrderedDataStore?,
		_stored: { [number]: number }, -- the total last read from or written to the store, by UserId
		_pending: { [number]: number }, -- amounts not saved yet
		_session: { [number]: number }, -- earned in this server
		_saving: { [number]: boolean },
		_present: { [number]: boolean },
	},
	SavedCounter
))

local function openStore(name: string, storeName: string): OrderedDataStore?
	-- An unpublished place has no DataStores at all.
	if game.GameId ~= 0 then
		if RunService:IsStudio() then
			storeName ..= "_Studio"
		end
		local ok, result = pcall(function()
			return DataStoreService:GetOrderedDataStore(storeName)
		end)
		if ok then
			return result
		end
		warn(`[{name}] DataStores unavailable:`, result)
	end
	warn(`[{name}] not saved here, and its board shows this server only (publish the place and enable API access).`)
	return nil
end

function SavedCounter.new(name: string, storeName: string): SavedCounter
	local self = setmetatable({
		Name = name,
		Changed = Signal.new(),
		_store = openStore(name, storeName),
		_stored = {},
		_pending = {},
		_session = {},
		_saving = {},
		_present = {},
	}, SavedCounter)

	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end)
	game:BindToClose(function()
		self:_flush(20)
	end)
	return self
end

function SavedCounter._total(self: SavedCounter, userId: number): number
	local known = self._stored[userId]
	if known then
		return known + (self._pending[userId] or 0)
	end
	return self._session[userId] or 0
end

function SavedCounter._show(self: SavedCounter, userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		self.Changed:Fire(player, self:_total(userId))
	end
end

-- Writes a player's unsaved amount. One save per player at a time: amounts that arrive while it
-- waits are picked up by the same loop.
function SavedCounter._save(self: SavedCounter, userId: number)
	local store = self._store
	if not store or self._saving[userId] then
		return
	end
	self._saving[userId] = true
	local failures = 0
	while (self._pending[userId] or 0) > 0 and failures < ATTEMPTS do
		local amount = self._pending[userId]
		local ok, result = pcall(function()
			return (store:IncrementAsync(tostring(userId), amount))
		end)
		if ok then
			local left = (self._pending[userId] or 0) - amount
			self._pending[userId] = if left > 0 then left else nil
			self._stored[userId] = result
			self:_show(userId)
		else
			failures += 1
			warn(`[{self.Name}] could not save {amount} for {userId}:`, result)
			task.wait(2 ^ failures)
		end
	end
	self._saving[userId] = nil
end

function SavedCounter._load(self: SavedCounter, player: Player)
	local store = self._store :: OrderedDataStore
	local userId = player.UserId
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(function()
			return (store:GetAsync(tostring(userId)))
		end)
		if ok then
			-- A save that finished first already knows the real total.
			if self._stored[userId] == nil then
				self._stored[userId] = tonumber(result) or 0
			end
			self:_show(userId)
			return
		end
		warn(`[{self.Name}] could not load {player.Name}:`, result)
		if not self._present[userId] then
			return
		end
		task.wait(2 ^ attempt)
	end
end

function SavedCounter._onPlayerAdded(self: SavedCounter, player: Player)
	local userId = player.UserId
	self._present[userId] = true
	if self._store and self._stored[userId] == nil then
		task.spawn(self._load, self, player)
	end
end

function SavedCounter._onPlayerRemoving(self: SavedCounter, player: Player)
	local userId = player.UserId
	self._present[userId] = nil
	self:_save(userId)
	-- Unsaved amounts stay for the shutdown flush. Otherwise forget the player so a later rejoin
	-- reloads their total, unless they are already back.
	if self._pending[userId] == nil and not self._saving[userId] and not self._present[userId] then
		self._stored[userId] = nil
		self._session[userId] = nil
	end
end

function SavedCounter._flush(self: SavedCounter, timeout: number)
	local userIds = {}
	for userId in self._pending do
		table.insert(userIds, userId)
	end
	for _, userId in userIds do
		task.spawn(self._save, self, userId)
	end
	local deadline = os.clock() + timeout
	while next(self._saving) ~= nil and os.clock() < deadline do
		task.wait(0.25)
	end
end

-- The player's total as this server knows it.
function SavedCounter.Get(self: SavedCounter, player: Player): number
	return self:_total(player.UserId)
end

-- Adds a whole, positive amount to the player's total and saves it.
function SavedCounter.Add(self: SavedCounter, player: Player, amount: number)
	amount = math.floor(amount)
	if amount <= 0 then
		return
	end
	local userId = player.UserId
	self._session[userId] = (self._session[userId] or 0) + amount
	if self._store then
		self._pending[userId] = (self._pending[userId] or 0) + amount
		task.spawn(self._save, self, userId)
	end
	self:_show(userId)
end

-- The global store boards rank, or nil when DataStores are not available here.
function SavedCounter.Store(self: SavedCounter): OrderedDataStore?
	return self._store
end

return SavedCounter
