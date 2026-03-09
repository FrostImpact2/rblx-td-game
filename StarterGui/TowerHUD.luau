

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
ww