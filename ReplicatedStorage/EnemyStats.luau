--[[
	EnemyStats Module
	Defines base stats and category values for basic enemies.
]]

local EnemyStats = {}

EnemyStats.AtkSpdTiers = {
	["VERY SLOW"]  = 3.0,
	["SLOW"]       = 2.0,
	["MEDIUM"]     = 1.2,
	["FAST"]       = 0.7,
	["VERY FAST"]  = 0.3,
}

EnemyStats.MoveSpdTiers = {
	["VERY SLOW"]  = 2,
	["SLOW"]       = 4,
	["MEDIUM"]     = 7,
	["FAST"]       = 10,
	["VERY FAST"]  = 14,
}

EnemyStats.RngTiers = {
	["VERY SHORT"] = 5,
	["SHORT"]      = 10,
	["MEDIUM"]     = 18,
	["LONG"]       = 28,
	["VERY LONG"]  = 40,
}

EnemyStats.SpdOrder = {"VERY SLOW", "SLOW", "MEDIUM", "FAST", "VERY FAST"}
EnemyStats.RngOrder = {"VERY SHORT", "SHORT", "MEDIUM", "LONG", "VERY LONG"}

EnemyStats.Templates = {
	["BasicZombie"] = {
		ATK        = 5,
		ATK_SPD    = "MEDIUM",
		MOVE_SPD   = "MEDIUM",
		HP         = 50,
		RNG        = "VERY SHORT",
		TARGETING  = "CLOSEST",
	},
	
	["FastDummy"] = {
		ATK        = 3,
		ATK_SPD    = "FAST",
		MOVE_SPD   = "FAST",
		HP         = 30,
		RNG        = "VERY SHORT",
		TARGETING  = "CLOSEST",
	},
	
	["TankyDummy"] = {
		ATK        = 7,
		ATK_SPD    = "SLOW",
		MOVE_SPD   = "SLOW",
		HP         = 70,
		RNG        = "VERY SHORT",
		TARGETING  = "CLOSEST",
	},
	
}






function EnemyStats.ResolveMoveSpd(tierName: string): number
	return EnemyStats.MoveSpdTiers[tierName] or EnemyStats.MoveSpdTiers["MEDIUM"]
end

function EnemyStats.ResolveAtkSpd(tierName: string): number
	return EnemyStats.AtkSpdTiers[tierName] or EnemyStats.AtkSpdTiers["MEDIUM"]
end

function EnemyStats.ResolveRng(tierName: string): number
	return EnemyStats.RngTiers[tierName] or EnemyStats.RngTiers["MEDIUM"]
end

function EnemyStats.ShiftTier(tierName: string, orderList: {string}, delta: number): string
	for i, name in ipairs(orderList) do
		if name == tierName then
			local newIndex = math.clamp(i + delta, 1, #orderList)
			return orderList[newIndex]
		end
	end
	return tierName
end

function EnemyStats.ApplyModifier(baseValue: number, flat: number?, percent: number?): number
	local value = baseValue
	if flat then
		value = value + flat
	end
	if percent then
		value = value * (percent / 100)
	end
	return math.ceil(value)
end

return EnemyStats