--[[
	Shop (client)
	The shop panel on the right edge of the screen: the fire extinguisher, with the foam left in its
	tank, and a DONATE button that opens a picker of donation tiers (Config.Shop.Donations).

	Products with no id yet are hidden in live servers. In Studio they show and are free to test
	(ShopTest); product keys match the server's Shop: "Extinguisher" and "Donate<Robux>".
]]

local GuiService = game:GetService("GuiService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local UiKit = require(script.Parent.UiKit)

local EX = Config.Extinguisher
local FOAM = Color3.fromRGB(140, 200, 255)
local GOLD = Color3.fromRGB(255, 205, 70)
local DARK_TEXT = Color3.fromRGB(28, 24, 20)

local player = Players.LocalPlayer
local create = UiKit.create
local corner = UiKit.corner

local Shop = {}

local function forSale(productId: number): boolean
	return productId ~= 0 or RunService:IsStudio()
end

local function buy(key: string, productId: number)
	if productId ~= 0 then
		MarketplaceService:PromptProductPurchase(player, productId)
	elseif RunService:IsStudio() then
		Net.Event("ShopTest"):FireServer(key)
	end
end

local function textLabel(props: UiKit.Props): TextLabel
	local defaults: UiKit.Props = {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for key, value in props do
		defaults[key] = value
	end
	return create("TextLabel", defaults)
end

local function button(props: UiKit.Props): TextButton
	local defaults: UiKit.Props = {
		Size = UDim2.new(1, 0, 0, 36),
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		TextColor3 = DARK_TEXT,
	}
	for key, value in props do
		defaults[key] = value
	end
	return create(
		"TextButton",
		defaults,
		{ corner(8), UiKit.padding(8), create("UITextSizeConstraint", { MaxTextSize = 16 }) }
	)
end

--------------------------------------------------------------------------------------------
-- Fire extinguisher
--------------------------------------------------------------------------------------------

local function extinguisherSection(order: number, parent: Instance)
	local testing = EX.ProductId == 0
	local section = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = parent,
	}, { create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	textLabel({
		LayoutOrder = 1,
		Font = Enum.Font.GothamBlack,
		TextSize = 16,
		TextColor3 = FOAM,
		Text = "FIRE EXTINGUISHER",
		Parent = section,
	})
	textLabel({
		LayoutOrder = 2,
		TextSize = 13,
		TextColor3 = UiKit.Muted,
		Text = "Spray to cool down and put out anyone on fire, you included.",
		Parent = section,
	})

	-- Foam gauge, shown while they own one. A full bar is one tank (extra tanks keep it full).
	local gaugeFill = create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = FOAM,
		BorderSizePixel = 0,
	}, { corner(4) })
	local gaugeText = create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(20, 30, 40),
		ZIndex = 2,
		Text = "",
	})
	local gauge = create("Frame", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundColor3 = Color3.fromRGB(50, 60, 70),
		BorderSizePixel = 0,
		Visible = false,
		Parent = section,
	}, { corner(4), gaugeFill, gaugeText })

	local buyButton = button({ LayoutOrder = 4, BackgroundColor3 = FOAM, Text = "BUY", Parent = section })

	local price: string? = nil
	local function refresh()
		local foam = player:GetAttribute("ExtinguisherFoam")
		local owned = typeof(foam) == "number" and foam > 0
		gauge.Visible = owned
		if owned then
			gaugeFill.Size = UDim2.fromScale(math.clamp(foam / EX.TankSeconds, 0, 1), 1)
			gaugeText.Text = `{math.ceil(foam)}s of foam`
		end
		local action = if owned then "ADD FOAM" else "BUY"
		buyButton.Text = if testing then `{action} (FREE IN STUDIO)` elseif price then `{action} · {price}` else action
	end
	player:GetAttributeChangedSignal("ExtinguisherFoam"):Connect(refresh)
	refresh()

	if not testing then
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(EX.ProductId, Enum.InfoType.Product)
			end)
			if ok and info and info.PriceInRobux then
				price = Format.Robux(info.PriceInRobux)
				refresh()
			end
		end)
	end

	buyButton.Activated:Connect(function()
		buy("Extinguisher", EX.ProductId)
	end)
end

--------------------------------------------------------------------------------------------
-- Donations
--------------------------------------------------------------------------------------------

-- The donation picker: a dimmed screen with a card of tier buttons. Returns a function that opens it.
local function buildDonations(tiers: { { Robux: number, ProductId: number } }): () -> ()
	local gui = create("ScreenGui", {
		Name = "MountIgnisDonate",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 15,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	-- Clicking the dimmed world around the card closes it.
	local backdrop = create("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		AutoButtonColor = false,
		Text = "",
		Parent = gui,
	})
	-- The tiers scroll between the title and the Close button, so the card fits short screens too.
	local scale = create("UIScale", { Scale = 1 })
	local card = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 380, 0.9, 0),
		BackgroundColor3 = UiKit.Panel,
		BackgroundTransparency = 0.04,
		Active = true,
		Parent = gui,
	}, {
		corner(16),
		UiKit.padding(16),
		scale,
		create("UISizeConstraint", { MaxSize = Vector2.new(380, 460) }),
		create("UIStroke", { Thickness = 2, Color = GOLD, Transparency = 0.3 }),
	})

	create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		TextColor3 = GOLD,
		Text = `SUPPORT {string.upper(Config.Volcano.Name)}`,
		Parent = card,
	}, { create("UITextSizeConstraint", { MaxTextSize = 24 }) })

	local scroll = create("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 1, -40 - 52),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = card,
	}, { create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }) })

	local note = "Every donation goes on the Most Robux Spent board in the lobby."
	for _, tier in tiers do
		if tier.ProductId == 0 then
			note ..= "\nStudio test: tiers without a product id are free."
			break
		end
	end
	textLabel({
		LayoutOrder = 1,
		Size = UDim2.new(1, -8, 0, 0),
		TextSize = 14,
		TextColor3 = UiKit.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = note,
		Parent = scroll,
	})

	local grid = create("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = scroll,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.new(0.5, -5, 0, 44),
			CellPadding = UDim2.fromOffset(10, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local first: TextButton? = nil
	for index, tier in tiers do
		local tierButton = button({
			LayoutOrder = index,
			BackgroundColor3 = GOLD,
			Text = Format.Robux(tier.Robux),
			Parent = grid,
		})
		first = first or tierButton
		tierButton.Activated:Connect(function()
			buy(`Donate{tier.Robux}`, tier.ProductId)
		end)
	end

	local close = button({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = Color3.fromRGB(70, 62, 58),
		TextColor3 = UiKit.Text,
		Text = "CLOSE",
		Parent = card,
	})

	local function hide()
		if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
		gui.Enabled = false
	end
	close.Activated:Connect(hide)
	backdrop.Activated:Connect(hide)

	return function()
		gui.Enabled = true
		scale.Scale = 0.9
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
		if UserInputService.GamepadEnabled and first then
			GuiService.SelectedObject = first
		end
	end
end

--------------------------------------------------------------------------------------------

function Shop.Start()
	local tiers = {}
	for _, tier in Config.Shop.Donations do
		if forSale(tier.ProductId) then
			table.insert(tiers, tier)
		end
	end
	local sellsExtinguisher = forSale(EX.ProductId)
	if not sellsExtinguisher and #tiers == 0 then
		return
	end

	local gui = create("ScreenGui", {
		Name = "MountIgnisShop",
		ResetOnSpawn = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local panel = create("Frame", {
		Name = "Shop",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(196, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = UiKit.Panel,
		BackgroundTransparency = 0.2,
		Parent = gui,
	}, {
		corner(12),
		UiKit.padding(10),
		create("UIStroke", { Thickness = 2, Color = UiKit.Accent, Transparency = 0.45 }),
		create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	if sellsExtinguisher then
		extinguisherSection(1, panel)
	end
	if #tiers > 0 then
		local open = buildDonations(tiers)
		local donate = button({
			LayoutOrder = 2,
			BackgroundColor3 = GOLD,
			Text = "DONATE",
			Parent = panel,
		})
		donate.Activated:Connect(open)
	end
end

return Shop
