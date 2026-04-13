--[[
EnemyStats Module
Defines integer base stats for enemies.
ATK_SPD is attack delay in seconds (lower is better).
]]

local EnemyStats = {}
local DEFAULT_MOVE_SPD = 7
local DEFAULT_ATK_SPD = 2
local DEFAULT_RNG = 5

local function resolveIntStat(value: any, fallback: number): number
	local num = tonumber(value)
	if num == nil then
		return fallback
	end
	return math.max(1, math.floor(num + 0.5))
end

EnemyStats.Templates = {
["BasicZombie"] = {
ATK       = 5,
DEF       = 0,
ATK_SPD   = 2,
MOVE_SPD  = 7,
HP        = 50,
RNG       = 5,
TARGETING = "CLOSEST",
},

["FastDummy"] = {
ATK       = 3,
DEF       = 0,
ATK_SPD   = 1,
MOVE_SPD  = 10,
HP        = 30,
RNG       = 5,
TARGETING = "CLOSEST",
},

["TankyDummy"] = {
ATK       = 7,
DEF       = 2,
ATK_SPD   = 3,
MOVE_SPD  = 4,
HP        = 70,
RNG       = 5,
TARGETING = "CLOSEST",
},
}

function EnemyStats.ResolveMoveSpd(value: any): number
	return resolveIntStat(value, DEFAULT_MOVE_SPD)
end

function EnemyStats.ResolveAtkSpd(value: any): number
	return resolveIntStat(value, DEFAULT_ATK_SPD)
end

function EnemyStats.ResolveRng(value: any): number
	return resolveIntStat(value, DEFAULT_RNG)
end

function EnemyStats.ApplyModifier(baseValue: number, flat: number?, percent: number?): number
local value = baseValue
if flat then
value += flat
end
if percent then
value *= (1 + (percent / 100))
end
return math.max(1, math.floor(value + 0.5))
end

return EnemyStats
