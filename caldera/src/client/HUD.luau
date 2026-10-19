--[[
	HUD
	Phase banner and timer, announcements, the vertical heat (burn) meter, a red flash on every hit,
	the shelter check during the pyroclastic flow, a kill feed and the end-of-round survivors panel.
	Built entirely in code so the place needs no UI assets.

	Layout, top to bottom: status panel, shelter pill, announcement banner (text scales down to fit
	its box, so a long line can never spill over the others). The heat meter sits on the left edge.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Caldera")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Shelter = require(Shared.Shelter)

local HUD = {}

local player = Players.LocalPlayer
local C = Config.Colors

local PANEL = Color3.fromRGB(22, 18, 18)
local TEXT = Color3.fromRGB(245, 238, 230)
local MUTED = Color3.fromRGB(190, 178, 168)

type Props = { [string]: any }

local function create(className: string, props: Props, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	instance.Parent = props.Parent
	return instance
end

local function corner(radius: number): UICorner
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function phaseColor(): Color3
	local id = Net.GetState("PhaseId")
	if Net.GetState("RoundState") == "Disaster" and id and C[id] then
		return C[id]
	end
	return C.Intermission
end

--------------------------------------------------------------------------------------------

local gui: ScreenGui
local flashGui: ScreenGui
local phaseLabel: TextLabel
local infoLabel: TextLabel
local panelStroke: UIStroke
local banner: TextLabel
local bannerTextSize: UITextSizeConstraint
local toast: TextLabel
local meterFrame: Frame
local meterFill: Frame
local meterStroke: UIStroke
local meterMax: TextLabel
local meterHint: TextLabel
local shelterPill: TextLabel
local feed: Frame
local resultsPanel: Frame
local flashEdges: { Frame } = {}
local flashTweens: { Tween } = {}

local bannerToken = 0
local toastToken = 0

-- The banner starts below the status panel (8..74) and the shelter pill (82..116).
local BANNER_TOP = 126

local function build()
	gui = create("ScreenGui", {
		Name = "CalderaHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- Top status panel.
	local panel = create("Frame", {
		Name = "Status",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(360, 66),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.2,
		Parent = gui,
	}, { corner(12) })
	panelStroke = create("UIStroke", { Thickness = 2, Transparency = 0.3, Color = C.Intermission, Parent = panel })
	phaseLabel = create("TextLabel", {
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		TextSize = 26,
		TextColor3 = C.Intermission,
		Text = "CALDERA",
		Parent = panel,
	})
	infoLabel = create("TextLabel", {
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 16,
		TextColor3 = MUTED,
		Text = "",
		Parent = panel,
	})

	bannerTextSize = create("UITextSizeConstraint", { MaxTextSize = 30 })
	banner = create("TextLabel", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, BANNER_TOP),
		Size = UDim2.new(0.86, 0, 0, 48),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		TextWrapped = true,
		TextColor3 = TEXT,
		TextStrokeTransparency = 0.35,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextTransparency = 1,
		Text = "",
		Parent = gui,
	}, { bannerTextSize })

	toast = create("TextLabel", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.66),
		Size = UDim2.new(0.6, 0, 0, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 22,
		TextColor3 = TEXT,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		Text = "",
		Parent = gui,
	})

	-- Shelter verdict shown while a pyroclastic flow is coming.
	shelterPill = create("TextLabel", {
		Name = "Shelter",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 82),
		Size = UDim2.fromOffset(300, 34),
		BackgroundColor3 = C.Bad,
		BackgroundTransparency = 0.15,
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextColor3 = Color3.new(1, 1, 1),
		Text = "EXPOSED",
		Visible = false,
		Parent = gui,
	}, { corner(17) })

	-- Heat meter: a vertical gauge on the left edge that fills from the bottom. Hidden until you get
	-- burned; it only empties in the lake. The notches mark each second of lava contact.
	meterFrame = create("Frame", {
		Name = "HeatMeter",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 22, 0.5, 0),
		Size = UDim2.fromOffset(26, 260),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		Visible = false,
		Parent = gui,
	}, { corner(13) })
	meterStroke = create("UIStroke", {
		Thickness = 2,
		Color = Color3.fromRGB(255, 120, 50),
		Transparency = 0.35,
		Parent = meterFrame,
	})
	meterFill = create("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = meterFrame,
	}, {
		corner(13),
		-- Yellow at the bottom, red at the top.
		create("UIGradient", {
			Rotation = -90,
			Color = ColorSequence.new(Color3.fromRGB(255, 206, 80), Color3.fromRGB(255, 40, 20)),
		}),
	})
	for notch = 1, 3 do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 1 - notch / 4),
			Size = UDim2.new(1, -8, 0, 2),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			ZIndex = 2,
			Parent = meterFrame,
		})
	end
	create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 8),
		Size = UDim2.fromOffset(80, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		TextSize = 15,
		TextColor3 = Color3.fromRGB(255, 170, 90),
		TextStrokeTransparency = 0.5,
		Text = "HEAT",
		Parent = meterFrame,
	})
	meterMax = create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -6),
		Size = UDim2.fromOffset(80, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextColor3 = Color3.fromRGB(255, 60, 40),
		TextStrokeTransparency = 0.4,
		Text = "MAX",
		Visible = false,
		Parent = meterFrame,
	})
	meterHint = create("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(1, 12, 0.5, 0),
		Size = UDim2.fromOffset(180, 46),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(255, 140, 60),
		TextStrokeTransparency = 0.4,
		Text = "",
		Parent = meterFrame,
	})

	-- Kill feed, top right.
	feed = create("Frame", {
		Name = "Feed",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(320, 200),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		create("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 4),
		}),
	})

	resultsPanel = create("Frame", {
		Name = "Results",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(380, 300),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = gui,
	}, { corner(14), create("UIStroke", { Thickness = 2, Color = C.Rumbling, Transparency = 0.2 }) })

	-- Damage flash: red screen edges, drawn under the inset so they reach the very top of the screen.
	-- Fully transparent until a hit lands (see flashDamage). Each edge's own transparency is driven
	-- directly rather than through a CanvasGroup, so visibility never depends on group rendering.
	flashGui = create("ScreenGui", {
		Name = "CalderaDamageFlash",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = -1,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local edges = {
		{ UDim2.fromScale(1, 0.28), UDim2.fromScale(0, 0), 90 },
		{ UDim2.fromScale(1, 0.28), UDim2.fromScale(0, 0.72), -90 },
		{ UDim2.fromScale(0.2, 1), UDim2.fromScale(0, 0), 0 },
		{ UDim2.fromScale(0.2, 1), UDim2.fromScale(0.8, 0), 180 },
	}
	for _, edge in edges do
		table.insert(
			flashEdges,
			create("Frame", {
				Size = edge[1],
				Position = edge[2],
				BorderSizePixel = 0,
				BackgroundColor3 = Color3.fromRGB(220, 24, 16),
				BackgroundTransparency = 1,
				Parent = flashGui,
			}, {
				create("UIGradient", {
					Rotation = edge[3],
					Transparency = NumberSequence.new(0, 1),
				}),
			})
		)
	end
end

--------------------------------------------------------------------------------------------

local FLASH_FADE = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Snaps the edges red and fades them straight back out. A new hit restarts the flash, so a burst
-- of hits reads as a burst of flashes and nothing ever stays on screen.
local function flashDamage(strength: number)
	local opacity = math.clamp(strength, 0.25, 0.8)
	for i, edge in flashEdges do
		local running = flashTweens[i]
		if running then
			running:Cancel()
		end
		edge.BackgroundTransparency = 1 - opacity
		local tween = TweenService:Create(edge, FLASH_FADE, { BackgroundTransparency = 1 })
		flashTweens[i] = tween
		tween:Play()
	end
end

local function watchHealth(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	local last = humanoid.Health
	humanoid.HealthChanged:Connect(function(health)
		local lost = last - health
		last = health
		-- Only losses flash (not regeneration), and bigger hits flash harder.
		if lost > 0.5 then
			flashDamage(0.3 + 1.2 * math.min(lost / math.max(humanoid.MaxHealth, 1), 0.4))
		end
	end)
end

--------------------------------------------------------------------------------------------

local function fadeText(label: TextLabel, visible: boolean, duration: number)
	TweenService:Create(label, TweenInfo.new(duration), {
		TextTransparency = if visible then 0 else 1,
		TextStrokeTransparency = if visible then 0.35 else 1,
	}):Play()
end

local function announce(text: string, color: Color3?, duration: number?, style: string?)
	local hold = duration or 3
	if style == "small" then
		toastToken += 1
		local token = toastToken
		toast.Text = text
		toast.TextColor3 = color or TEXT
		fadeText(toast, true, 0.2)
		task.delay(hold, function()
			if token == toastToken then
				fadeText(toast, false, 0.5)
			end
		end)
		return
	end

	bannerToken += 1
	local token = bannerToken
	banner.Text = text
	banner.TextColor3 = color or TEXT
	bannerTextSize.MaxTextSize = if style == "big" then 44 else 30
	banner.Size = UDim2.new(0.86, 0, 0, if style == "big" then 60 else 48)
	fadeText(banner, true, 0.25)
	-- A quick punch-in for big alerts.
	if style == "big" then
		banner.Position = UDim2.new(0.5, 0, 0, BANNER_TOP - 14)
		TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back), {
			Position = UDim2.new(0.5, 0, 0, BANNER_TOP),
		}):Play()
	end
	task.delay(hold, function()
		if token == bannerToken then
			fadeText(banner, false, 0.6)
		end
	end)
end

local function escapeRichText(text: string): string
	return (string.gsub(text, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function addFeed(name: string, cause: string)
	local entry = create("TextLabel", {
		Size = UDim2.fromOffset(320, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.3,
		Font = Enum.Font.GothamMedium,
		TextSize = 15,
		TextColor3 = TEXT,
		RichText = true,
		Text = `  <b>{escapeRichText(name)}</b> was claimed by {escapeRichText(cause)}  `,
		LayoutOrder = -math.floor(os.clock() * 1000),
		Parent = feed,
	}, { corner(6) })
	local entries = {}
	for _, child in feed:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(entries, child)
		end
	end
	if #entries > 5 then
		table.sort(entries, function(a, b)
			return a.LayoutOrder > b.LayoutOrder
		end)
		entries[1]:Destroy()
	end
	task.delay(7, function()
		if entry.Parent then
			local tween =
				TweenService:Create(entry, TweenInfo.new(0.6), { TextTransparency = 1, BackgroundTransparency = 1 })
			tween:Play()
			tween.Completed:Wait()
			entry:Destroy()
		end
	end)
end

local function showResults(names: { string }, participants: number)
	for _, child in resultsPanel:GetChildren() do
		if child:IsA("TextLabel") or child:IsA("ScrollingFrame") then
			child:Destroy()
		end
	end
	create("TextLabel", {
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		TextSize = 28,
		TextColor3 = if #names > 0 then C.Good else C.Bad,
		Text = if #names > 0 then `SURVIVORS ({#names}/{participants})` else "NO SURVIVORS",
		Parent = resultsPanel,
	})
	local list = create("ScrollingFrame", {
		Position = UDim2.fromOffset(20, 60),
		Size = UDim2.new(1, -40, 1, -80),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = resultsPanel,
	}, { create("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center }) })
	if #names == 0 then
		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamMedium,
			TextSize = 18,
			TextColor3 = MUTED,
			Text = `{Config.Volcano.Name} claimed everyone.`,
			Parent = list,
		})
	end
	for _, name in names do
		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 20,
			TextColor3 = TEXT,
			Text = name,
			Parent = list,
		})
	end
	resultsPanel.Visible = true
	task.delay(Config.Round.Results - 0.5, function()
		resultsPanel.Visible = false
	end)
end

--------------------------------------------------------------------------------------------

local shelterParams = RaycastParams.new()
shelterParams.FilterType = Enum.RaycastFilterType.Include

local function updateStatus()
	local state = Net.GetState("RoundState") or "Waiting"
	local phaseName = Net.GetState("Phase") or ""
	local endsAt = Net.GetState("PhaseEndsAt") or 0
	local remaining = endsAt - workspace:GetServerTimeNow()
	local color = phaseColor()

	phaseLabel.TextColor3 = color
	panelStroke.Color = color

	if state == "Intermission" then
		phaseLabel.Text = "INTERMISSION"
		infoLabel.Text = `Eruption in {formatTime(remaining)}`
	elseif state == "Disaster" then
		phaseLabel.Text = string.upper(phaseName)
		local alive = Net.GetState("Alive") or 0
		local total = Net.GetState("Participants") or 0
		local you = if player:GetAttribute("InRound") then "" else " · spectating"
		infoLabel.Text = `{formatTime(remaining)} · {alive}/{total} surviving{you}`
	elseif state == "Results" then
		phaseLabel.Text = "ERUPTION OVER"
		infoLabel.Text = `Next round in {formatTime(remaining)}`
	elseif state == "Resetting" then
		phaseLabel.Text = "REBUILDING"
		infoLabel.Text = "Emberfall is being rebuilt..."
	else
		phaseLabel.Text = "CALDERA"
		infoLabel.Text = "Waiting for players"
	end
end

local function updateShelter()
	local showing = Net.GetState("PhaseId") == "Pyroclastic" and Net.GetState("RoundState") == "Disaster"
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not showing or not root or not player:GetAttribute("InRound") then
		shelterPill.Visible = false
		return
	end
	-- Same rule as the server: only buildings can shelter you.
	local caldera = workspace:FindFirstChild("Caldera")
	local structures = caldera and caldera:FindFirstChild("Structures")
	shelterParams.FilterDescendantsInstances = if structures then { structures } else {}
	local volcano = Config.Volcano.Center + Vector3.new(0, Config.Volcano.Height, 0)
	local sheltered = Shelter.Evaluate(root.Position, volcano, shelterParams)
	shelterPill.Visible = true
	shelterPill.Text = if sheltered then "SHELTERED ✓" else "EXPOSED: get inside a house or the bunker!"
	shelterPill.BackgroundColor3 = if sheltered then Color3.fromRGB(46, 150, 80) else C.Bad
	shelterPill.Size = UDim2.fromOffset(if sheltered then 200 else 400, 34)
end

function HUD.Start()
	build()

	Net.Event("Announce").OnClientEvent:Connect(announce)
	Net.Event("KillFeed").OnClientEvent:Connect(addFeed)
	Net.Event("Results").OnClientEvent:Connect(showResults)

	player.CharacterAdded:Connect(watchHealth)
	if player.Character then
		task.spawn(watchHealth, player.Character)
	end

	local shown = 0
	local statusTimer, shelterTimer = 0, 0
	RunService.RenderStepped:Connect(function(dt)
		statusTimer += dt
		if statusTimer > 0.2 then
			statusTimer = 0
			updateStatus()
		end
		shelterTimer += dt
		if shelterTimer > 0.2 then
			shelterTimer = 0
			updateShelter()
		end

		-- Heat meter: eases toward the server's value; visible from the first burn until the lake
		-- has emptied it.
		local target = player:GetAttribute("BurnMeter") or 0
		shown += (target - shown) * math.min(1, dt * 12)
		if target <= 0 and shown < 0.004 then
			shown = 0
		end
		local burning = player:GetAttribute("Burning") == true
		meterFrame.Visible = shown > 0 or burning
		meterFill.Size = UDim2.fromScale(1, math.clamp(shown, 0, 1))
		local full = target >= 1
		meterMax.Visible = full
		if full then
			meterMax.TextTransparency = 0.25 + 0.25 * math.sin(os.clock() * 10)
		end
		meterHint.Text = if burning then "ON FIRE!\nGet to the lake!" else "Cooling off..."
		meterHint.TextColor3 = if burning then Color3.fromRGB(255, 140, 60) else Color3.fromRGB(140, 200, 255)
		meterStroke.Color = if burning then Color3.fromRGB(255, 120, 50) else Color3.fromRGB(120, 190, 255)
	end)
end

return HUD
