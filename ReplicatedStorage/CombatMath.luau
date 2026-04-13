local CombatMath = {}

local function toInt(value: number): number
return math.floor(value + 0.5)
end

function CombatMath.ApplyModifiers(baseValue: number, flat: number?, percent: number?): number
local value = baseValue
if flat then
value += flat
end
if percent then
value *= (1 + (percent / 100))
end
return toInt(value)
end

function CombatMath.ApplyDefense(rawDamage: number, defense: number?): number
local mitigated = toInt(rawDamage) - toInt(defense or 0)
if mitigated < 1 then
return 1
end
return mitigated
end

function CombatMath.ResolveIntegerStat(value: any, fallback: number, minValue: number?): number
local n = tonumber(value) or fallback
n = toInt(n)
if minValue ~= nil then
n = math.max(minValue, n)
end
return n
end

return CombatMath
