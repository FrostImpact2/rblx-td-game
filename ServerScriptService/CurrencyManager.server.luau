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

-- Client ↔ Server: loadout/equipment configuration
local loadoutConfigRemote      = Instance.new("RemoteFunction")
loadoutConfigRemote.Name       = "LoadoutConfigRequest"
loadoutConfigRemote.Parent     = ReplicatedStorage

local loadoutUpdatedRemote      = Instance.new("RemoteEvent")
loadoutUpdatedRemote.Name       = "LoadoutConfigUpdated"
loadoutUpdatedRemote.Parent     = ReplicatedStorage

-- ============================================================
-- PLAYER DATA  (in-memory; replace with DataStore for persistence)
-- ============================================================

local playerData = {}   -- [userId] = { Coins, Gems, pity, unlocked, equipment }

local STARTING_COINS = 1000
local STARTING_GEMS  = 50
local LOADOUT_SIZE   = 5

local function buildDefaultLoadout(): { string }
	local preferred = { "Warrior", "Deadeye", "Vitalist", "Wanderer", "Pathfinder" }
	local out = {}
	for _, towerName in ipairs(preferred) do
		if TowerData.Towers[towerName] then
			table.insert(out, towerName)
		end
	end
	if #out == 0 then
		for towerName in pairs(TowerData.Towers) do
			table.insert(out, towerName)
		end
		table.sort(out)
	end
	return out
end

local DEFAULT_LOADOUT = buildDefaultLoadout()
-- Starter kit so the feature is immediately testable in fresh sessions.
local DEFAULT_EQUIPMENT_OWNED = {
	SharpBlade = true,
	SniperScope = true,
	HealingPack = true,
	SpeedBoots = true,
	ArmorPlate = true,
}

local function copyArray(arr: { any }): { any }
	local out = {}
	for i, v in ipairs(arr) do
		out[i] = v
	end
	return out
end

local function copyNestedArrayMap(map: { [string]: { any } }): { [string]: { any } }
	local out = {}
	for k, list in pairs(map or {}) do
		out[k] = copyArray(list)
	end
	return out
end

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
			-- owned equipment keys (unique inventory)
			equipment = table.clone(DEFAULT_EQUIPMENT_OWNED),
			-- ordered list of tower names used by in-round hotbar
			loadout   = copyArray(DEFAULT_LOADOUT),
			-- equipped[towerName] = { "EquipmentKey1", ... } (max by TowerData.Towers[tower].equipmentSlots)
			equipped  = {},
		}
	end
	return playerData[uid]
end

local function sendCurrency(player: Player)
	local d = getOrCreate(player)
	updateCurrencyRemote:FireClient(player, { Coins = d.Coins, Gems = d.Gems })
end

local function buildSnapshot(player: Player)
	local d = getOrCreate(player)
	return {
		Coins = d.Coins,
		Gems = d.Gems,
		unlocked = table.clone(d.unlocked),
		equipment = table.clone(d.equipment),
		loadout = copyArray(d.loadout),
		equipped = copyNestedArrayMap(d.equipped),
	}
end

local function sendLoadoutSnapshot(player: Player)
	loadoutUpdatedRemote:FireClient(player, buildSnapshot(player))
end

local function sanitizeLoadout(d): { string }
	local out = {}
	local seen = {}
	for _, towerName in ipairs(d.loadout or {}) do
		if type(towerName) == "string"
			and TowerData.Towers[towerName]
			and d.unlocked[towerName]
			and not seen[towerName]
		then
			table.insert(out, towerName)
			seen[towerName] = true
			if #out >= LOADOUT_SIZE then
				break
			end
		end
	end

	for _, towerName in ipairs(DEFAULT_LOADOUT) do
		if #out >= LOADOUT_SIZE then break end
		if d.unlocked[towerName] and not seen[towerName] then
			table.insert(out, towerName)
			seen[towerName] = true
		end
	end
	d.loadout = out
	return out
end

local function compactTowerEquipment(d, towerName: string)
	local slots = (TowerData.Towers[towerName] and TowerData.Towers[towerName].equipmentSlots) or 0
	local eqList = d.equipped[towerName] or {}
	local filtered = {}
	local usedElsewhere = {}
	for otherTower, list in pairs(d.equipped) do
		if otherTower ~= towerName then
			for _, eqKey in ipairs(list) do
				usedElsewhere[eqKey] = true
			end
		end
	end
	for _, eqKey in ipairs(eqList) do
		local eqData = TowerData.Equipment[eqKey]
		if eqData and d.equipment[eqKey] and not usedElsewhere[eqKey] then
			table.insert(filtered, eqKey)
			usedElsewhere[eqKey] = true
			if #filtered >= slots then
				break
			end
		end
	end
	d.equipped[towerName] = filtered
end

local function sanitizeEquipment(d)
	for towerName in pairs(TowerData.Towers) do
		compactTowerEquipment(d, towerName)
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	local d = getOrCreate(player)
	sanitizeLoadout(d)
	sanitizeEquipment(d)
	sendCurrency(player)
	sendLoadoutSnapshot(player)
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
		sanitizeLoadout(d)
	end

	sendCurrency(player)
	sendLoadoutSnapshot(player)
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

local function canEquipOnTower(towerName: string, eqKey: string): boolean
	local towerData = TowerData.Towers[towerName]
	local eqData    = TowerData.Equipment[eqKey]
	if not towerData or not eqData then return false end
	local compat = eqData.compatibleRoles
	if not compat or #compat == 0 then return true end
	for _, role in ipairs(compat) do
		if role == towerData.role then
			return true
		end
	end
	return false
end

local function toggleEquipment(player: Player, towerName: string, eqKey: string)
	local d = getOrCreate(player)
	if type(towerName) ~= "string" or type(eqKey) ~= "string" then
		return false, "Invalid tower or equipment."
	end
	if not TowerData.Towers[towerName] then
		return false, "Unknown tower."
	end
	if not d.equipment[eqKey] then
		return false, "Equipment not owned."
	end
	if not canEquipOnTower(towerName, eqKey) then
		return false, "Equipment is incompatible with this tower role."
	end

	d.equipped[towerName] = d.equipped[towerName] or {}
	local list = d.equipped[towerName]
	local existingIdx = table.find(list, eqKey)
	if existingIdx then
		table.remove(list, existingIdx)
		sendLoadoutSnapshot(player)
		return true, "Equipment removed."
	end

	for otherTower, otherList in pairs(d.equipped) do
		if otherTower ~= towerName and table.find(otherList, eqKey) then
			return false, "Equipment is already equipped on another tower."
		end
	end

	local slots = (TowerData.Towers[towerName].equipmentSlots or 0)
	if #list >= slots then
		return false, "No free equipment slots."
	end

	table.insert(list, eqKey)
	sendLoadoutSnapshot(player)
	return true, "Equipment equipped."
end

local function setLoadout(player: Player, loadoutList: { string })
	local d = getOrCreate(player)
	if typeof(loadoutList) ~= "table" then
		return false, "Invalid loadout payload."
	end
	d.loadout = copyArray(loadoutList)
	sanitizeLoadout(d)
	sendLoadoutSnapshot(player)
	return true, "Loadout updated."
end

loadoutConfigRemote.OnServerInvoke = function(player: Player, action: string, payload: table?)
	local d = getOrCreate(player)
	sanitizeLoadout(d)
	sanitizeEquipment(d)
	local ok = true
	local message = "OK"
	payload = payload or {}

	if action == "SetLoadout" then
		ok, message = setLoadout(player, payload.loadout or {})
	elseif action == "ToggleEquipment" then
		ok, message = toggleEquipment(player, payload.tower, payload.equipment)
	elseif action == "ClearTowerEquipment" then
		local towerName = payload.tower
		if type(towerName) ~= "string" or not TowerData.Towers[towerName] then
			ok, message = false, "Invalid tower."
		else
			d.equipped[towerName] = {}
			sendLoadoutSnapshot(player)
			ok, message = true, "Equipment cleared."
		end
	elseif action ~= "Get" then
		ok, message = false, "Unknown action."
	end

	return {
		ok = ok,
		message = message,
		data = buildSnapshot(player),
	}
end

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
	local d = getOrCreate(player)
	sanitizeLoadout(d)
	sanitizeEquipment(d)
	return d
end

function CurrencyManager.GetRateUpTower(): string
	return rateUpTower
end

function CurrencyManager.GetSnapshot(player: Player)
	return buildSnapshot(player)
end

function CurrencyManager.GetLoadout(player: Player): { string }
	local d = CurrencyManager.GetData(player)
	return copyArray(d.loadout)
end

function CurrencyManager.GetEquippedForTower(player: Player, towerName: string): { string }
	local d = CurrencyManager.GetData(player)
	return copyArray(d.equipped[towerName] or {})
end

return CurrencyManager
