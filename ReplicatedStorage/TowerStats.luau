--[[
TowerStats (ModuleScript)
Place in ReplicatedStorage

Defines tower templates and stat resolution.
All core combat stats are integer based.
ATK_SPD is attack delay in seconds (lower is better).
]]

local TowerStats = {}

TowerStats.Templates = {
Warrior = {
ATK      = 10,
DEF      = 3,
ATK_SPD  = 1,
RNG      = 8,
HP       = 100,
MOVE_SPD = 16,

AttackType   = "Melee",
AttackName   = "CLEAVE",
AttackDesc   = "Slash at the enemy, dealing 100% ATK to a single target.",
DamageMulti  = 1.0,
},

Deadeye = {
ATK      = 12,
DEF      = 1,
AP       = 15,
ATK_SPD  = 1,
RNG      = 30,
HP       = 75,
MOVE_SPD = 14,

AttackType   = "Ranged",
AttackName   = "REVOLVER",
AttackDesc   = "Shoot the enemy, dealing 1× ATK to a single target. Enhances basic attack after 2 usages.",
DamageMulti  = 1.0,
},

Vitalist = {
ATK      = 12,
DEF      = 1,
AP       = 18,
ATK_SPD  = 1,
RNG      = 20,
HP       = 85,
MOVE_SPD = 14,

AttackType   = "Hybrid",
AttackName   = "C-310 MENDOR",
AttackDesc   = "Fires 8-bullet bursts (0.125× ATK each). ATK: damages enemy. SUPP: heals ally tower. At 40 charge: Nano Blast (2× AP laser).",
DamageMulti  = 1.0,
},

Wanderer = {
ATK      = 18,
DEF      = 1,
AP       = 20,
ATK_SPD  = 2,
RNG      = 60,
HP       = 85,
MOVE_SPD = 20,

AttackType   = "Ranged",
AttackName   = "HEAVY ROUNDS",
AttackDesc   = "Drone fires bursts of 2 (0.5× ATK each). During Reconnaissance: Wanderer fires High Caliber (1.5× ATK).",
DamageMulti  = 1.0,
},

Pathfinder = {
ATK      = 14,
DEF      = 2,
ATK_SPD  = 2,
RNG      = 20,
HP       = 85,
MOVE_SPD = 16,

AttackType   = "Zone",
AttackName   = "RECLAMATION",
AttackDesc   = "Cannot attack normally. After placing 4 Waypoints, pulls all souls through waypoints dealing 1× ATK per leg (+0.25× per waypoint passed).",
DamageMulti  = 1.0,
},
}

return TowerStats
