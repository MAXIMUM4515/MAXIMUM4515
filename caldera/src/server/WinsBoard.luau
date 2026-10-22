--[[
	WinsBoard
	The "Most Wins" board in the lobby, beside the spawn. It shows the top players of all time,
	re-read from the global wins store every RefreshInterval seconds (5 minutes), with a countdown
	to the next refresh. Without DataStore access it ranks the players in this server instead and
	says so.

	The SurfaceGui is built and updated here on the server; it replicates to every client like any
	other part of the lobby.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Wins = require(script.Parent.Wins)

local LB = Config.Leaderboard

local PANEL = Color3.fromRGB(22, 18, 18)
local TEXT = Color3.fromRGB(245, 238, 230)
local MUTED = Color3.fromRGB(190, 178, 168)
local ACCENT = Color3.fromRGB(255, 176, 74)
local MEDALS = { Color3.fromRGB(255, 205, 70), Color3.fromRGB(205, 212, 222), Color3.fromRGB(214, 140, 86) }

local PIXELS_PER_STUD = 50
local TEXT_SCALE = 0.78 -- of a row's height

local WinsBoard = {}

type Entry = { UserId: number, Wins: number }
type Row = { Frame: Frame, Rank: TextLabel, Name: TextLabel, Wins: TextLabel }

local rows: { Row } = {}
local subtitle: TextLabel
local emptyLabel: TextLabel
local names: { [number]: string } = {}

local function label(props: { [string]: any }): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = TEXT
	text.TextScaled = true
	for key, value in props do
		(text :: any)[key] = value
	end
	return text
end

local function build(board: BasePart)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "WinsBoard"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	gui.LightInfluence = 0
	gui.MaxDistance = 250

	local background = Instance.new("Frame")
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = PANEL
	background.BorderSizePixel = 0
	background.Parent = gui

	local width, height = board.Size.X * PIXELS_PER_STUD, board.Size.Y * PIXELS_PER_STUD
	local headerHeight = 96
	label({
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, 0, 0, 52),
		Font = Enum.Font.GothamBlack,
		TextColor3 = ACCENT,
		Text = "MOST WINS",
		Parent = background,
	})
	subtitle = label({
		Position = UDim2.fromOffset(0, 64),
		Size = UDim2.new(1, 0, 0, 22),
		Font = Enum.Font.GothamMedium,
		TextColor3 = MUTED,
		Text = "",
		Parent = background,
	})

	local rowHeight = math.floor((height - headerHeight - 14) / LB.Size)
	for index = 1, LB.Size do
		local frame = Instance.new("Frame")
		frame.Position = UDim2.fromOffset(24, headerHeight + (index - 1) * rowHeight)
		frame.Size = UDim2.fromOffset(width - 48, rowHeight - 4)
		frame.BackgroundColor3 = Color3.new(1, 1, 1)
		frame.BackgroundTransparency = if index % 2 == 1 then 0.94 else 1
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = background
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = frame

		local row: Row = {
			Frame = frame,
			Rank = label({
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 10, 0.5, 0),
				Size = UDim2.new(0, 64, TEXT_SCALE, 0),
				Font = Enum.Font.GothamBlack,
				TextColor3 = MEDALS[index] or MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = `#{index}`,
				Parent = frame,
			}),
			Name = label({
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 84, 0.5, 0),
				Size = UDim2.new(1, -84 - 120, TEXT_SCALE, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = "",
				Parent = frame,
			}),
			Wins = label({
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.new(0, 110, TEXT_SCALE, 0),
				Font = Enum.Font.GothamBlack,
				TextColor3 = ACCENT,
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = "",
				Parent = frame,
			}),
		}
		rows[index] = row
	end

	emptyLabel = label({
		Position = UDim2.fromOffset(24, headerHeight + 20),
		Size = UDim2.new(1, -48, 0, 34),
		Font = Enum.Font.GothamMedium,
		TextColor3 = MUTED,
		Text = "No wins yet. Survive a round to get on the board!",
		Visible = false,
		Parent = background,
	})

	gui.Parent = board
end

--------------------------------------------------------------------------------------------

-- Display names for the listed players: from the server for anyone here, otherwise looked up in
-- one batch (and remembered).
local function resolveNames(entries: { Entry })
	local missing = {}
	for _, entry in entries do
		local player = Players:GetPlayerByUserId(entry.UserId)
		if player then
			names[entry.UserId] = player.DisplayName
		elseif names[entry.UserId] == nil and entry.UserId > 0 then
			table.insert(missing, entry.UserId)
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok then
		for _, info in infos do
			names[info.Id] = info.DisplayName
		end
	else
		for _, userId in missing do
			local found, name = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if found then
				names[userId] = name
			end
		end
	end
end

-- The global top list, or nil if the store can't be read right now.
local function globalTop(): { Entry }?
	local store = Wins.Store()
	if not store then
		return nil
	end
	local ok, page = pcall(function()
		return store:GetSortedAsync(false, LB.Size):GetCurrentPage()
	end)
	if not ok then
		warn("[WinsBoard] could not read the top list:", page)
		return nil
	end
	local entries = {}
	for _, item in page do
		local userId, wins = tonumber(item.key), tonumber(item.value)
		if userId and wins and wins > 0 then
			table.insert(entries, { UserId = userId, Wins = wins })
		end
	end
	return entries
end

local function serverTop(): { Entry }
	local entries = {}
	for _, player in Players:GetPlayers() do
		local wins = Wins.Get(player)
		if wins > 0 then
			table.insert(entries, { UserId = player.UserId, Wins = wins })
		end
	end
	table.sort(entries, function(a, b)
		if a.Wins ~= b.Wins then
			return a.Wins > b.Wins
		end
		return a.UserId < b.UserId
	end)
	while #entries > LB.Size do
		table.remove(entries)
	end
	return entries
end

local function render(entries: { Entry })
	for index, row in rows do
		local entry = entries[index]
		row.Frame.Visible = entry ~= nil
		if entry then
			row.Name.Text = names[entry.UserId] or "Unknown player"
			row.Wins.Text = if entry.Wins == 1 then "1 win" else `{entry.Wins} wins`
		end
	end
	emptyLabel.Visible = #entries == 0
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- Re-reads the list. Returns the scope line shown under the title.
local function refresh(): string
	local global = globalTop()
	local entries = global or serverTop()
	local scope = if global then "ALL-TIME, ALL SERVERS" else "THIS SERVER (GLOBAL BOARD OFFLINE)"
	resolveNames(entries)
	render(entries)
	return scope
end

function WinsBoard.Init(board: BasePart)
	build(board)
	task.spawn(function()
		while true do
			local ok, scope = pcall(refresh)
			if not ok then
				warn("[WinsBoard]", scope)
				scope = "ALL-TIME"
			end
			local nextRefresh = os.clock() + LB.RefreshInterval
			while os.clock() < nextRefresh do
				subtitle.Text = `{scope} · UPDATES IN {formatTime(nextRefresh - os.clock())}`
				task.wait(1)
			end
		end
	end)
end

return WinsBoard
