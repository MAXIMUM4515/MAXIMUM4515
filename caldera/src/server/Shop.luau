--[[
	Shop
	Every developer product goes through here. MarketplaceService.ProcessReceipt is game-wide, so
	products register a grant function under a key and this module handles their receipts. Each
	purchase adds the Robux the buyer spent to their saved total, which the lobby's "Most Robux
	Spent" board ranks.

	Donations (Config.Shop.Donations) are products that grant nothing but thanks, announced to the
	whole server. Product keys: "Extinguisher", and "Donate<Robux>" for each tier (the client's shop
	uses the same keys).

	In Studio a product with no id yet can be bought for free through ShopTest, so the whole shop
	and the Robux board can be tried before the products exist. Studio saves into separate test
	stores (see SavedCounter), so test purchases never reach the live board.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("MountIgnis")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local SavedCounter = require(script.Parent.SavedCounter)

type Product = {
	Key: string,
	Id: number,
	-- The price, counted for free Studio test purchases (a real receipt says what was paid).
	Robux: number?,
	Grant: (Player) -> (),
}

local DONATION_COLOR = Color3.fromRGB(255, 205, 70)

local Shop = {}

-- Robux each player has spent on developer products, all time.
Shop.Spent = (nil :: any) :: SavedCounter.SavedCounter

local products: { [string]: Product } = {}
local byId: { [number]: Product } = {}
local granted: { [string]: boolean } = {} -- receipts already granted in this server

local announceEvent = Net.Event("Announce")

-- Adds a product to the shop. With an id of 0 it isn't for sale yet (but is free to test in Studio).
-- Can be called before Init.
function Shop.Register(key: string, productId: number, robux: number?, grant: (Player) -> ())
	local product: Product = { Key = key, Id = productId, Robux = robux, Grant = grant }
	products[key] = product
	if productId ~= 0 then
		byId[productId] = product
	end
end

local function processReceipt(receipt: { [any]: any }): Enum.ProductPurchaseDecision
	local product = byId[receipt.ProductId]
	if not product then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Roblox can deliver the same receipt more than once; grant it only the first time.
	if granted[receipt.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		-- They left before it arrived: Roblox offers it again when they next join a server.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, err = pcall(product.Grant, player)
	if not ok then
		warn(`[Shop] could not grant {product.Key}:`, err)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	granted[receipt.PurchaseId] = true
	Shop.Spent:Add(player, tonumber(receipt.CurrencySpent) or 0)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function thanks(robux: number): (Player) -> ()
	return function(player: Player)
		announceEvent:FireAllClients(
			`{player.DisplayName} donated {Format.Robux(robux)}. Thank you!`,
			DONATION_COLOR,
			4,
			"small"
		)
	end
end

function Shop.Init()
	Shop.Spent = SavedCounter.new("RobuxSpent", Config.Leaderboards.RobuxSpent.StoreName)
	for _, tier in Config.Shop.Donations do
		Shop.Register(`Donate{tier.Robux}`, tier.ProductId, tier.Robux, thanks(tier.Robux))
	end

	-- Every product is registered by now, so no receipt arrives for one this server doesn't know.
	MarketplaceService.ProcessReceipt = processReceipt

	local unset = 0
	for _, product in products do
		if product.Id == 0 then
			unset += 1
		end
	end
	if unset > 0 then
		warn(
			`[Shop] {unset} developer product(s) have no id in Config yet: they are hidden in live servers and free in Studio.`
		)
	end

	-- Testing without products: Studio only, so a live server can never hand anything out free.
	Net.Event("ShopTest").OnServerEvent:Connect(function(player, key)
		local product = if typeof(key) == "string" then products[key] else nil
		if RunService:IsStudio() and product and product.Id == 0 then
			product.Grant(player)
			Shop.Spent:Add(player, product.Robux or 0)
		end
	end)
end

return Shop
