--[[
	CurrencyManager (Server Script)
	Place in ServerScriptService/

	Manages per-player currencies (Coins and Gems) and gacha pull logic.

	Currencies:
	  Coins – used for most purchases; coin gacha pulls do NOT add to pity.
	  Gems  – used for gacha; pulls with Gems DO add to pity.

	Gacha pity:
	  Every banner tracks pity separately per player.
	  Hitting 70 Gem pulls on a banner guarantees an EPIC or higher reward.
	  Pity resets after the guarantee fires.

	Special banner:
	  Rate-Up tower is rotated every hour.  50 % of EPIC+ pulls from Gem
	  pulls are guaranteed to be the Rate-Up tower.

	Starting balances (new players):
	  Coins : 1 000
	  Gems  : 50
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TowerData         = require(ReplicatedStorage:WaitForChild("TowerData", 10))

-- ============================================================
-- REMOTE EVENTS
-- ============================================================

-- Server → Client: push updated balances
local updateCurrencyRemote      = Instance.new("RemoteEvent")
updateCurrencyRemote.Name       = "UpdateCurrency"
updateCurrencyRemote.Parent     = ReplicatedStorage

-- Client → Server: request a gacha pull
local gachaPullRemote      = Instance.new("RemoteEvent")
gachaPullRemote.Name       = "GachaPull"
gachaPullRemote.Parent     = ReplicatedStorage

-- Server → Client: send pull result(s)
local gachaResultRemote      = Instance.new("RemoteEvent")
gachaResultRemote.Name       = "GachaResult"
gachaResultRemote.Parent     = ReplicatedStorage

-- ============================================================
-- PLAYER DATA  (in-memory; replace with DataStore for persistence)
-- ============================================================

local playerData = {}   -- [userId] = { Coins, Gems, pity, unlocked, equipment }

local STARTING_COINS = 1000
local STARTING_GEMS  = 50

local function getOrCreate(player: Player)
	local uid = player.UserId
	if not playerData[uid] then
		playerData[uid] = {
			Coins     = STARTING_COINS,
			Gems      = STARTING_GEMS,
			-- pity[bannerKey] = number of gem pulls since last guarantee
			pity      = { standard = 0, special = 0 },
			-- set of unlocked tower names
			unlocked  = { Warrior = true },   -- Warrior is free
			-- list of owned equipment keys
			equipment = {},
		}
	end
	return playerData[uid]
end

local function sendCurrency(player: Player)
	local d = getOrCreate(player)
	updateCurrencyRemote:FireClient(player, { Coins = d.Coins, Gems = d.Gems })
end

Players.PlayerAdded:Connect(function(player: Player)
	getOrCreate(player)
	sendCurrency(player)
end)

-- Clean up on leave
Players.PlayerRemoving:Connect(function(player: Player)
	playerData[player.UserId] = nil
end)

-- ============================================================
-- RATE-UP ROTATION  (special banner)
-- ============================================================

local rateUpTower  = TowerData.Banners.special.rateUpTower or "Deadeye"  -- initialized from TowerData
local allTowers    = {}
for name in pairs(TowerData.Towers) do
	table.insert(allTowers, name)
end
table.sort(allTowers)   -- deterministic ordering

task.spawn(function()
	local rotationSec = TowerData.Banners.special.rateUpRotationSec or 3600
	while true do
		task.wait(rotationSec)
		-- Advance to next tower in the sorted list
		local idx = table.find(allTowers, rateUpTower) or 0
		idx = (idx % #allTowers) + 1
		rateUpTower = allTowers[idx]
		print("[CurrencyManager] Rate-Up tower rotated to: " .. rateUpTower)
	end
end)

-- ============================================================
-- GACHA LOGIC
-- ============================================================

local rarityOrder = { "COMMON", "UNCOMMON", "RARE", "EPIC", "LEGENDARY" }

-- Roll a rarity tier, optionally forcing at least EPIC (pity guarantee)
local function rollRarity(forceEpicPlus: boolean): string
	if forceEpicPlus then
		local epicPlusRates = { EPIC = TowerData.GachaRates.EPIC, LEGENDARY = TowerData.GachaRates.LEGENDARY }
		local total = epicPlusRates.EPIC + epicPlusRates.LEGENDARY
		local r = math.random() * total
		return (r <= epicPlusRates.LEGENDARY) and "LEGENDARY" or "EPIC"
	end

	local r   = math.random() * 100
	local acc = 0
	for _, tier in ipairs(rarityOrder) do
		acc = acc + (TowerData.GachaRates[tier] or 0)
		if r <= acc then return tier end
	end
	return "COMMON"
end

-- Pick a tower from the banner pool that matches the given rarity
local function pickTower(bannerKey: string, rarity: string, useRateUp: boolean): string
	local banner  = TowerData.Banners[bannerKey]
	local pool    = banner and banner.pools or allTowers

	local candidates = {}
	for _, name in ipairs(pool) do
		local td = TowerData.Towers[name]
		if td and td.rarity == rarity then
			table.insert(candidates, name)
		end
	end

	-- Apply Rate-Up logic for the special banner
	if useRateUp and bannerKey == "special" then
		local rateUpChance = TowerData.Banners.special.rateUpChance or 0
		if (rarity == "EPIC" or rarity == "LEGENDARY") and math.random() < rateUpChance then
			return rateUpTower
		end
	end

	if #candidates == 0 then
		-- Fallback: any tower from pool
		return pool[math.random(1, #pool)]
	end
	return candidates[math.random(1, #candidates)]
end

-- Execute a single pull; useGems=true means pity is tracked
local function doPull(player: Player, bannerKey: string, useGems: boolean): { tower: string, rarity: string, isNew: boolean }
	local d         = getOrCreate(player)
	local banner    = TowerData.Banners[bannerKey]
	if not banner then
		warn("[CurrencyManager] Unknown banner: " .. tostring(bannerKey))
		return { tower = "Warrior", rarity = "RARE", isNew = false }
	end

	-- Deduct currency
	local cost = useGems and banner.costPerPull or banner.coinCostPerPull
	if useGems then
		if d.Gems < cost then
			return nil  -- caller should have validated; just return nil
		end
		d.Gems = d.Gems - cost
	else
		if d.Coins < cost then
			return nil
		end
		d.Coins = d.Coins - cost
	end

	-- Pity tracking only applies to Gem pulls
	local pityCount = 0
	if useGems then
		d.pity[bannerKey] = (d.pity[bannerKey] or 0) + 1
		pityCount = d.pity[bannerKey]
	end

	local forceEpicPlus = useGems and (pityCount >= (banner.pityAt or 70))
	local rarity        = rollRarity(forceEpicPlus)

	if forceEpicPlus and useGems then
		d.pity[bannerKey] = 0   -- reset pity after guarantee
	end

	local tower = pickTower(bannerKey, rarity, useGems and bannerKey == "special")
	local isNew = not d.unlocked[tower]
	if isNew then
		d.unlocked[tower] = true
	end

	sendCurrency(player)
	return { tower = tower, rarity = rarity, isNew = isNew }
end

-- ============================================================
-- REMOTE HANDLER: GachaPull
--   bannerKey  : "standard" | "special"
--   pullCount  : 1 | 10
--   useGems    : true = spend Gems (counts pity), false = spend Coins (no pity)
-- ============================================================

gachaPullRemote.OnServerEvent:Connect(function(player: Player, bannerKey: string, pullCount: number, useGems: boolean)
	pullCount = math.clamp(tonumber(pullCount) or 1, 1, 10)

	local d      = getOrCreate(player)
	local banner = TowerData.Banners[bannerKey]
	if not banner then return end

	local cost = useGems and (banner.costPerPull * pullCount) or (banner.coinCostPerPull * pullCount)
	local balance = useGems and d.Gems or d.Coins
	if balance < cost then
		-- Silently reject insufficient funds (client should prevent this)
		return
	end

	local results = {}
	for _ = 1, pullCount do
		local result = doPull(player, bannerKey, useGems)
		if result then
			table.insert(results, result)
		end
	end

	-- Send all results to the client at once
	gachaResultRemote:FireClient(player, results)
	sendCurrency(player)
end)

-- ============================================================
-- EXPOSED API  (used by other server scripts if needed)
-- ============================================================

local CurrencyManager = {}

function CurrencyManager.AddCoins(player: Player, amount: number)
	local d = getOrCreate(player)
	d.Coins = d.Coins + amount
	sendCurrency(player)
end

function CurrencyManager.AddGems(player: Player, amount: number)
	local d = getOrCreate(player)
	d.Gems = d.Gems + amount
	sendCurrency(player)
end

function CurrencyManager.GetData(player: Player)
	return getOrCreate(player)
end

function CurrencyManager.GetRateUpTower(): string
	return rateUpTower
end

return CurrencyManager
