--[[
	DamageIndicator (ModuleScript)
	Place in ReplicatedStorage/

	Shared configuration for damage indicator colours and sizes.
]]

local DamageIndicator = {}

-- Colour categories
DamageIndicator.Colours = {
	Normal   = Color3.fromRGB(255, 255, 255),   -- white  – standard hit
	Critical = Color3.fromRGB(255, 220,  40),   -- yellow – crit / Headhunter
	Heal     = Color3.fromRGB(100, 255, 120),   -- green  – Vitalist heal
	Enemy    = Color3.fromRGB(255,  60,  60),   -- red    – enemy hits tower
	Nano     = Color3.fromRGB(120, 200, 255),   -- blue   – Nano Blast
}

-- Behaviour tweaks
DamageIndicator.FLOAT_HEIGHT   = 5    -- studs the label floats upward
DamageIndicator.FLOAT_TIME     = 1.2  -- seconds the indicator lives
DamageIndicator.FONT_SIZE_BASE = 22   -- base TextLabel size
DamageIndicator.FONT_SIZE_CRIT = 30   -- enlarged size for crits / specials

return DamageIndicator