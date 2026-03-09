	

local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player           = Players.LocalPlayer
local playerGui        = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TowerHUD"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local hint = Instance.new("TextLabel")
hint.Name = "PlacementHint"
hint.Size = UDim2.new(0, 350, 0, 36)
hint.Position = UDim2.new(0.5, -175, 1, -50)
hint.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
hint.BackgroundTransparency = 0.3
hint.BorderSizePixel = 0
hint.Text = ""
hint.TextColor3 = Color3.fromRGB(220, 220, 220)
hint.TextScaled = true
hint.Font = Enum.Font.SourceSans
hint.Parent = screenGui

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(80, 120, 200)
stroke.Thickness = 1
stroke.Parent = hint

-- ── Deadeye info card ──────────────────────────────────────────────────────

-- Pull live stats from TowerStats if available; fall back to hard-coded values
local deadeyeStats = { ATK = 12, AP = 15, ATK_SPD = 1.0, RNG = 22 }
local ok, TowerStats = pcall(function()
	return require(ReplicatedStorage:WaitForChild("TowerStats", 5))
end)
if ok and TowerStats and TowerStats.Templates and TowerStats.Templates.Deadeye then
	local t = TowerStats.Templates.Deadeye
	deadeyeStats.ATK     = t.ATK     or deadeyeStats.ATK
	deadeyeStats.AP      = t.AP      or deadeyeStats.AP
	deadeyeStats.ATK_SPD = t.ATK_SPD or deadeyeStats.ATK_SPD
	deadeyeStats.RNG     = t.RNG     or deadeyeStats.RNG
else
	warn("[TowerHUD] TowerStats not found – Deadeye card will use hard-coded stat values.")
end

-- Outer card frame
local card = Instance.new("Frame")
card.Name             = "DeadeyeCard"
card.Size             = UDim2.new(0, 260, 0, 210)
card.Position         = UDim2.new(0, 12, 1, -222)
card.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
card.BackgroundTransparency = 0.15
card.BorderSizePixel  = 0
card.Parent           = screenGui

local cardStroke = Instance.new("UIStroke")
cardStroke.Color     = Color3.fromRGB(80, 120, 200)
cardStroke.Thickness = 2
cardStroke.Parent    = card

local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0, 6)
cardCorner.Parent       = card

-- Portrait image
local portrait = Instance.new("ImageLabel")
portrait.Name             = "Portrait"
portrait.Size             = UDim2.new(0, 72, 0, 72)
portrait.Position         = UDim2.new(0, 10, 0, 10)
portrait.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
portrait.BackgroundTransparency = 0
portrait.BorderSizePixel  = 0
portrait.Image            = "rbxassetid://0"   -- placeholder; swap with real portrait asset
portrait.ScaleType        = Enum.ScaleType.Fit
portrait.Parent           = card

local portraitStroke = Instance.new("UIStroke")
portraitStroke.Color     = Color3.fromRGB(80, 120, 200)
portraitStroke.Thickness = 1
portraitStroke.Parent    = portrait

local portraitCorner = Instance.new("UICorner")
portraitCorner.CornerRadius = UDim.new(0, 4)
portraitCorner.Parent       = portrait

-- Tower name
local nameLabel = Instance.new("TextLabel")
nameLabel.Name             = "TowerName"
nameLabel.Size             = UDim2.new(0, 160, 0, 26)
nameLabel.Position         = UDim2.new(0, 92, 0, 10)
nameLabel.BackgroundTransparency = 1
nameLabel.Text             = "DEADEYE"
nameLabel.TextColor3       = Color3.fromRGB(220, 220, 220)
nameLabel.Font             = Enum.Font.GothamBold
nameLabel.TextSize         = 18
nameLabel.TextXAlignment   = Enum.TextXAlignment.Left
nameLabel.Parent           = card

-- Attack type badge
local typeLabel = Instance.new("TextLabel")
typeLabel.Name             = "AttackType"
typeLabel.Size             = UDim2.new(0, 80, 0, 20)
typeLabel.Position         = UDim2.new(0, 92, 0, 38)
typeLabel.BackgroundColor3 = Color3.fromRGB(40, 60, 120)
typeLabel.BackgroundTransparency = 0
typeLabel.BorderSizePixel  = 0
typeLabel.Text             = "Ranged"
typeLabel.TextColor3       = Color3.fromRGB(160, 190, 255)
typeLabel.Font             = Enum.Font.GothamSemibold
typeLabel.TextSize         = 12
typeLabel.TextXAlignment   = Enum.TextXAlignment.Center
typeLabel.Parent           = card

local typeCorner = Instance.new("UICorner")
typeCorner.CornerRadius = UDim.new(0, 4)
typeCorner.Parent       = typeLabel

-- Key hint badge
local dKeyHint = Instance.new("TextLabel")
dKeyHint.Name             = "KeyHint"
dKeyHint.Size             = UDim2.new(0, 28, 0, 20)
dKeyHint.Position         = UDim2.new(0, 177, 0, 38)
dKeyHint.BackgroundColor3 = Color3.fromRGB(30, 40, 70)
dKeyHint.BackgroundTransparency = 0
dKeyHint.BorderSizePixel  = 0
dKeyHint.Text             = "[T]"
dKeyHint.TextColor3       = Color3.fromRGB(160, 190, 255)
dKeyHint.Font             = Enum.Font.GothamBold
dKeyHint.TextSize         = 11
dKeyHint.TextXAlignment   = Enum.TextXAlignment.Center
dKeyHint.Parent           = card

local dKeyCorner = Instance.new("UICorner")
dKeyCorner.CornerRadius = UDim.new(0, 4)
dKeyCorner.Parent       = dKeyHint

-- Stats row (ATK / AP / ATK_SPD / RNG)
local statsData = {
	{ label = "ATK",     value = tostring(deadeyeStats.ATK)     },
	{ label = "AP",      value = tostring(deadeyeStats.AP)      },
	{ label = "ATK_SPD", value = tostring(deadeyeStats.ATK_SPD) },
	{ label = "RNG",     value = tostring(deadeyeStats.RNG)     },
}

local statsRow = Instance.new("Frame")
statsRow.Name             = "StatsRow"
statsRow.Size             = UDim2.new(1, -20, 0, 50)
statsRow.Position         = UDim2.new(0, 10, 0, 90)
statsRow.BackgroundTransparency = 1
statsRow.BorderSizePixel  = 0
statsRow.Parent           = card

local statsLayout = Instance.new("UIListLayout")
statsLayout.FillDirection  = Enum.FillDirection.Horizontal
statsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
statsLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
statsLayout.Padding        = UDim.new(0, 6)
statsLayout.Parent         = statsRow

for _, s in ipairs(statsData) do
	local cell = Instance.new("Frame")
	cell.Size             = UDim2.new(0, 54, 1, 0)
	cell.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
	cell.BackgroundTransparency = 0
	cell.BorderSizePixel  = 0
	cell.Parent           = statsRow

	local cellCorner = Instance.new("UICorner")
	cellCorner.CornerRadius = UDim.new(0, 4)
	cellCorner.Parent       = cell

	local valLbl = Instance.new("TextLabel")
	valLbl.Size             = UDim2.new(1, 0, 0.55, 0)
	valLbl.Position         = UDim2.new(0, 0, 0, 0)
	valLbl.BackgroundTransparency = 1
	valLbl.Text             = s.value
	valLbl.TextColor3       = Color3.fromRGB(220, 220, 220)
	valLbl.Font             = Enum.Font.GothamBold
	valLbl.TextSize         = 14
	valLbl.TextXAlignment   = Enum.TextXAlignment.Center
	valLbl.Parent           = cell

	local keyLbl = Instance.new("TextLabel")
	keyLbl.Size             = UDim2.new(1, 0, 0.45, 0)
	keyLbl.Position         = UDim2.new(0, 0, 0.55, 0)
	keyLbl.BackgroundTransparency = 1
	keyLbl.Text             = s.label
	keyLbl.TextColor3       = Color3.fromRGB(130, 150, 200)
	keyLbl.Font             = Enum.Font.Gotham
	keyLbl.TextSize         = 10
	keyLbl.TextXAlignment   = Enum.TextXAlignment.Center
	keyLbl.Parent           = cell
end

-- Description
local descLabel = Instance.new("TextLabel")
descLabel.Name             = "Description"
descLabel.Size             = UDim2.new(1, -20, 0, 56)
descLabel.Position         = UDim2.new(0, 10, 0, 148)
descLabel.BackgroundTransparency = 1
descLabel.Text             = "Ranged Eco tower. Revolver: 1× ATK. Enhanced: Headhunter (1× AP, executes below 25% HP)."
descLabel.TextColor3       = Color3.fromRGB(170, 170, 185)
descLabel.Font             = Enum.Font.SourceSans
descLabel.TextSize         = 12
descLabel.TextWrapped      = true
descLabel.TextXAlignment   = Enum.TextXAlignment.Left
descLabel.TextYAlignment   = Enum.TextYAlignment.Top
descLabel.Parent           = card

-- ── Vitalist info card ─────────────────────────────────────────────────────

local vitalistStats = { ATK = 12, AP = 18, ATK_SPD = 1.2, RNG = 20 }
if ok and TowerStats and TowerStats.Templates and TowerStats.Templates.Vitalist then
	local t = TowerStats.Templates.Vitalist
	vitalistStats.ATK     = t.ATK     or vitalistStats.ATK
	vitalistStats.AP      = t.AP      or vitalistStats.AP
	vitalistStats.ATK_SPD = t.ATK_SPD or vitalistStats.ATK_SPD
	vitalistStats.RNG     = t.RNG     or vitalistStats.RNG
end

local vCard = Instance.new("Frame")
vCard.Name             = "VitalistCard"
vCard.Size             = UDim2.new(0, 260, 0, 220)
vCard.Position         = UDim2.new(0, 12, 1, -448)  -- stacked above the Deadeye card
vCard.BackgroundColor3 = Color3.fromRGB(20, 30, 25)
vCard.BackgroundTransparency = 0.15
vCard.BorderSizePixel  = 0
vCard.Parent           = screenGui

local vCardStroke = Instance.new("UIStroke")
vCardStroke.Color     = Color3.fromRGB(50, 200, 90)
vCardStroke.Thickness = 2
vCardStroke.Parent    = vCard

local vCardCorner = Instance.new("UICorner")
vCardCorner.CornerRadius = UDim.new(0, 6)
vCardCorner.Parent       = vCard

-- Portrait
local vPortrait = Instance.new("ImageLabel")
vPortrait.Name             = "Portrait"
vPortrait.Size             = UDim2.new(0, 72, 0, 72)
vPortrait.Position         = UDim2.new(0, 10, 0, 10)
vPortrait.BackgroundColor3 = Color3.fromRGB(10, 20, 15)
vPortrait.BackgroundTransparency = 0
vPortrait.BorderSizePixel  = 0
vPortrait.Image            = "rbxassetid://0"
vPortrait.ScaleType        = Enum.ScaleType.Fit
vPortrait.Parent           = vCard

local vPortraitStroke = Instance.new("UIStroke")
vPortraitStroke.Color     = Color3.fromRGB(50, 200, 90)
vPortraitStroke.Thickness = 1
vPortraitStroke.Parent    = vPortrait

local vPortraitCorner = Instance.new("UICorner")
vPortraitCorner.CornerRadius = UDim.new(0, 4)
vPortraitCorner.Parent       = vPortrait

-- Tower name
local vName = Instance.new("TextLabel")
vName.Name             = "TowerName"
vName.Size             = UDim2.new(0, 160, 0, 26)
vName.Position         = UDim2.new(0, 92, 0, 10)
vName.BackgroundTransparency = 1
vName.Text             = "VITALIST"
vName.TextColor3       = Color3.fromRGB(220, 255, 220)
vName.Font             = Enum.Font.GothamBold
vName.TextSize         = 18
vName.TextXAlignment   = Enum.TextXAlignment.Left
vName.Parent           = vCard

-- Type badge
local vType = Instance.new("TextLabel")
vType.Name             = "AttackType"
vType.Size             = UDim2.new(0, 80, 0, 20)
vType.Position         = UDim2.new(0, 92, 0, 38)
vType.BackgroundColor3 = Color3.fromRGB(25, 60, 35)
vType.BackgroundTransparency = 0
vType.BorderSizePixel  = 0
vType.Text             = "Hybrid"
vType.TextColor3       = Color3.fromRGB(100, 220, 130)
vType.Font             = Enum.Font.GothamSemibold
vType.TextSize         = 12
vType.TextXAlignment   = Enum.TextXAlignment.Center
vType.Parent           = vCard

local vTypeCorner = Instance.new("UICorner")
vTypeCorner.CornerRadius = UDim.new(0, 4)
vTypeCorner.Parent       = vType

-- Key hint badge
local vKeyHint = Instance.new("TextLabel")
vKeyHint.Name             = "KeyHint"
vKeyHint.Size             = UDim2.new(0, 28, 0, 20)
vKeyHint.Position         = UDim2.new(0, 177, 0, 38)
vKeyHint.BackgroundColor3 = Color3.fromRGB(40, 60, 40)
vKeyHint.BackgroundTransparency = 0
vKeyHint.BorderSizePixel  = 0
vKeyHint.Text             = "[Y]"
vKeyHint.TextColor3       = Color3.fromRGB(180, 240, 180)
vKeyHint.Font             = Enum.Font.GothamBold
vKeyHint.TextSize         = 11
vKeyHint.TextXAlignment   = Enum.TextXAlignment.Center
vKeyHint.Parent           = vCard

local vKeyCorner = Instance.new("UICorner")
vKeyCorner.CornerRadius = UDim.new(0, 4)
vKeyCorner.Parent       = vKeyHint

-- Stats row
local vStatsData = {
	{ label = "ATK",     value = tostring(vitalistStats.ATK)     },
	{ label = "AP",      value = tostring(vitalistStats.AP)      },
	{ label = "ATK_SPD", value = tostring(vitalistStats.ATK_SPD) },
	{ label = "RNG",     value = tostring(vitalistStats.RNG)     },
}

local vStatsRow = Instance.new("Frame")
vStatsRow.Name             = "StatsRow"
vStatsRow.Size             = UDim2.new(1, -20, 0, 50)
vStatsRow.Position         = UDim2.new(0, 10, 0, 90)
vStatsRow.BackgroundTransparency = 1
vStatsRow.BorderSizePixel  = 0
vStatsRow.Parent           = vCard

local vStatsLayout = Instance.new("UIListLayout")
vStatsLayout.FillDirection  = Enum.FillDirection.Horizontal
vStatsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
vStatsLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
vStatsLayout.Padding        = UDim.new(0, 6)
vStatsLayout.Parent         = vStatsRow

for _, s in ipairs(vStatsData) do
	local cell = Instance.new("Frame")
	cell.Size             = UDim2.new(0, 54, 1, 0)
	cell.BackgroundColor3 = Color3.fromRGB(25, 40, 28)
	cell.BackgroundTransparency = 0
	cell.BorderSizePixel  = 0
	cell.Parent           = vStatsRow

	local cellCorner = Instance.new("UICorner")
	cellCorner.CornerRadius = UDim.new(0, 4)
	cellCorner.Parent       = cell

	local valLbl = Instance.new("TextLabel")
	valLbl.Size             = UDim2.new(1, 0, 0.55, 0)
	valLbl.Position         = UDim2.new(0, 0, 0, 0)
	valLbl.BackgroundTransparency = 1
	valLbl.Text             = s.value
	valLbl.TextColor3       = Color3.fromRGB(200, 255, 200)
	valLbl.Font             = Enum.Font.GothamBold
	valLbl.TextSize         = 14
	valLbl.TextXAlignment   = Enum.TextXAlignment.Center
	valLbl.Parent           = cell

	local keyLbl = Instance.new("TextLabel")
	keyLbl.Size             = UDim2.new(1, 0, 0.45, 0)
	keyLbl.Position         = UDim2.new(0, 0, 0.55, 0)
	keyLbl.BackgroundTransparency = 1
	keyLbl.Text             = s.label
	keyLbl.TextColor3       = Color3.fromRGB(100, 180, 110)
	keyLbl.Font             = Enum.Font.Gotham
	keyLbl.TextSize         = 10
	keyLbl.TextXAlignment   = Enum.TextXAlignment.Center
	keyLbl.Parent           = cell
end

-- Description
local vDesc = Instance.new("TextLabel")
vDesc.Name             = "Description"
vDesc.Size             = UDim2.new(1, -20, 0, 66)
vDesc.Position         = UDim2.new(0, 10, 0, 148)
vDesc.BackgroundTransparency = 1
vDesc.Text             = "Hybrid Medic. ATK: 8-bullet bursts (0.125× ATK ea., blue laser). SUPP: heals ally towers. 40 charge → Nano Blast (2× AP). Move ≤8 studs → switch protocol."
vDesc.TextColor3       = Color3.fromRGB(160, 210, 170)
vDesc.Font             = Enum.Font.SourceSans
vDesc.TextSize         = 11
vDesc.TextWrapped      = true
vDesc.TextXAlignment   = Enum.TextXAlignment.Left
vDesc.TextYAlignment   = Enum.TextYAlignment.Top
vDesc.Parent           = vCard
