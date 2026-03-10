--[[
	TowerData (ModuleScript)
	Place in ReplicatedStorage

	Extended tower/equipment data used by the Inventory, Gacha, and Quest systems.
	This is separate from TowerStats (which holds combat numbers) – TowerData
	holds display-facing metadata such as descriptions, rarity, and banner pools.
]]

local TowerData = {}

-- ============================================================
-- RARITY TIERS
-- ============================================================

TowerData.Rarity = {
	COMMON    = { name = "Common",    color = Color3.fromRGB(180, 180, 180), stars = 1 },
	UNCOMMON  = { name = "Uncommon",  color = Color3.fromRGB(80,  200, 80),  stars = 2 },
	RARE      = { name = "Rare",      color = Color3.fromRGB(80,  120, 220), stars = 3 },
	EPIC      = { name = "Epic",      color = Color3.fromRGB(160, 60,  220), stars = 4 },
	LEGENDARY = { name = "Legendary", color = Color3.fromRGB(255, 165, 0),   stars = 5 },
}

-- ============================================================
-- TOWER DISPLAY DATA
-- ============================================================

TowerData.Towers = {
	Warrior = {
		displayName      = "Warrior",
		rarity           = "RARE",
		description      = "A sturdy frontline fighter who charges into enemies and slashes them with powerful melee attacks. Can cleave multiple foes in rapid succession.",
		role             = "Melee DPS",
		equipmentSlots   = 2,
		lockedByDefault  = false,   -- free starter tower
		bannerWeight     = 30,      -- higher = more common in gacha pools
		gachaBanner      = "standard",
		imageId          = "",      -- placeholder; fill with Roblox asset ID
	},

	Deadeye = {
		displayName      = "Deadeye",
		rarity           = "EPIC",
		description      = "A sharpshooter who picks off enemies from extreme range. Builds Headhunter stacks for devastating enhanced shots with bonus armour penetration.",
		role             = "Ranged DPS",
		equipmentSlots   = 3,
		lockedByDefault  = true,
		bannerWeight     = 15,
		gachaBanner      = "standard",
		imageId          = "",
	},

	Vitalist = {
		displayName      = "Vitalist",
		rarity           = "EPIC",
		description      = "A versatile support unit firing burst rounds that damage enemies or heal allied towers. Charges a Nano Blast beam that can turn the tide of battle.",
		role             = "Support / Hybrid",
		equipmentSlots   = 3,
		lockedByDefault  = true,
		bannerWeight     = 15,
		gachaBanner      = "standard",
		imageId          = "",
	},
}

-- ============================================================
-- EQUIPMENT DISPLAY DATA
-- ============================================================

TowerData.Equipment = {
	SharpBlade = {
		displayName      = "Sharp Blade",
		description      = "Increases ATK by 5.",
		rarity           = "COMMON",
		stat             = "ATK",
		bonus            = 5,
		compatibleRoles  = { "Melee DPS" },
		imageId          = "",
	},
	SniperScope = {
		displayName      = "Sniper Scope",
		description      = "Increases RNG by 8.",
		rarity           = "UNCOMMON",
		stat             = "RNG",
		bonus            = 8,
		compatibleRoles  = { "Ranged DPS" },
		imageId          = "",
	},
	HealingPack = {
		displayName      = "Healing Pack",
		description      = "Increases AP by 6.",
		rarity           = "UNCOMMON",
		stat             = "AP",
		bonus            = 6,
		compatibleRoles  = { "Support / Hybrid" },
		imageId          = "",
	},
	SpeedBoots = {
		displayName      = "Speed Boots",
		description      = "Increases MOVE_SPD by 3.",
		rarity           = "COMMON",
		stat             = "MOVE_SPD",
		bonus            = 3,
		compatibleRoles  = nil,    -- universal; equippable on any tower
		imageId          = "",
	},
	ArmorPlate = {
		displayName      = "Armor Plate",
		description      = "Increases HP by 25.",
		rarity           = "COMMON",
		stat             = "HP",
		bonus            = 25,
		compatibleRoles  = nil,
		imageId          = "",
	},
}

-- ============================================================
-- GACHA BANNER CONFIGURATION
-- ============================================================

TowerData.Banners = {
	standard = {
		displayName        = "Standard Summon",
		description        = "A permanent banner featuring all available towers.\nPity counter resets at 70 Gem pulls.",
		costPerPull        = 160,     -- Gems per single pull
		coinCostPerPull    = 1000,    -- Coins per single pull (no pity)
		pityAt             = 70,
		pools              = { "Warrior", "Deadeye", "Vitalist" },
		rateUpTower        = nil,
		rateUpChance       = 0,
		rateUpRotationSec  = 0,
	},
	special = {
		displayName        = "Special Summon",
		description        = "Features an increased chance for the Rate-Up tower, rotated every hour.\nPity counter resets at 70 Gem pulls.\nCoin pulls do NOT contribute to pity.",
		costPerPull        = 160,     -- Gems per single pull
		coinCostPerPull    = 1000,    -- Coins per single pull (no pity)
		pityAt             = 70,
		pools              = { "Warrior", "Deadeye", "Vitalist" },
		rateUpTower        = "Deadeye",  -- default starting Rate-Up (server overrides hourly)
		rateUpChance       = 0.50,    -- 50 % of EPIC+ pulls guaranteed to be the Rate-Up
		rateUpRotationSec  = 3600,
	},
}

-- ============================================================
-- GACHA BASE PULL RATES  (must sum to exactly 100.0)
-- WARNING: If you modify these values, ensure they still total 100.0 or
-- the rollRarity function in CurrencyManager will produce incorrect results.
-- ============================================================

TowerData.GachaRates = {
	COMMON    = 50.0,
	UNCOMMON  = 30.0,
	RARE      = 14.0,
	EPIC      =  5.0,
	LEGENDARY =  1.0,
}

-- ============================================================
-- QUEST DEFINITIONS
-- ============================================================

TowerData.Quests = {
	Daily = {
		{
			id          = "daily_place_5",
			displayName = "Tower Assembly",
			description = "Place 5 towers in a single round.",
			goal        = 5,
			reward      = { Coins = 200 },
		},
		{
			id          = "daily_kill_20",
			displayName = "Enemy Slayer",
			description = "Defeat 20 enemies.",
			goal        = 20,
			reward      = { Coins = 150 },
		},
		{
			id          = "daily_survive_3",
			displayName = "Survivor",
			description = "Survive 3 waves.",
			goal        = 3,
			reward      = { Coins = 100 },
		},
	},

	Weekly = {
		{
			id          = "weekly_kill_200",
			displayName = "Mass Extermination",
			description = "Defeat 200 enemies across all sessions this week.",
			goal        = 200,
			reward      = { Coins = 1500 },
		},
		{
			id          = "weekly_place_30",
			displayName = "Army Builder",
			description = "Place 30 towers across all sessions this week.",
			goal        = 30,
			reward      = { Coins = 1200 },
		},
		{
			id          = "weekly_survive_10",
			displayName = "Endurance",
			description = "Survive a total of 10 waves across all sessions this week.",
			goal        = 10,
			reward      = { Coins = 800 },
		},
	},

	Challenges = {
		{
			id          = "challenge_no_sell",
			displayName = "Committed",
			description = "Complete a round without selling any towers.",
			goal        = 1,
			reward      = { Coins = 500, Equipment = "SharpBlade" },
		},
		{
			id          = "challenge_all_towers",
			displayName = "Collector",
			description = "Have all 3 tower types placed at the same time.",
			goal        = 1,
			reward      = { Coins = 1000, Equipment = "SniperScope" },
		},
		{
			id          = "challenge_100_kills",
			displayName = "Century",
			description = "Defeat 100 enemies in a single round.",
			goal        = 100,
			reward      = { Coins = 2000, Equipment = "HealingPack" },
		},
	},
}

return TowerData
