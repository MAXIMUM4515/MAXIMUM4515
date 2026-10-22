--[[
	GuidePopup
	A "how to play" card shown when a player joins: what the game is about and how to get through
	each phase of the eruption. Pressing "Okay!" closes it. Phase names and lengths come straight
	from Config, so the card never drifts out of date.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local UiKit = require(script.Parent.UiKit)

local create = UiKit.create
local corner = UiKit.corner

local GuidePopup = {}

local INTRO =
	`{Config.Volcano.Name} is waking up above the village of Emberfall. Every round it erupts in four phases. Survive all of them to win the round.`

local PHASE_TIPS = {
	Rumbling = "Tremors shake the ground and boulders break off the summit, bursting where they land. Keep off the volcano's slopes and watch for rolling rocks.",
	Eruption = "Lava bombs rain down: a red ring marks each landing spot, so step out of it. Molten lava pours toward the village. It burns you, slows you and fills your HEAT meter. Burning houses spread fire to their neighbours.",
	Pyroclastic = "A deadly cloud of ash sweeps down the mountain. Get inside a house or a concrete bunker, behind a wall that faces the volcano. Out in the open you won't survive. Watch the SHELTERED / EXPOSED sign.",
	Aftermath = "The eruption fades and the lava hardens into black rock you can walk on. Glowing rock still burns. Hold on until the timer runs out.",
}

local TIPS = {
	"Your HEAT meter (left side of the screen) fills while you touch lava, and you keep burning until it is empty. Only the lake cools you down, or a fire extinguisher if you have one.",
	"Surviving a round is a win. The boards in the lobby show who has the most wins and who has spent the most Robux.",
	"Brick houses and concrete bunkers don't burn, so they make the safest shelters.",
	"Cooled black crust is safe to walk on.",
	"If you die, you watch the rest of the round from the lobby.",
}

local CARD = Color3.fromRGB(38, 31, 29)

local function paragraph(text: string, size: number, color: Color3, font: Enum.Font?): TextLabel
	return create("TextLabel", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = font or Enum.Font.GothamMedium,
		TextSize = size,
		TextColor3 = color,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
	})
end

-- A rounded card with a coloured strip down its left edge, holding a title and a body.
local function card(title: string, body: string, color: Color3): Frame
	local content = create("Frame", {
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -28, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
		create("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }),
	})
	local heading = paragraph(title, 18, color, Enum.Font.GothamBlack)
	heading.LayoutOrder = 1
	heading.Parent = content
	local text = paragraph(body, 15, UiKit.Text)
	text.LayoutOrder = 2
	text.Parent = content

	return create("Frame", {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = CARD,
	}, {
		corner(10),
		create("Frame", {
			Size = UDim2.new(0, 4, 1, 0),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		}, { corner(2) }),
		content,
	})
end

function GuidePopup.Show()
	local gui = create("ScreenGui", {
		Name = "MountIgnisGuide",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 20,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	-- Active so clicks on the dimmed world behind the card don't go through.
	local backdrop = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Active = true,
		Parent = gui,
	})
	local scale = create("UIScale", { Scale = 0.9 })
	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.92, 0.88),
		BackgroundColor3 = UiKit.Panel,
		BackgroundTransparency = 0.04,
		Parent = backdrop,
	}, {
		corner(16),
		create("UIStroke", { Thickness = 2, Color = UiKit.Accent, Transparency = 0.3 }),
		create("UISizeConstraint", { MaxSize = Vector2.new(620, 680) }),
		scale,
	})

	-- Everything but the button scrolls, so the card fits on small screens too.
	local scroll = create("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -84),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = panel,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
		create("UIPadding", {
			PaddingTop = UDim.new(0, 22),
			PaddingBottom = UDim.new(0, 8),
			PaddingLeft = UDim.new(0, 22),
			PaddingRight = UDim.new(0, 22),
		}),
	})
	local order = 0
	local function add(instance: GuiObject)
		order += 1
		instance.LayoutOrder = order
		instance.Parent = scroll
	end

	local title = paragraph(string.upper(Config.Volcano.Name), 34, UiKit.Accent, Enum.Font.GothamBlack)
	title.TextXAlignment = Enum.TextXAlignment.Center
	add(title)
	add(paragraph(INTRO, 17, UiKit.Text))
	add(paragraph("THE FOUR PHASES", 15, UiKit.Muted, Enum.Font.GothamBlack))
	for index, phase in Config.Round.Phases do
		local color = Config.Colors[phase.Id] or UiKit.Accent
		add(card(`{index}. {string.upper(phase.Name)}  ·  {phase.Duration}s`, PHASE_TIPS[phase.Id] or "", color))
	end
	add(paragraph("SURVIVAL TIPS", 15, UiKit.Muted, Enum.Font.GothamBlack))
	local bullets = {}
	for _, tip in TIPS do
		table.insert(bullets, `• {tip}`)
	end
	add(card("Remember", table.concat(bullets, "\n"), UiKit.Accent))

	local button = create("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(220, 48),
		BackgroundColor3 = UiKit.Accent,
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		TextColor3 = Color3.fromRGB(34, 22, 14),
		Text = "Okay!",
		Parent = panel,
	}, { corner(12) })
	if UserInputService.GamepadEnabled then
		GuiService.SelectedObject = button
	end

	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()

	local closing = false
	button.Activated:Connect(function()
		if closing then
			return
		end
		closing = true
		if GuiService.SelectedObject == button then
			GuiService.SelectedObject = nil
		end
		TweenService:Create(scale, TweenInfo.new(0.15), { Scale = 0.92 }):Play()
		local fade = TweenService:Create(backdrop, TweenInfo.new(0.15), { BackgroundTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		gui:Destroy()
	end)
end

function GuidePopup.Start()
	GuidePopup.Show()
end

return GuidePopup
