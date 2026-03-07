--[[
	TowerStats (ModuleScript)
	Place in ReplicatedStorage
	
	Defines tower templates and stat resolution.
]]

local TowerStats = {}

TowerStats.Templates = {
	Warrior = {
		ATK      = 10,
		ATK_SPD  = 1.2,   -- attacks per second
		RNG      = 8,     -- attack range in studs
		HP       = 100,
		MOVE_SPD = 16,

		-- Attack info
		AttackType   = "Melee",
		AttackName   = "CLEAVE",
		AttackDesc   = "Slash at the enemy, dealing 100% ATK to a single target.",
		DamageMulti  = 1.0,  -- 100% ATK
	},
}

return TowerStats