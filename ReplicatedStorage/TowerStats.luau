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

	Deadeye = {
		ATK      = 12,
		AP       = 15,    -- ability power used by Headhunter
		ATK_SPD  = 1.0,   -- attacks per second
		RNG      = 30,    -- long ranged
		HP       = 75,
		MOVE_SPD = 14,

		-- Attack info
		AttackType   = "Ranged",
		AttackName   = "REVOLVER",
		AttackDesc   = "Shoot the enemy, dealing 1× ATK to a single target. Enhances basic attack after 2 usages.",
		DamageMulti  = 1.0,
	},

	Vitalist = {
		ATK      = 12,    -- basic attack; each bullet does 0.125× ATK
		AP       = 18,    -- ability power; Nano Blast deals/heals 2× AP
		ATK_SPD  = 1.2,   -- burst attacks per second
		RNG      = 20,    -- attack range in studs
		HP       = 85,
		MOVE_SPD = 14,

		-- Attack info
		AttackType   = "Hybrid",
		AttackName   = "C-310 MENDOR",
		AttackDesc   = "Fires 8-bullet bursts (0.125× ATK each). ATK: damages enemy. SUPP: heals ally tower. At 40 charge: Nano Blast (2× AP laser).",
		DamageMulti  = 1.0,
	},

	Wanderer = {
		ATK      = 18,    -- drone Heavy Rounds: 0.5× ATK × 2 shots = 1.0× per trigger
		AP       = 20,    -- High Caliber during Recon: 1.5× ATK
		ATK_SPD  = 0.8,   -- drone attack triggers per second
		RNG      = 35,    -- drone movement range AND attack range
		HP       = 85,
		MOVE_SPD = 20,    -- drone travel speed (studs/s)

		-- Attack info
		AttackType   = "Ranged",
		AttackName   = "HEAVY ROUNDS",
		AttackDesc   = "Drone fires bursts of 2 (0.5× ATK each). During Reconnaissance: Wanderer fires High Caliber (1.5× ATK).",
		DamageMulti  = 1.0,
	},
}

return TowerStats