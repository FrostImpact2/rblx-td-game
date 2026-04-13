--[[
LobbyGui (LocalScript)
Place in StarterGui/

Implements all three main out-of-round GUIs:
  • INVENTORY  – tower/equipment viewer and shop
  • QUESTS     – daily / weekly / challenge quest tabs
  • GACHA      – standard and special banner pull system

Clean white card-based layout with bold navigation bar,
matching the reference image style. High-resolution text
and generous spacing for readability.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TowerData = require(ReplicatedStorage:WaitForChild("TowerData", 30))

-- ============================================================
-- REMOTES
-- ============================================================

local updateCurrencyRemote = ReplicatedStorage:WaitForChild("UpdateCurrency",    30)
local gachaPullRemote      = ReplicatedStorage:WaitForChild("GachaPull",         30)
local gachaResultRemote    = ReplicatedStorage:WaitForChild("GachaResult",       30)
local toggleStateRemote    = ReplicatedStorage:WaitForChild("ToggleGameState",   30)
local gameStateChanged     = ReplicatedStorage:WaitForChild("GameStateChanged",  30)
local gameStateValue       = ReplicatedStorage:WaitForChild("GameState",         30)
local loadoutConfigRemote  = ReplicatedStorage:WaitForChild("LoadoutConfigRequest", 30)
local loadoutUpdatedRemote = ReplicatedStorage:WaitForChild("LoadoutConfigUpdated", 30)

-- ============================================================
-- LOCAL STATE
-- ============================================================

local localCoins      = 0
local localGems       = 0
local activeBanner    = "standard"
local activePanel     = nil
local unlockedTowers  = { Warrior = true }
local ownedEquipment  = {}
local currentLoadout  = { "Warrior" }
local equippedByTower = {}
local selectedTower   = nil
local activeQuestTab  = "Daily"
local panelOpen       = false

-- ============================================================
-- COLOUR PALETTE  (matches reference: crisp white, bold accents)
-- ============================================================

local C = {
	-- Grayscale hierarchy (light → dark, no pure white anywhere)
	-- G1 is the lightest "almost white" used for main panels
	-- G5 is the darkest used for the nav bar / dark tiles
	G1          = Color3.fromRGB(238, 239, 244),   -- lightest: main panel face
	G2          = Color3.fromRGB(224, 226, 234),   -- card surfaces, nav bar
	G3          = Color3.fromRGB(210, 212, 223),   -- secondary boxes, pill bg
	G4          = Color3.fromRGB(192, 195, 210),   -- input/desc boxes, progress bg
	G5          = Color3.fromRGB(168, 172, 192),   -- darker elements, claim btn
	G6          = Color3.fromRGB(130, 135, 158),   -- deepest gray surface

	-- Aliases (used throughout code for semantic clarity)
	BG          = Color3.fromRGB(210, 212, 223),   -- page background = G3
	PANEL       = Color3.fromRGB(238, 239, 244),   -- main card face = G1
	PANEL2      = Color3.fromRGB(224, 226, 234),   -- secondary card = G2
	GRAY        = Color3.fromRGB(210, 212, 223),   -- boxes/inputs = G3
	GRAY_DARK   = Color3.fromRGB(192, 195, 210),   -- darker gray boxes = G4
	STATUS_BG   = Color3.fromRGB(210, 212, 223),   -- currency pill bg = G3

	-- Borders & dividers
	BORDER      = Color3.fromRGB(185, 188, 205),
	DIVIDER     = Color3.fromRGB(200, 203, 216),

	-- Accents (kept vivid so they pop against the gray scale)
	ACCENT      = Color3.fromRGB(255, 88, 100),    -- coral/red
	ACCENT2     = Color3.fromRGB(80, 140, 255),    -- blue
	GREEN       = Color3.fromRGB(52, 199, 105),
	RED         = Color3.fromRGB(220, 60, 70),
	GOLD        = Color3.fromRGB(235, 165, 20),
	GEM         = Color3.fromRGB(130, 80, 255),
	ORANGE      = Color3.fromRGB(255, 140, 60),

	-- Text (dark on light gray reads well)
	TEXT        = Color3.fromRGB(28, 30, 42),
	TEXTSUB     = Color3.fromRGB(78, 82, 108),
	TEXTDIM     = Color3.fromRGB(140, 144, 168),
	WHITE       = Color3.fromRGB(245, 246, 250),   -- "white" text = very light gray
	BLACK       = Color3.fromRGB(0,   0,   0),

	-- Tile colours
	TILE_WHITE  = Color3.fromRGB(238, 239, 244),   -- G1 instead of pure white
	TILE_CORAL  = Color3.fromRGB(255, 160, 130),
	TILE_PEACH  = Color3.fromRGB(255, 200, 170),
	TILE_DARK   = Color3.fromRGB(48,  50,  66),    -- dark tile
	TILE_BLUE   = Color3.fromRGB(210, 222, 245),
}

local PANEL_ROTATION = -1.5

local CAMERA_OFFSET        = Vector3.new(6, 4, 10)
local CAMERA_LOOKAT_OFFSET = Vector3.new(0, 2, 0)

-- ============================================================
-- ROOT SCREEN GUI
-- ============================================================

local screenGui              = Instance.new("ScreenGui")
screenGui.Name               = "LobbyGui"
screenGui.ResetOnSpawn       = false
screenGui.ZIndexBehavior     = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset     = true
screenGui.Parent             = playerGui

-- ============================================================
-- HELPER UTILITIES
-- ============================================================

local function makeCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
end

local function makeStroke(parent, color, thickness, trans)
	local s = Instance.new("UIStroke")
	s.Color = color or C.BORDER
	s.Thickness = thickness or 1
	s.Transparency = trans or 0
	s.Parent = parent
	return s
end

local function makeShadow(parent)
	-- Simulate a soft drop shadow using a slightly larger dark frame behind
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.new(1, 8, 1, 8)
	shadow.Position = UDim2.new(0, -4, 0, 4)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.88
	shadow.BorderSizePixel = 0
	shadow.ZIndex = parent.ZIndex - 1
	shadow.Parent = parent.Parent
	makeCorner(shadow, 12)
	shadow.Parent = parent
	return shadow
end

local function makeLabel(parent, text, size, pos, textColor, bgColor, bgTrans)
	local f = Instance.new("TextLabel")
	f.Size = size
	f.Position = pos or UDim2.new(0,0,0,0)
	f.BackgroundColor3 = bgColor or C.G1
	f.BackgroundTransparency = bgTrans ~= nil and bgTrans or 1
	f.BorderSizePixel = 0
	f.Text = text
	f.TextColor3 = textColor or C.TEXT
	f.Font = Enum.Font.GothamBold
	f.TextScaled = false
	f.TextSize = 17          -- high-res readable size
	f.TextXAlignment = Enum.TextXAlignment.Left
	f.Parent = parent
	return f
end

local function makeButton(parent, text, size, pos, bg, textColor)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = pos or UDim2.new(0,0,0,0)
	b.BackgroundColor3 = bg or C.ACCENT
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = textColor or C.WHITE
	b.Font = Enum.Font.GothamBold
	b.TextSize = 17
	b.AutoButtonColor = true
	b.Parent = parent
	return b
end

local function makeDivider(parent, horizontal)
	local d = Instance.new("Frame")
	if horizontal then
		d.Size = UDim2.new(1, 0, 0, 1)
	else
		d.Size = UDim2.new(0, 1, 1, 0)
	end
	d.BackgroundColor3 = C.DIVIDER
	d.BackgroundTransparency = 0
	d.BorderSizePixel = 0
	d.Parent = parent
	return d
end

local function rarityColor(rarityKey: string): Color3
	local r = TowerData.Rarity[rarityKey]
	return r and r.color or C.TEXT
end

local function rarityStars(rarityKey: string): string
	local r = TowerData.Rarity[rarityKey]
	local n = r and r.stars or 1
	if n <= 5 then
		return string.rep("★", n) .. string.rep("☆", 5 - n)
	end
	return string.rep("★", n)
end

local refreshLoadoutViews = function() end

local function applyProfileSnapshot(snapshot: table?)
	if type(snapshot) ~= "table" then return end

	if type(snapshot.unlocked) == "table" then
		unlockedTowers = table.clone(snapshot.unlocked)
	end
	if type(snapshot.equipment) == "table" then
		ownedEquipment = table.clone(snapshot.equipment)
	end
	if type(snapshot.loadout) == "table" and #snapshot.loadout > 0 then
		currentLoadout = {}
		for _, towerName in ipairs(snapshot.loadout) do
			if type(towerName) == "string" then
				table.insert(currentLoadout, towerName)
			end
		end
	end
	if #currentLoadout == 0 then
		currentLoadout = { "Warrior" }
	end
	if type(snapshot.equipped) == "table" then
		equippedByTower = {}
		for towerName, list in pairs(snapshot.equipped) do
			if type(list) == "table" then
				equippedByTower[towerName] = table.clone(list)
			end
		end
	end
	refreshLoadoutViews()
end

local function requestProfile(action: string, payload: table?): table?
	local ok, response = pcall(function()
		return loadoutConfigRemote:InvokeServer(action, payload or {})
	end)
	if not ok or type(response) ~= "table" then
		return nil
	end
	if response.data then
		applyProfileSnapshot(response.data)
	end
	return response
end

-- ============================================================
-- MAIN FLOATING PANEL
-- ============================================================

local PANEL_W = 0.90
local PANEL_H = 0.76

local mainPanel              = Instance.new("Frame")
mainPanel.Name               = "MainPanel"
mainPanel.Size               = UDim2.new(PANEL_W, 0, PANEL_H, 0)
mainPanel.AnchorPoint        = Vector2.new(0.5, 0.5)
mainPanel.Position           = UDim2.new(0.5, 0, 1.5, 0)
mainPanel.BackgroundColor3   = C.BG
mainPanel.BackgroundTransparency = 0
mainPanel.BorderSizePixel    = 0
mainPanel.ClipsDescendants   = true
mainPanel.Rotation           = PANEL_ROTATION
mainPanel.ZIndex             = 5
mainPanel.Parent             = screenGui
makeCorner(mainPanel, 10)
makeStroke(mainPanel, C.BORDER, 1, 0)

-- ============================================================
-- NAV BAR  (white bar, bold segmented tabs like reference image)
-- ============================================================

local NAV_HEIGHT = 60

local navBar              = Instance.new("Frame")
navBar.Name               = "NavBar"
navBar.Size               = UDim2.new(1, 0, 0, NAV_HEIGHT)
navBar.Position           = UDim2.new(0, 0, 0, 0)
navBar.BackgroundColor3   = C.G2
navBar.BorderSizePixel    = 0
navBar.ZIndex             = 10
navBar.Parent             = mainPanel

-- Bottom border on nav bar
local navBorder = makeDivider(navBar, true)
navBorder.Position = UDim2.new(0, 0, 1, -1)
navBorder.BackgroundColor3 = C.BORDER
navBorder.BackgroundTransparency = 0

-- ── Currency / status area (right side) ─────────────────────

local statusArea        = Instance.new("Frame")
statusArea.Size         = UDim2.new(0, 420, 0, 42)
statusArea.Position     = UDim2.new(1, -432, 0.5, -21)
statusArea.BackgroundTransparency = 1
statusArea.BorderSizePixel = 0
statusArea.ZIndex       = 12
statusArea.Parent       = navBar

-- Helper: pill-shaped currency display
local function makeCurrencyPill(parent, xOffset, width, icon, color)
	local pill = Instance.new("Frame")
	pill.Size = UDim2.new(0, width, 0, 38)
	pill.Position = UDim2.new(0, xOffset, 0.5, -19)
	pill.BackgroundColor3 = C.GRAY
	pill.BorderSizePixel = 0
	pill.ZIndex = 13
	pill.Parent = parent
	makeCorner(pill, 7)
	makeStroke(pill, C.BORDER, 1, 0)

	local iconL = makeLabel(pill, icon,
		UDim2.new(0, 30, 1, 0), UDim2.new(0, 5, 0, 0),
		color, nil, 1)
	iconL.TextSize = 18
	iconL.TextXAlignment = Enum.TextXAlignment.Center
	iconL.ZIndex = 14

	local valL = makeLabel(pill, "0",
		UDim2.new(1, -38, 1, 0), UDim2.new(0, 36, 0, 0),
		C.TEXT, nil, 1)
	valL.Name = "Value"
	valL.TextSize = 16
	valL.Font = Enum.Font.GothamBold
	valL.TextXAlignment = Enum.TextXAlignment.Left
	valL.ZIndex = 14

	return valL
end

-- Level pill
local lvlPill = Instance.new("Frame")
lvlPill.Size = UDim2.new(0, 64, 0, 38)
lvlPill.Position = UDim2.new(0, 0, 0.5, -19)
lvlPill.BackgroundColor3 = C.ACCENT
lvlPill.BorderSizePixel = 0
lvlPill.ZIndex = 13
lvlPill.Parent = statusArea
makeCorner(lvlPill, 7)

local lvlLabel = makeLabel(lvlPill, "Lv 1",
	UDim2.new(1, 0, 1, 0), UDim2.new(0,0,0,0),
	C.WHITE, nil, 1)
lvlLabel.TextSize = 15
lvlLabel.TextXAlignment = Enum.TextXAlignment.Center
lvlLabel.ZIndex = 14

local coinsLabel = makeCurrencyPill(statusArea, 72,  124, "🪙", C.GOLD)
coinsLabel.Text = "1,000"
local gemsLabel  = makeCurrencyPill(statusArea, 204, 104,  "💎", C.GEM)
gemsLabel.Text = "50"

-- START / STOP toggle button (right-most, coral accent)
local toggleBtn = makeButton(navBar, "▶ START",
	UDim2.new(0, 108, 0, 40),
	UDim2.new(1, -120, 0.5, -20),
	C.GREEN, C.WHITE)
makeCorner(toggleBtn, 7)
toggleBtn.TextSize = 15
toggleBtn.ZIndex = 13

-- ============================================================
-- SEGMENTED NAVIGATION TABS  (match reference image style)
-- ============================================================

local tabButtons = {}

local TAB_DEFS = {
	{ key = "inventory", label = "INVENTORY", order = 1 },
	{ key = "quests",    label = "QUESTS",    order = 2 },
	{ key = "gacha",     label = "GACHA",     order = 3 },
}

-- Tabs live on the LEFT side of the nav bar, bold text style
local TAB_WIDTH  = 160
local TAB_STARTX = 0

for i, def in ipairs(TAB_DEFS) do
	local xPos = TAB_STARTX + (i - 1) * TAB_WIDTH

	local tabContainer              = Instance.new("Frame")
	tabContainer.Name               = "Tab_" .. def.key
	tabContainer.Size               = UDim2.new(0, TAB_WIDTH, 1, 0)
	tabContainer.Position           = UDim2.new(0, xPos, 0, 0)
	tabContainer.BackgroundColor3   = C.G1
	tabContainer.BackgroundTransparency = 1
	tabContainer.ClipsDescendants   = true
	tabContainer.BorderSizePixel    = 0
	tabContainer.ZIndex             = 11
	tabContainer.Parent             = navBar

	local tabBtn              = Instance.new("TextButton")
	tabBtn.Name               = "Button"
	tabBtn.Size               = UDim2.new(1, 0, 1, 0)
	tabBtn.BackgroundTransparency = 1
	tabBtn.BorderSizePixel    = 0
	tabBtn.Text               = ""
	tabBtn.AutoButtonColor    = false
	tabBtn.ZIndex             = 14
	tabBtn.Parent             = tabContainer

	local tabLabel            = Instance.new("TextLabel")
	tabLabel.Size             = UDim2.new(1, 0, 1, -4)
	tabLabel.Position         = UDim2.new(0, 0, 0, 2)
	tabLabel.BackgroundTransparency = 1
	tabLabel.Text             = def.label
	tabLabel.TextColor3       = C.TEXTSUB
	tabLabel.Font             = Enum.Font.GothamBold
	tabLabel.TextSize         = 17
	tabLabel.ZIndex           = 13
	tabLabel.Parent           = tabContainer

	-- Bold bottom accent line (like reference image active tab indicator)
	local activeBar              = Instance.new("Frame")
	activeBar.Name               = "ActiveBar"
	activeBar.Size               = UDim2.new(0.7, 0, 0, 4)
	activeBar.AnchorPoint        = Vector2.new(0.5, 1)
	activeBar.Position           = UDim2.new(0.5, 0, 1, 0)
	activeBar.BackgroundColor3   = C.ACCENT
	activeBar.BorderSizePixel    = 0
	activeBar.Visible            = false
	activeBar.ZIndex             = 15
	activeBar.Parent             = tabContainer
	makeCorner(activeBar, 2)

	-- Thin right-side divider between tabs
	if i < #TAB_DEFS then
		local vdiv            = Instance.new("Frame")
		vdiv.Size             = UDim2.new(0, 1, 0.45, 0)
		vdiv.Position         = UDim2.new(1, 0, 0.275, 0)
		vdiv.BackgroundColor3 = C.BORDER
		vdiv.BorderSizePixel  = 0
		vdiv.ZIndex           = 12
		vdiv.Parent           = tabContainer
	end

	tabButtons[def.key] = {
		container = tabContainer,
		button    = tabBtn,
		label     = tabLabel,
		indicator = activeBar,
	}
end

-- ============================================================
-- CONTENT AREA
-- ============================================================

local contentArea              = Instance.new("Frame")
contentArea.Name               = "ContentArea"
contentArea.Size               = UDim2.new(1, 0, 1, -NAV_HEIGHT)
contentArea.Position           = UDim2.new(0, 0, 0, NAV_HEIGHT)
contentArea.BackgroundColor3   = C.BG
contentArea.BackgroundTransparency = 0
contentArea.BorderSizePixel    = 0
contentArea.ClipsDescendants   = true
contentArea.ZIndex             = 5
contentArea.Parent             = mainPanel

-- ============================================================
-- ARROW TOGGLE BUTTON  (clean pill style)
-- ============================================================

local arrowBtn              = Instance.new("TextButton")
arrowBtn.Name               = "ArrowToggle"
arrowBtn.Size               = UDim2.new(0, 72, 0, 32)
arrowBtn.Position           = UDim2.new(0.5, -36, 1, -40)
arrowBtn.BackgroundColor3   = C.G2
arrowBtn.BorderSizePixel    = 0
arrowBtn.Text               = "▲"
arrowBtn.TextColor3         = C.TEXT
arrowBtn.Font               = Enum.Font.GothamBold
arrowBtn.TextSize           = 20
arrowBtn.AutoButtonColor    = true
arrowBtn.ZIndex             = 30
arrowBtn.Parent             = screenGui
makeCorner(arrowBtn, 10)
makeStroke(arrowBtn, C.BORDER, 1, 0)

-- ============================================================
-- HOME GRID PANEL  (card tiles matching reference image layout)
-- ============================================================

local GRID_PAD = 12

local homePanel              = Instance.new("Frame")
homePanel.Name               = "HomePanel"
homePanel.Size               = UDim2.new(1, 0, 1, 0)
homePanel.BackgroundTransparency = 1
homePanel.BorderSizePixel    = 0
homePanel.Visible            = false
homePanel.ZIndex             = 6
homePanel.Parent             = contentArea

local function makeTile(parent, size, pos, bgColor, title, subtitle, accentColor, zIdx)
	local tile              = Instance.new("Frame")
	tile.Size               = size
	tile.Position           = pos
	tile.BackgroundColor3   = bgColor or C.TILE_WHITE
	tile.BorderSizePixel    = 0
	tile.ZIndex             = zIdx or 7
	tile.Parent             = parent
	makeCorner(tile, 10)
	makeStroke(tile, C.BORDER, 1, 0)

	-- Top-left accent stripe (like reference image colored left edge)
	if accentColor then
		local stripe = Instance.new("Frame")
		stripe.Size = UDim2.new(0, 4, 1, 0)
		stripe.BackgroundColor3 = accentColor
		stripe.BorderSizePixel = 0
		stripe.ZIndex = (zIdx or 7) + 1
		stripe.Parent = tile
		makeCorner(stripe, 3)
	end

	local titleOffset = accentColor and 14 or 10

	local titleL = makeLabel(tile, title or "",
		UDim2.new(1, -(titleOffset + 10), 0, 30),
		UDim2.new(0, titleOffset, 0, 14),
		C.TEXT, nil, 1)
	titleL.TextSize = 20
	titleL.Font = Enum.Font.GothamBold
	titleL.ZIndex = (zIdx or 7) + 2

	if subtitle then
		local subL = makeLabel(tile, subtitle,
			UDim2.new(1, -(titleOffset + 10), 0, 22),
			UDim2.new(0, titleOffset, 0, 46),
			C.TEXTSUB, nil, 1)
		subL.TextSize = 14
		subL.Font = Enum.Font.Gotham
		subL.TextWrapped = true
		subL.ZIndex = (zIdx or 7) + 2
	end

	local btn              = Instance.new("TextButton")
	btn.Size               = UDim2.new(1, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.Text               = ""
	btn.ZIndex             = (zIdx or 7) + 3
	btn.Parent             = tile

	return tile, btn
end

-- Top row: two tiles
local invTile, invTileBtn = makeTile(homePanel,
	UDim2.new(0.55, -GRID_PAD, 0.50, -GRID_PAD * 0.5),
	UDim2.new(0, GRID_PAD, 0, GRID_PAD),
	C.TILE_WHITE,
	"INVENTORY",
	"Browse towers, view stats & equipment",
	C.ACCENT2, 7)

-- Coral/gradient right tile (LIMITED TIME OFFERS — matches reference)
local gachaTile, gachaTileBtn = makeTile(homePanel,
	UDim2.new(0.45, -GRID_PAD, 0.50, -GRID_PAD * 0.5),
	UDim2.new(0.55, 0, 0, GRID_PAD),
	C.TILE_CORAL,
	"LIMITED TIME OFFERS!",
	"Summon new towers – Special banner active",
	nil, 7)

local gachaGrad = Instance.new("UIGradient")
gachaGrad.Color = ColorSequence.new(C.TILE_PEACH, C.TILE_CORAL)
gachaGrad.Rotation = 135
gachaGrad.Parent = gachaTile

-- Sale badge on the gacha tile (reference image has "SUMMER SALE!" badge)
local saleBadge = Instance.new("Frame")
saleBadge.Size = UDim2.new(0, 120, 0, 24)
saleBadge.Position = UDim2.new(0, 10, 0, 66)
saleBadge.BackgroundColor3 = C.ACCENT
saleBadge.BorderSizePixel = 0
saleBadge.ZIndex = 10
saleBadge.Parent = gachaTile
makeCorner(saleBadge, 4)

local saleLbl = makeLabel(saleBadge, "Very Cool",
	UDim2.new(1, -8, 1, 0), UDim2.new(0, 4, 0, 0),
	C.WHITE, nil, 1)
saleLbl.TextSize = 14
saleLbl.TextXAlignment = Enum.TextXAlignment.Center
saleLbl.ZIndex = 11

-- Bottom row: three tiles
local bottomY = UDim.new(0.50, GRID_PAD * 0.5)
local bottomH = UDim.new(0.50, -GRID_PAD * 1.5)
local tileW   = UDim.new(1/3, -GRID_PAD * 1.1)

local dailyTile, dailyTileBtn = makeTile(homePanel,
	UDim2.new(tileW.Scale, tileW.Offset, bottomH.Scale, bottomH.Offset),
	UDim2.new(0, GRID_PAD, bottomY.Scale, bottomY.Offset),
	C.TILE_WHITE,
	"DAILY QUESTS",
	"Complete tasks for rewards",
	C.GREEN, 7)

local weeklyTile, weeklyTileBtn = makeTile(homePanel,
	UDim2.new(tileW.Scale, tileW.Offset, bottomH.Scale, bottomH.Offset),
	UDim2.new(1/3, GRID_PAD * 0.3, bottomY.Scale, bottomY.Offset),
	C.TILE_DARK,
	"WEEKLY QUESTS",
	"Bigger goals, bigger prizes",
	C.ACCENT, 7)

-- White text on dark tile
local weeklyChildren = weeklyTile:GetChildren()
for _, c in ipairs(weeklyChildren) do
	if c:IsA("TextLabel") then
		c.TextColor3 = c.TextSize >= 16 and C.WHITE or Color3.fromRGB(168, 170, 188)
	end
end

local challengeTile, challengeTileBtn = makeTile(homePanel,
	UDim2.new(tileW.Scale, tileW.Offset, bottomH.Scale, bottomH.Offset),
	UDim2.new(2/3, -GRID_PAD * 0.4, bottomY.Scale, bottomY.Offset),
	C.TILE_BLUE,
	"CHALLENGES",
	"Earn special equipment",
	C.ACCENT2, 7)

local loadoutHomeFrame = Instance.new("Frame")
loadoutHomeFrame.Name = "LoadoutPanel"
loadoutHomeFrame.Size = UDim2.new(1, -(GRID_PAD * 2), 0, 110)
loadoutHomeFrame.Position = UDim2.new(0, GRID_PAD, 1, -122)
loadoutHomeFrame.BackgroundColor3 = C.G2
loadoutHomeFrame.BorderSizePixel = 0
loadoutHomeFrame.ZIndex = 12
loadoutHomeFrame.Parent = homePanel
makeCorner(loadoutHomeFrame, 10)
makeStroke(loadoutHomeFrame, C.BORDER, 1, 0)

local loadoutHomeTitle = makeLabel(loadoutHomeFrame, "MATCH LOADOUT (Click slot to clear)",
	UDim2.new(1, -12, 0, 24),
	UDim2.new(0, 10, 0, 6),
	C.TEXTSUB, nil, 1)
loadoutHomeTitle.TextSize = 13
loadoutHomeTitle.ZIndex = 13

local loadoutHomeRow = Instance.new("Frame")
loadoutHomeRow.Size = UDim2.new(1, -16, 0, 68)
loadoutHomeRow.Position = UDim2.new(0, 8, 0, 32)
loadoutHomeRow.BackgroundTransparency = 1
loadoutHomeRow.BorderSizePixel = 0
loadoutHomeRow.ZIndex = 13
loadoutHomeRow.Parent = loadoutHomeFrame

local loadoutHomeLayout = Instance.new("UIListLayout")
loadoutHomeLayout.FillDirection = Enum.FillDirection.Horizontal
loadoutHomeLayout.VerticalAlignment = Enum.VerticalAlignment.Center
loadoutHomeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
loadoutHomeLayout.Padding = UDim.new(0, 8)
loadoutHomeLayout.Parent = loadoutHomeRow

local loadoutHomeSlots = {}

-- ============================================================
-- INVENTORY PANEL
-- ============================================================

local invPanel              = Instance.new("Frame")
invPanel.Name               = "InventoryPanel"
invPanel.Size               = UDim2.new(1, 0, 1, 0)
invPanel.BackgroundTransparency = 1
invPanel.BorderSizePixel    = 0
invPanel.Visible            = false
invPanel.ZIndex             = 6
invPanel.Parent             = contentArea

local towerListFrame              = Instance.new("Frame")
towerListFrame.Name               = "TowerList"
towerListFrame.Size               = UDim2.new(0, 220, 1, -16)
towerListFrame.Position           = UDim2.new(0, GRID_PAD, 0, GRID_PAD * 0.5)
towerListFrame.BackgroundColor3   = C.G2
towerListFrame.BorderSizePixel    = 0
towerListFrame.ClipsDescendants   = true
towerListFrame.ZIndex             = 7
towerListFrame.Parent             = invPanel
makeCorner(towerListFrame, 10)
makeStroke(towerListFrame, C.BORDER, 1, 0)

local towerListHeader = makeLabel(towerListFrame, "TOWERS",
	UDim2.new(1, 0, 0, 42),
	UDim2.new(0, 0, 0, 0),
	C.TEXTSUB, C.G3, 0)
towerListHeader.TextSize = 14
towerListHeader.TextXAlignment = Enum.TextXAlignment.Center
towerListHeader.ZIndex = 8
makeDivider(towerListHeader, true).Position = UDim2.new(0, 0, 1, 0)

local towerScrollFrame            = Instance.new("ScrollingFrame")
towerScrollFrame.Name             = "Scroll"
towerScrollFrame.Size             = UDim2.new(1, 0, 1, -42)
towerScrollFrame.Position         = UDim2.new(0, 0, 0, 42)
towerScrollFrame.BackgroundTransparency = 1
towerScrollFrame.BorderSizePixel  = 0
towerScrollFrame.ScrollBarThickness = 4
towerScrollFrame.ScrollBarImageColor3 = C.ACCENT
towerScrollFrame.CanvasSize       = UDim2.new(0, 0, 0, 0)
towerScrollFrame.ZIndex           = 8
towerScrollFrame.Parent           = towerListFrame

local towerScrollLayout           = Instance.new("UIListLayout")
towerScrollLayout.SortOrder       = Enum.SortOrder.LayoutOrder
towerScrollLayout.Padding         = UDim.new(0, 5)
towerScrollLayout.Parent          = towerScrollFrame

local towerScrollPad = Instance.new("UIPadding")
towerScrollPad.PaddingTop   = UDim.new(0, 6)
towerScrollPad.PaddingLeft  = UDim.new(0, 6)
towerScrollPad.PaddingRight = UDim.new(0, 6)
towerScrollPad.Parent = towerScrollFrame

local towerViewer              = Instance.new("Frame")
towerViewer.Name               = "TowerViewer"
towerViewer.Size               = UDim2.new(1, -248, 1, -16)
towerViewer.Position           = UDim2.new(0, 238, 0, GRID_PAD * 0.5)
towerViewer.BackgroundColor3   = C.G1
towerViewer.BorderSizePixel    = 0
towerViewer.ZIndex             = 7
towerViewer.Parent             = invPanel
makeCorner(towerViewer, 10)
makeStroke(towerViewer, C.BORDER, 1, 0)

local portraitBox              = Instance.new("Frame")
portraitBox.Name               = "Portrait"
portraitBox.Size               = UDim2.new(0, 130, 0, 130)
portraitBox.Position           = UDim2.new(0.5, -65, 0, 16)
portraitBox.BackgroundColor3   = C.GRAY
portraitBox.BorderSizePixel    = 0
portraitBox.ZIndex             = 8
portraitBox.Parent             = towerViewer
makeCorner(portraitBox, 12)
makeStroke(portraitBox, C.BORDER, 1, 0)

local portraitLabel = makeLabel(portraitBox, "?",
	UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
	C.TEXTDIM, nil, 1)
portraitLabel.TextSize = 48
portraitLabel.TextXAlignment = Enum.TextXAlignment.Center
portraitLabel.TextYAlignment = Enum.TextYAlignment.Center
portraitLabel.ZIndex = 9

local viewerName = makeLabel(towerViewer, "Select a tower",
	UDim2.new(1, -10, 0, 32),
	UDim2.new(0, 6, 0, 154),
	C.TEXT, nil, 1)
viewerName.TextSize = 21
viewerName.TextXAlignment = Enum.TextXAlignment.Center
viewerName.ZIndex = 8

local viewerRarity = makeLabel(towerViewer, "──────",
	UDim2.new(1, -10, 0, 22),
	UDim2.new(0, 6, 0, 188),
	C.TEXTSUB, nil, 1)
viewerRarity.TextSize = 16
viewerRarity.TextXAlignment = Enum.TextXAlignment.Center
viewerRarity.ZIndex = 8

local viewerDesc = Instance.new("TextLabel")
viewerDesc.Size               = UDim2.new(1, -20, 0, 72)
viewerDesc.Position           = UDim2.new(0, 10, 0, 218)
viewerDesc.BackgroundColor3   = C.GRAY
viewerDesc.BackgroundTransparency = 0
viewerDesc.BorderSizePixel    = 0
viewerDesc.Text               = "No tower selected.\nClick a tower from the list."
viewerDesc.TextColor3         = C.TEXTSUB
viewerDesc.Font               = Enum.Font.Gotham
viewerDesc.TextSize           = 14
viewerDesc.TextWrapped        = true
viewerDesc.TextXAlignment     = Enum.TextXAlignment.Left
viewerDesc.TextYAlignment     = Enum.TextYAlignment.Center
viewerDesc.ZIndex             = 8
viewerDesc.Parent             = towerViewer
makeCorner(viewerDesc, 8)

local descPad = Instance.new("UIPadding")
descPad.PaddingLeft  = UDim.new(0, 10)
descPad.PaddingRight = UDim.new(0, 10)
descPad.Parent = viewerDesc

local statsRow              = Instance.new("Frame")
statsRow.Name               = "StatsRow"
statsRow.Size               = UDim2.new(1, -20, 0, 62)
statsRow.Position           = UDim2.new(0, 10, 0, 298)
statsRow.BackgroundColor3   = C.GRAY
statsRow.BorderSizePixel    = 0
statsRow.ZIndex             = 8
statsRow.Parent             = towerViewer
makeCorner(statsRow, 8)

local statsLayout           = Instance.new("UIListLayout")
statsLayout.FillDirection   = Enum.FillDirection.Horizontal
statsLayout.SortOrder       = Enum.SortOrder.LayoutOrder
statsLayout.Padding         = UDim.new(0, 0)
statsLayout.Parent          = statsRow

local TowerStats = require(ReplicatedStorage:WaitForChild("TowerStats", 30))

local function makeStatCell(parent, icon, layoutOrder)
	local cell             = Instance.new("Frame")
	cell.Size              = UDim2.new(0.25, 0, 1, 0)
	cell.BackgroundTransparency = 1
	cell.BorderSizePixel   = 0
	cell.LayoutOrder       = layoutOrder
	cell.ZIndex            = 9
	cell.Parent            = parent

	-- Vertical divider between stats (except last)
	if layoutOrder < 4 then
		local vd = Instance.new("Frame")
		vd.Size = UDim2.new(0, 1, 0.5, 0)
		vd.Position = UDim2.new(1, 0, 0.25, 0)
		vd.BackgroundColor3 = C.BORDER
		vd.BorderSizePixel = 0
		vd.ZIndex = 10
		vd.Parent = cell
	end

	local iconL = makeLabel(cell, icon, UDim2.new(1, 0, 0, 26),
		UDim2.new(0, 0, 0, 4), C.TEXTSUB, nil, 1)
	iconL.TextSize = 18
	iconL.TextXAlignment = Enum.TextXAlignment.Center
	iconL.ZIndex = 10

	local valL = makeLabel(cell, "–",
		UDim2.new(1, 0, 0, 24),
		UDim2.new(0, 0, 0, 32),
		C.TEXT, nil, 1)
	valL.Name = "Value"
	valL.TextSize = 16
	valL.Font = Enum.Font.GothamBold
	valL.TextXAlignment = Enum.TextXAlignment.Center
	valL.ZIndex = 10

	return valL
end

local statAtk  = makeStatCell(statsRow, "⚔️",  1)
local statRng  = makeStatCell(statsRow, "🎯",  2)
local statSpd  = makeStatCell(statsRow, "⚡",  3)
local statHP   = makeStatCell(statsRow, "❤️",  4)

local equipHeader = makeLabel(towerViewer, "EQUIPMENT SLOTS",
	UDim2.new(1, -20, 0, 22),
	UDim2.new(0, 10, 0, 368),
	C.TEXTSUB, nil, 1)
equipHeader.TextSize = 14
equipHeader.ZIndex = 8

local loadoutActionBtn = makeButton(towerViewer, "ADD TO LOADOUT",
	UDim2.new(0, 190, 0, 28),
	UDim2.new(1, -200, 0, 366),
	C.ACCENT2, C.WHITE)
loadoutActionBtn.TextSize = 12
loadoutActionBtn.ZIndex = 9
makeCorner(loadoutActionBtn, 6)

local equipRow              = Instance.new("Frame")
equipRow.Name               = "EquipRow"
equipRow.Size               = UDim2.new(1, -20, 0, 62)
equipRow.Position           = UDim2.new(0, 10, 0, 392)
equipRow.BackgroundTransparency = 1
equipRow.BorderSizePixel    = 0
equipRow.ZIndex             = 8
equipRow.Parent             = towerViewer

local equipSlotButtons = {}

local equipListFrame = Instance.new("ScrollingFrame")
equipListFrame.Name = "EquipmentChoices"
equipListFrame.Size = UDim2.new(1, -20, 0, 136)
equipListFrame.Position = UDim2.new(0, 10, 0, 462)
equipListFrame.BackgroundColor3 = C.G2
equipListFrame.BorderSizePixel = 0
equipListFrame.ScrollBarThickness = 4
equipListFrame.ScrollBarImageColor3 = C.ACCENT
equipListFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
equipListFrame.ZIndex = 8
equipListFrame.Parent = towerViewer
makeCorner(equipListFrame, 8)
makeStroke(equipListFrame, C.BORDER, 1, 0)

local equipListLayout = Instance.new("UIListLayout")
equipListLayout.SortOrder = Enum.SortOrder.LayoutOrder
equipListLayout.Padding = UDim.new(0, 5)
equipListLayout.Parent = equipListFrame

local equipListPadding = Instance.new("UIPadding")
equipListPadding.PaddingTop = UDim.new(0, 6)
equipListPadding.PaddingLeft = UDim.new(0, 6)
equipListPadding.PaddingRight = UDim.new(0, 6)
equipListPadding.PaddingBottom = UDim.new(0, 6)
equipListPadding.Parent = equipListFrame

local function isEquipmentCompatible(towerName: string, eqKey: string): boolean
	local td = TowerData.Towers[towerName]
	local eq = TowerData.Equipment[eqKey]
	if not td or not eq then return false end
	local compat = eq.compatibleRoles
	if not compat or #compat == 0 then return true end
	for _, role in ipairs(compat) do
		if role == td.role then
			return true
		end
	end
	return false
end

local function refreshEquipSlotsForSelectedTower()
	local towerName = selectedTower
	if not towerName then return end
	local assigned = equippedByTower[towerName] or {}
	for i, slot in ipairs(equipSlotButtons) do
		local eqKey = assigned[i]
		local text = "+"
		local color = C.TEXTDIM
		if eqKey then
			local eq = TowerData.Equipment[eqKey]
			text = eq and eq.displayName or eqKey
			color = rarityColor(eq and eq.rarity or "COMMON")
		end
		slot.label.Text = text
		slot.label.TextColor3 = color
	end
end

local function buildEquipSlots(slotCount)
	for _, s in ipairs(equipSlotButtons) do
		s.button:Destroy()
	end
	equipSlotButtons = {}

	local slotW = 54
	local gap   = 8
	for i = 1, slotCount do
		local slotButton = Instance.new("TextButton")
		slotButton.Size = UDim2.new(0, slotW, 0, 54)
		slotButton.Position = UDim2.new(0, (i - 1) * (slotW + gap), 0, 0)
		slotButton.BackgroundColor3 = C.GRAY
		slotButton.BorderSizePixel = 0
		slotButton.Text = ""
		slotButton.ZIndex = 9
		slotButton.Parent = equipRow
		makeCorner(slotButton, 8)
		makeStroke(slotButton, C.BORDER, 1, 0)

		local slotLabel = makeLabel(slotButton, "+",
			UDim2.new(1, 0, 1, 0),
			UDim2.new(0, 0, 0, 0),
			C.TEXTDIM, nil, 1)
		slotLabel.TextScaled = true
		slotLabel.TextXAlignment = Enum.TextXAlignment.Center
		slotLabel.TextYAlignment = Enum.TextYAlignment.Center
		slotLabel.ZIndex = 10

		slotButton.MouseButton1Click:Connect(function()
			if not selectedTower then return end
			local assigned = equippedByTower[selectedTower] or {}
			if assigned[i] then
				requestProfile("ToggleEquipment", { tower = selectedTower, equipment = assigned[i] })
			end
		end)

		table.insert(equipSlotButtons, { button = slotButton, label = slotLabel })
	end
	refreshEquipSlotsForSelectedTower()
end

local function rebuildEquipmentChoices()
	for _, child in ipairs(equipListFrame:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	if not selectedTower then
		equipListFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
		return
	end

	local yCount = 0
	local assigned = equippedByTower[selectedTower] or {}
	local equippedElsewhereSet = {}
	for towerName, eqList in pairs(equippedByTower) do
		if towerName ~= selectedTower then
			for _, eqKey in ipairs(eqList) do
				equippedElsewhereSet[eqKey] = true
			end
		end
	end
	local equipmentKeys = {}
	for eqKey in pairs(ownedEquipment) do
		table.insert(equipmentKeys, eqKey)
	end
	table.sort(equipmentKeys)

	for _, eqKey in ipairs(equipmentKeys) do
		if isEquipmentCompatible(selectedTower, eqKey) then
			local eqData = TowerData.Equipment[eqKey]
			local isEquippedHere = table.find(assigned, eqKey) ~= nil
			local equippedElsewhere = equippedElsewhereSet[eqKey] == true

			local btn = makeButton(equipListFrame, "", UDim2.new(1, -2, 0, 34), UDim2.new(0, 0, 0, 0), C.G1, C.TEXT)
			btn.LayoutOrder = yCount
			btn.ZIndex = 9
			btn.TextSize = 13
			btn.TextXAlignment = Enum.TextXAlignment.Left
			local stateText = isEquippedHere and "EQUIPPED"
				or (equippedElsewhere and "USED")
				or "EQUIP"
			btn.Text = string.format("[%s] %s  (%s)", stateText, eqData.displayName, eqData.rarity)
			btn.TextColor3 = isEquippedHere and C.GREEN or rarityColor(eqData.rarity)
			btn.AutoButtonColor = not equippedElsewhere or isEquippedHere
			btn.BackgroundColor3 = isEquippedHere and C.G2 or C.G1
			makeStroke(btn, C.BORDER, 1, 0)

			btn.MouseButton1Click:Connect(function()
				if equippedElsewhere and not isEquippedHere then return end
				requestProfile("ToggleEquipment", { tower = selectedTower, equipment = eqKey })
			end)
			yCount += 1
		end
	end

	equipListFrame.CanvasSize = UDim2.new(0, 0, 0, math.max(0, yCount * 39 + 8))
end

buildEquipSlots(0)

-- ============================================================
-- Tower list entries
-- ============================================================

local towerEntryButtons = {}

local function updateViewerForTower(towerName: string)
	selectedTower    = towerName
	local td         = TowerData.Towers[towerName]
	local ts         = TowerStats and TowerStats.Templates[towerName]
	local isUnlocked = unlockedTowers[towerName] == true
	local inLoadout  = table.find(currentLoadout, towerName) ~= nil

	viewerName.Text  = td and td.displayName or towerName
	viewerName.TextColor3 = isUnlocked and C.TEXT or C.TEXTDIM

	if td then
		viewerRarity.Text = rarityStars(td.rarity)
		viewerRarity.TextColor3 = rarityColor(td.rarity)
		viewerDesc.Text  = isUnlocked
			and (td.description .. "\n\nRole: " .. (td.role or "–"))
			or  "🔒 Tower locked.\nObtain via Gacha or the Shop."
		buildEquipSlots(isUnlocked and (td.equipmentSlots or 0) or 0)
	else
		viewerRarity.Text = "–"
		viewerDesc.Text  = ""
		buildEquipSlots(0)
	end

	if ts and isUnlocked then
		statAtk.Text = tostring(ts.ATK  or "–")
		statRng.Text = tostring(ts.RNG  or "–")
		statSpd.Text = tostring(ts.ATK_SPD or "–")
		statHP.Text  = tostring(ts.HP   or "–")
	else
		statAtk.Text = "–"
		statRng.Text = "–"
		statSpd.Text = "–"
		statHP.Text  = "–"
	end

	loadoutActionBtn.Visible = isUnlocked
	loadoutActionBtn.Text = inLoadout and "REMOVE FROM LOADOUT" or "ADD TO LOADOUT"
	loadoutActionBtn.BackgroundColor3 = inLoadout and C.RED or C.ACCENT2
	refreshEquipSlotsForSelectedTower()
	rebuildEquipmentChoices()
end

local function buildTowerListEntries()
	for _, child in ipairs(towerScrollFrame:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	towerEntryButtons = {}

	local sortedNames = {}
	for name in pairs(TowerData.Towers) do
		table.insert(sortedNames, name)
	end
	table.sort(sortedNames)

	local totalH = 0
	for _, name in ipairs(sortedNames) do
		local td         = TowerData.Towers[name]
		local isUnlocked = unlockedTowers[name] == true

		local entry            = Instance.new("Frame")
		entry.Name             = name
		entry.Size             = UDim2.new(1, 0, 0, 76)
		entry.BackgroundColor3 = isUnlocked and C.G1 or C.G3
		entry.BackgroundTransparency = 0
		entry.BorderSizePixel  = 0
		entry.ZIndex           = 9
		entry.LayoutOrder      = isUnlocked and 0 or 1
		entry.Parent           = towerScrollFrame
		makeCorner(entry, 8)
		makeStroke(entry, isUnlocked and C.ACCENT or C.BORDER, 1, isUnlocked and 0.4 or 0)

		-- Left accent bar per rarity
		local rBar = Instance.new("Frame")
		rBar.Size = UDim2.new(0, 4, 1, 0)
		rBar.BackgroundColor3 = isUnlocked and rarityColor(td.rarity) or C.TEXTDIM
		rBar.BorderSizePixel = 0
		rBar.ZIndex = 10
		rBar.Parent = entry
		makeCorner(rBar, 3)

		local nameL = makeLabel(entry, td.displayName,
			UDim2.new(1, -20, 0, 26),
			UDim2.new(0, 12, 0, 12),
			isUnlocked and C.TEXT or C.TEXTDIM, nil, 1)
		nameL.TextSize = 17
		nameL.ZIndex = 10

		local rarityL = makeLabel(entry, rarityStars(td.rarity),
			UDim2.new(1, -20, 0, 18),
			UDim2.new(0, 12, 0, 40),
			rarityColor(td.rarity), nil, 1)
		rarityL.TextSize = 13
		rarityL.Font = Enum.Font.Gotham
		rarityL.ZIndex = 10

		if not isUnlocked then
			local lockL = makeLabel(entry, "🔒",
				UDim2.new(0, 26, 0, 26),
				UDim2.new(1, -32, 0.5, -13),
				C.RED, nil, 1)
			lockL.TextSize = 18
			lockL.TextXAlignment = Enum.TextXAlignment.Center
			lockL.ZIndex = 10
		end

		local btn              = Instance.new("TextButton")
		btn.Size               = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Text               = ""
		btn.ZIndex             = 11
		btn.Parent             = entry

		btn.MouseButton1Click:Connect(function()
			updateViewerForTower(name)
			for n, b in pairs(towerEntryButtons) do
				b.BackgroundColor3 = n == name and C.G2 or (unlockedTowers[n] and C.G1 or C.G3)
			end
		end)

		towerEntryButtons[name] = entry
		totalH = totalH + 81
	end

	towerScrollFrame.CanvasSize = UDim2.new(0, 0, 0, totalH)
end

local function rebuildHomeLoadoutSlots()
	for _, slot in ipairs(loadoutHomeSlots) do
		slot:Destroy()
	end
	loadoutHomeSlots = {}

	for i = 1, 5 do
		local towerName = currentLoadout[i]
		local slot = makeButton(loadoutHomeRow, "",
			UDim2.new(0, 92, 0, 66),
			UDim2.new(0, 0, 0, 0),
			towerName and C.G1 or C.G3, C.TEXT)
		slot.TextSize = 12
		slot.TextWrapped = true
		slot.Text = towerName and (string.format("%d. %s", i, towerName)) or (string.format("%d. Empty", i))
		slot.ZIndex = 14
		makeCorner(slot, 7)
		makeStroke(slot, C.BORDER, 1, 0)

		slot.MouseButton1Click:Connect(function()
			if not towerName then return end
			local nextLoadout = table.clone(currentLoadout)
			table.remove(nextLoadout, i)
			requestProfile("SetLoadout", { loadout = nextLoadout })
		end)

		table.insert(loadoutHomeSlots, slot)
	end
end

refreshLoadoutViews = function()
	buildTowerListEntries()
	rebuildHomeLoadoutSlots()
	if selectedTower and TowerData.Towers[selectedTower] then
		updateViewerForTower(selectedTower)
	elseif currentLoadout[1] then
		updateViewerForTower(currentLoadout[1])
	end
end

loadoutActionBtn.MouseButton1Click:Connect(function()
	if not selectedTower then return end
	if not unlockedTowers[selectedTower] then return end

	local inLoadout = table.find(currentLoadout, selectedTower) ~= nil
	local nextLoadout = table.clone(currentLoadout)
	if inLoadout then
		local idx = table.find(nextLoadout, selectedTower)
		if idx then table.remove(nextLoadout, idx) end
	else
		if #nextLoadout >= 5 then return end
		table.insert(nextLoadout, selectedTower)
	end
	requestProfile("SetLoadout", { loadout = nextLoadout })
end)

-- ============================================================
-- QUESTS PANEL
-- ============================================================

local questPanel              = Instance.new("Frame")
questPanel.Name               = "QuestsPanel"
questPanel.Size               = UDim2.new(1, 0, 1, 0)
questPanel.BackgroundTransparency = 1
questPanel.BorderSizePixel    = 0
questPanel.Visible            = false
questPanel.ZIndex             = 6
questPanel.Parent             = contentArea

local questTabBar             = Instance.new("Frame")
questTabBar.Size              = UDim2.new(1, 0, 0, 52)
questTabBar.BackgroundColor3  = C.G2
questTabBar.BackgroundTransparency = 0
questTabBar.BorderSizePixel   = 0
questTabBar.ZIndex            = 7
questTabBar.Parent            = questPanel

local questDivider = makeDivider(questTabBar, true)
questDivider.Position = UDim2.new(0, 0, 1, -1)

local questTabLayout          = Instance.new("UIListLayout")
questTabLayout.FillDirection  = Enum.FillDirection.Horizontal
questTabLayout.SortOrder      = Enum.SortOrder.LayoutOrder
questTabLayout.Parent         = questTabBar

local questTabBtns = {}
local questScrolls = {}

local tabDefs = {
	{ key = "Daily",      label = "DAILY",      layoutOrder = 1 },
	{ key = "Weekly",     label = "WEEKLY",     layoutOrder = 2 },
	{ key = "Challenges", label = "CHALLENGES", layoutOrder = 3 },
}

local questScrollContainer              = Instance.new("Frame")
questScrollContainer.Size               = UDim2.new(1, 0, 1, -52)
questScrollContainer.Position           = UDim2.new(0, 0, 0, 52)
questScrollContainer.BackgroundTransparency = 1
questScrollContainer.BorderSizePixel    = 0
questScrollContainer.ZIndex             = 7
questScrollContainer.Parent             = questPanel

for _, tabDef in ipairs(tabDefs) do
	local key = tabDef.key

	local tabContainer = Instance.new("Frame")
	tabContainer.Size = UDim2.new(0, 200, 1, 0)
	tabContainer.BackgroundColor3 = C.G1
	tabContainer.BackgroundTransparency = 1
	tabContainer.BorderSizePixel = 0
	tabContainer.LayoutOrder = tabDef.layoutOrder
	tabContainer.ZIndex = 8
	tabContainer.Parent = questTabBar

	local tabBtn              = Instance.new("TextButton")
	tabBtn.Size               = UDim2.new(1, 0, 1, 0)
	tabBtn.BackgroundTransparency = 1
	tabBtn.BorderSizePixel    = 0
	tabBtn.Text               = tabDef.label
	tabBtn.TextColor3         = C.TEXTSUB
	tabBtn.Font               = Enum.Font.GothamBold
	tabBtn.TextSize           = 17
	tabBtn.AutoButtonColor    = false
	tabBtn.ZIndex             = 9
	tabBtn.Parent             = tabContainer

	local qActiveBar = Instance.new("Frame")
	qActiveBar.Size = UDim2.new(0.6, 0, 0, 3)
	qActiveBar.AnchorPoint = Vector2.new(0.5, 1)
	qActiveBar.Position = UDim2.new(0.5, 0, 1, 0)
	qActiveBar.BackgroundColor3 = C.ACCENT
	qActiveBar.BorderSizePixel = 0
	qActiveBar.Visible = false
	qActiveBar.ZIndex = 10
	qActiveBar.Parent = tabContainer
	makeCorner(qActiveBar, 2)

	questTabBtns[key] = { btn = tabBtn, bar = qActiveBar }

	local scroll              = Instance.new("ScrollingFrame")
	scroll.Name               = key .. "Scroll"
	scroll.Size               = UDim2.new(1, 0, 1, 0)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel    = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = C.ACCENT
	scroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
	scroll.Visible            = (key == "Daily")
	scroll.ZIndex             = 8
	scroll.Parent             = questScrollContainer

	local scrollLayout        = Instance.new("UIListLayout")
	scrollLayout.SortOrder    = Enum.SortOrder.LayoutOrder
	scrollLayout.Padding      = UDim.new(0, 8)
	scrollLayout.Parent       = scroll

	local scrollPad           = Instance.new("UIPadding")
	scrollPad.PaddingTop      = UDim.new(0, 10)
	scrollPad.PaddingLeft     = UDim.new(0, 12)
	scrollPad.PaddingRight    = UDim.new(0, 12)
	scrollPad.Parent          = scroll

	questScrolls[key] = scroll

	local quests  = TowerData.Quests[key] or {}
	local totalH  = 10
	for _, quest in ipairs(quests) do
		local card              = Instance.new("Frame")
		card.Name               = quest.id
		card.Size               = UDim2.new(1, 0, 0, 100)
		card.BackgroundColor3   = C.G1
		card.BackgroundTransparency = 0
		card.BorderSizePixel    = 0
		card.ZIndex             = 9
		card.Parent             = scroll
		makeCorner(card, 10)
		makeStroke(card, C.BORDER, 1, 0)

		local qname = makeLabel(card, quest.displayName,
			UDim2.new(1, -130, 0, 28),
			UDim2.new(0, 14, 0, 12),
			C.TEXT, nil, 1)
		qname.TextSize = 18
		qname.ZIndex = 10

		local qdesc = makeLabel(card, quest.description,
			UDim2.new(1, -130, 0, 26),
			UDim2.new(0, 14, 0, 40),
			C.TEXTSUB, nil, 1)
		qdesc.TextSize = 14
		qdesc.Font = Enum.Font.Gotham
		qdesc.TextWrapped = true
		qdesc.ZIndex = 10

		local rewardParts = {}
		if quest.reward.Coins then
			table.insert(rewardParts, "🪙 " .. quest.reward.Coins)
		end
		if quest.reward.Gems then
			table.insert(rewardParts, "💎 " .. quest.reward.Gems)
		end
		if quest.reward.Equipment then
			local eq = TowerData.Equipment[quest.reward.Equipment]
			table.insert(rewardParts, "🎁 " .. (eq and eq.displayName or quest.reward.Equipment))
		end

		local rewardL = makeLabel(card, "Reward: " .. table.concat(rewardParts, "  "),
			UDim2.new(1, -130, 0, 20),
			UDim2.new(0, 14, 0, 70),
			C.GOLD, nil, 1)
		rewardL.TextSize = 14
		rewardL.Font = Enum.Font.GothamBold
		rewardL.ZIndex = 10

		local progBg              = Instance.new("Frame")
		progBg.Size               = UDim2.new(0, 116, 0, 12)
		progBg.Position           = UDim2.new(1, -128, 0, 18)
		progBg.BackgroundColor3   = C.GRAY
		progBg.BorderSizePixel    = 0
		progBg.ZIndex             = 10
		progBg.Parent             = card
		makeCorner(progBg, 6)
		makeStroke(progBg, C.BORDER, 1, 0)

		local progFill            = Instance.new("Frame")
		progFill.Size             = UDim2.new(0, 0, 1, 0)
		progFill.BackgroundColor3 = C.GREEN
		progFill.BorderSizePixel  = 0
		progFill.ZIndex           = 11
		progFill.Parent           = progBg
		makeCorner(progFill, 6)

		local progText = makeLabel(card, "0 / " .. quest.goal,
			UDim2.new(0, 116, 0, 18),
			UDim2.new(1, -128, 0, 34),
			C.TEXTSUB, nil, 1)
		progText.TextSize = 12
		progText.TextXAlignment = Enum.TextXAlignment.Center
		progText.ZIndex = 10

		local claimBtn = makeButton(card, "Claim",
			UDim2.new(0, 104, 0, 34),
			UDim2.new(1, -118, 1, -44),
			C.GRAY_DARK, C.TEXT)
		claimBtn.TextSize = 15
		claimBtn.ZIndex = 10
		makeCorner(claimBtn, 7)

		totalH = totalH + 108
	end
	scroll.CanvasSize = UDim2.new(0, 0, 0, totalH)
end

local function switchQuestTab(key: string)
	activeQuestTab = key
	for k, scroll in pairs(questScrolls) do
		scroll.Visible = (k == key)
	end
	for k, info in pairs(questTabBtns) do
		if k == key then
			info.btn.TextColor3 = C.ACCENT
			info.bar.Visible = true
		else
			info.btn.TextColor3 = C.TEXTSUB
			info.bar.Visible = false
		end
	end
end

for k, info in pairs(questTabBtns) do
	info.btn.MouseButton1Click:Connect(function()
		switchQuestTab(k)
	end)
end

switchQuestTab("Daily")

-- ============================================================
-- GACHA PANEL
-- ============================================================

local gachaPanel              = Instance.new("Frame")
gachaPanel.Name               = "GachaPanel"
gachaPanel.Size               = UDim2.new(1, 0, 1, 0)
gachaPanel.BackgroundTransparency = 1
gachaPanel.BorderSizePixel    = 0
gachaPanel.Visible            = false
gachaPanel.ZIndex             = 6
gachaPanel.Parent             = contentArea

local bannerRow              = Instance.new("Frame")
bannerRow.Size               = UDim2.new(1, -24, 0, 80)
bannerRow.Position           = UDim2.new(0, 12, 0, 12)
bannerRow.BackgroundTransparency = 1
bannerRow.BorderSizePixel    = 0
bannerRow.ZIndex             = 7
bannerRow.Parent             = gachaPanel

local bannerBtns = {}

for i, bKey in ipairs({ "standard", "special" }) do
	local bData             = TowerData.Banners[bKey]
	local isActive          = (bKey == activeBanner)

	local bBtn              = Instance.new("TextButton")
	bBtn.Size               = UDim2.new(0.5, -6, 1, 0)
	bBtn.Position           = UDim2.new((i-1)*0.5, (i-1)*6, 0, 0)
	bBtn.BackgroundColor3   = isActive and C.ACCENT or C.G1
	bBtn.BackgroundTransparency = 0
	bBtn.BorderSizePixel    = 0
	bBtn.Text               = ""
	bBtn.AutoButtonColor    = false
	bBtn.ZIndex             = 8
	bBtn.Parent             = bannerRow
	makeCorner(bBtn, 10)
	local bStroke = makeStroke(bBtn, isActive and C.ACCENT or C.BORDER, 1, isActive and 0 or 0)

	local bName = makeLabel(bBtn, bData.displayName,
		UDim2.new(1, -16, 0, 30),
		UDim2.new(0, 14, 0, 12),
		isActive and C.WHITE or C.TEXT, nil, 1)
	bName.TextSize = 17
	bName.ZIndex = 9

	local bType = makeLabel(bBtn, bKey == "special" and "⭐ RATE-UP BANNER" or "📦 STANDARD",
		UDim2.new(1, -16, 0, 22),
		UDim2.new(0, 14, 0, 42),
		bKey == "special" and (isActive and C.GOLD or C.GOLD) or C.TEXTSUB, nil, 1)
	bType.TextSize = 14
	bType.ZIndex = 9

	bannerBtns[bKey] = { button = bBtn, nameLabel = bName, typeLabel = bType, stroke = bStroke }
end

local bannerDesc              = Instance.new("TextLabel")
bannerDesc.Size               = UDim2.new(1, -24, 0, 64)
bannerDesc.Position           = UDim2.new(0, 12, 0, 100)
bannerDesc.BackgroundColor3   = C.GRAY
bannerDesc.BackgroundTransparency = 0
bannerDesc.BorderSizePixel    = 0
bannerDesc.Text               = TowerData.Banners.standard.description
bannerDesc.TextColor3         = C.TEXTSUB
bannerDesc.Font               = Enum.Font.Gotham
bannerDesc.TextSize           = 14
bannerDesc.TextWrapped        = true
bannerDesc.TextXAlignment     = Enum.TextXAlignment.Left
bannerDesc.TextYAlignment     = Enum.TextYAlignment.Center
bannerDesc.ZIndex             = 7
bannerDesc.Parent             = gachaPanel
makeCorner(bannerDesc, 10)
makeStroke(bannerDesc, C.BORDER, 1, 0)

local descPad2 = Instance.new("UIPadding")
descPad2.PaddingTop   = UDim.new(0, 6)
descPad2.PaddingLeft  = UDim.new(0, 12)
descPad2.PaddingRight = UDim.new(0, 12)
descPad2.Parent       = bannerDesc

local rateUpLabel = makeLabel(gachaPanel, "Rate-Up: Deadeye",
	UDim2.new(1, -24, 0, 26),
	UDim2.new(0, 12, 0, 172),
	C.GOLD, nil, 1)
rateUpLabel.TextSize = 16
rateUpLabel.Visible = (activeBanner == "special")
rateUpLabel.ZIndex = 7

local pityLabel = makeLabel(gachaPanel, "Pity: 0 / 70  (Gem pulls only)",
	UDim2.new(1, -24, 0, 22),
	UDim2.new(0, 12, 0, 202),
	C.TEXTSUB, nil, 1)
pityLabel.TextSize = 14
pityLabel.Font = Enum.Font.Gotham
pityLabel.ZIndex = 7

-- Pull buttons row
local pullRow               = Instance.new("Frame")
pullRow.Size                = UDim2.new(1, -24, 0, 58)
pullRow.Position            = UDim2.new(0, 12, 0, 232)
pullRow.BackgroundTransparency = 1
pullRow.BorderSizePixel     = 0
pullRow.ZIndex              = 7
pullRow.Parent              = gachaPanel

local pullLayout = Instance.new("UIListLayout")
pullLayout.FillDirection = Enum.FillDirection.Horizontal
pullLayout.SortOrder = Enum.SortOrder.LayoutOrder
pullLayout.Padding = UDim.new(0, 8)
pullLayout.Parent = pullRow

local function makePullBtn(parent, text, bg, textColor, layoutOrder)
	local b = makeButton(parent, text,
		UDim2.new(0.25, -6, 1, 0), UDim2.new(0,0,0,0),
		bg, textColor)
	b.TextSize = 14
	b.LayoutOrder = layoutOrder
	b.ZIndex = 8
	makeCorner(b, 8)
	return b
end

local gem1Btn   = makePullBtn(pullRow, "💎 ×1  (160)",    C.GEM,                              C.WHITE, 1)
local gem10Btn  = makePullBtn(pullRow, "💎 ×10  (1,600)", Color3.fromRGB(105, 55, 220),       C.WHITE, 2)
local coin1Btn  = makePullBtn(pullRow, "🪙 ×1  (1,000)",  Color3.fromRGB(210, 175, 60),       C.TEXT,  3)
local coin10Btn = makePullBtn(pullRow, "🪙 ×10  (10,000)",Color3.fromRGB(185, 155, 40),       C.TEXT,  4)

local noPityNote = makeLabel(gachaPanel, "⚠ Coin pulls do not count toward pity.",
	UDim2.new(1, -24, 0, 20),
	UDim2.new(0, 12, 0, 298),
	C.RED, nil, 1)
noPityNote.TextSize = 14
noPityNote.Font = Enum.Font.Gotham
noPityNote.ZIndex = 7

local resultsHeader = makeLabel(gachaPanel, "RECENT PULLS",
	UDim2.new(1, -24, 0, 22),
	UDim2.new(0, 12, 0, 324),
	C.TEXTSUB, nil, 1)
resultsHeader.TextSize = 14
resultsHeader.ZIndex = 7

local resultsScroll              = Instance.new("ScrollingFrame")
resultsScroll.Name               = "ResultsScroll"
resultsScroll.Size               = UDim2.new(1, -24, 1, -356)
resultsScroll.Position           = UDim2.new(0, 12, 0, 350)
resultsScroll.BackgroundColor3   = C.GRAY
resultsScroll.BackgroundTransparency = 0
resultsScroll.BorderSizePixel    = 0
resultsScroll.ScrollBarThickness = 4
resultsScroll.ScrollBarImageColor3 = C.ACCENT
resultsScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
resultsScroll.ZIndex             = 7
resultsScroll.Parent             = gachaPanel
makeCorner(resultsScroll, 10)
makeStroke(resultsScroll, C.BORDER, 1, 0)

local resultsLayout              = Instance.new("UIListLayout")
resultsLayout.FillDirection      = Enum.FillDirection.Horizontal
resultsLayout.SortOrder          = Enum.SortOrder.LayoutOrder
resultsLayout.Padding            = UDim.new(0, 8)
resultsLayout.Wraps              = true
resultsLayout.Parent             = resultsScroll

local resultsPad                 = Instance.new("UIPadding")
resultsPad.PaddingTop            = UDim.new(0, 8)
resultsPad.PaddingLeft           = UDim.new(0, 8)
resultsPad.PaddingRight          = UDim.new(0, 8)
resultsPad.Parent                = resultsScroll

local resultCards = {}

local function addResultCard(towerName: string, rarity: string, isNew: boolean)
	local td     = TowerData.Towers[towerName]
	local rColor = rarityColor(rarity)

	local card              = Instance.new("Frame")
	card.Size               = UDim2.new(0, 80, 0, 90)
	card.BackgroundColor3   = C.G1
	card.BorderSizePixel    = 0
	card.LayoutOrder        = -(#resultCards)
	card.ZIndex             = 8
	card.Parent             = resultsScroll
	makeCorner(card, 10)
	makeStroke(card, rColor, 2, 0)

	local icon = makeLabel(card, td and td.displayName:sub(1,2) or "??",
		UDim2.new(1, 0, 0, 48),
		UDim2.new(0, 0, 0, 4),
		rColor, nil, 1)
	icon.TextSize = 22
	icon.TextXAlignment = Enum.TextXAlignment.Center
	icon.ZIndex = 9

	local nameL = makeLabel(card, td and td.displayName or towerName,
		UDim2.new(1, -6, 0, 30),
		UDim2.new(0, 3, 0, 52),
		C.TEXT, nil, 1)
	nameL.TextSize = 12
	nameL.TextWrapped = true
	nameL.TextXAlignment = Enum.TextXAlignment.Center
	nameL.ZIndex = 9

	if isNew then
		local newTag = Instance.new("Frame")
		newTag.Size = UDim2.new(1, 0, 0, 18)
		newTag.Position = UDim2.new(0, 0, 1, -18)
		newTag.BackgroundColor3 = C.GREEN
		newTag.BorderSizePixel = 0
		newTag.ZIndex = 9
		newTag.Parent = card
		makeCorner(newTag, 5)

		local newL = makeLabel(newTag, "NEW",
			UDim2.new(1, 0, 1, 0),
			UDim2.new(0, 0, 0, 0),
			C.WHITE, nil, 1)
		newL.TextSize = 11
		newL.Font = Enum.Font.GothamBold
		newL.TextXAlignment = Enum.TextXAlignment.Center
		newL.ZIndex = 10
	end

	table.insert(resultCards, card)
	local contentH = math.ceil(#resultCards / 6) * 104 + 16
	resultsScroll.CanvasSize = UDim2.new(0, 0, 0, contentH)
	resultsScroll.CanvasPosition = Vector2.new(0, 0)
end

local function switchBanner(bannerKey: string)
	activeBanner = bannerKey
	local bData  = TowerData.Banners[bannerKey]

	bannerDesc.Text = bData.description
	rateUpLabel.Visible = (bannerKey == "special")
	if bannerKey == "special" then
		rateUpLabel.Text = "Rate-Up: " .. (bData.rateUpTower or "None") .. "  (rotates hourly)"
	end

	for k, info in pairs(bannerBtns) do
		local isActive = (k == bannerKey)
		info.button.BackgroundColor3 = isActive and C.ACCENT or C.G1
		info.nameLabel.TextColor3 = isActive and C.WHITE or C.TEXT
		if info.stroke then
			info.stroke.Color = isActive and C.ACCENT or C.BORDER
			info.stroke.Transparency = 0
		end
	end
end

for bKey, info in pairs(bannerBtns) do
	info.button.MouseButton1Click:Connect(function()
		switchBanner(bKey)
	end)
end

local function firePull(count: number, useGems: boolean)
	gachaPullRemote:FireServer(activeBanner, count, useGems)
end

gem1Btn.MouseButton1Click:Connect(function()   firePull(1,  true)  end)
gem10Btn.MouseButton1Click:Connect(function()  firePull(10, true)  end)
coin1Btn.MouseButton1Click:Connect(function()  firePull(1,  false) end)
coin10Btn.MouseButton1Click:Connect(function() firePull(10, false) end)

gachaResultRemote.OnClientEvent:Connect(function(results: table)
	for _, res in ipairs(results) do
		addResultCard(res.tower, res.rarity, res.isNew)
	end
	requestProfile("Get", {})
end)

-- ============================================================
-- PANEL SWITCHING LOGIC
-- ============================================================

local panels = {
	home      = { frame = homePanel,   title = "HOME"      },
	inventory = { frame = invPanel,    title = "INVENTORY"  },
	quests    = { frame = questPanel,  title = "QUESTS"     },
	gacha     = { frame = gachaPanel,  title = "GACHA"      },
}

local function setTabActive(key: string | nil)
	for k, info in pairs(tabButtons) do
		local isActive = (k == key)
		info.indicator.Visible = isActive
		info.label.TextColor3 = isActive and C.ACCENT or C.TEXTSUB
		info.label.Font = isActive and Enum.Font.GothamBold or Enum.Font.Gotham
	end
end

local function openPanel(key: string)
	if activePanel == key then return end
	activePanel = key
	for k, p in pairs(panels) do
		p.frame.Visible = (k == key)
	end
	setTabActive(key)
	if key == "inventory" then
		buildTowerListEntries()
	end
end

invTileBtn.MouseButton1Click:Connect(function()      openPanel("inventory") end)
gachaTileBtn.MouseButton1Click:Connect(function()    openPanel("gacha")     end)
dailyTileBtn.MouseButton1Click:Connect(function()
	switchQuestTab("Daily")
	openPanel("quests")
end)
weeklyTileBtn.MouseButton1Click:Connect(function()
	switchQuestTab("Weekly")
	openPanel("quests")
end)
challengeTileBtn.MouseButton1Click:Connect(function()
	switchQuestTab("Challenges")
	openPanel("quests")
end)

-- ============================================================
-- SLIDE ANIMATION + CAMERA
-- ============================================================

local camera = Workspace.CurrentCamera
local originalCameraType = nil
local originalCameraCF   = nil

local SLIDE_TIME = 0.45
local TWEEN_INFO = TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function slideOpen()
	panelOpen = true
	arrowBtn.Text = "▼"

	TweenService:Create(mainPanel, TWEEN_INFO, { Position = UDim2.new(0.5, 0, 0.5, 0) }):Play()
	TweenService:Create(arrowBtn, TWEEN_INFO, { Position = UDim2.new(0.5, -36, 0.14, -20) }):Play()

	originalCameraType = camera.CameraType
	originalCameraCF   = camera.CFrame

	local character = player.Character
	if character then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root then
			camera.CameraType = Enum.CameraType.Scriptable
			local targetCF = CFrame.new(
				root.Position + CAMERA_OFFSET,
				root.Position + CAMERA_LOOKAT_OFFSET
			)
			TweenService:Create(camera,
				TweenInfo.new(SLIDE_TIME * 1.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ CFrame = targetCF }
			):Play()
		end
	end

	if not activePanel then
		openPanel("home")
	end
end

local function restoreCameraType()
	camera.CameraType = originalCameraType or Enum.CameraType.Custom
end

local function slideClose()
	panelOpen = false
	arrowBtn.Text = "▲"

	TweenService:Create(mainPanel, TWEEN_INFO, { Position = UDim2.new(0.5, 0, 1.5, 0) }):Play()
	TweenService:Create(arrowBtn, TWEEN_INFO, { Position = UDim2.new(0.5, -36, 1, -40) }):Play()

	if originalCameraType then
		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and originalCameraCF then
				local camTween = TweenService:Create(camera,
					TweenInfo.new(SLIDE_TIME * 1.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
					{ CFrame = originalCameraCF }
				)
				camTween:Play()
				camTween.Completed:Connect(restoreCameraType)
			else
				restoreCameraType()
			end
		else
			restoreCameraType()
		end
		originalCameraType = nil
		originalCameraCF   = nil
	end
end

local function togglePanel()
	if panelOpen then slideClose() else slideOpen() end
end

arrowBtn.MouseButton1Click:Connect(togglePanel)

for key, info in pairs(tabButtons) do
	info.button.MouseButton1Click:Connect(function()
		if not panelOpen then slideOpen() end
		openPanel(key)
	end)
end

-- ============================================================
-- CURRENCY UPDATE
-- ============================================================

local function formatNumber(n: number): string
	local s = tostring(math.floor(n))
	local result = ""
	local len    = #s
	for i = 1, len do
		if i > 1 and (len - i + 1) % 3 == 0 then
			result = result .. ","
		end
		result = result .. s:sub(i, i)
	end
	return result
end

updateCurrencyRemote.OnClientEvent:Connect(function(data: table)
	localCoins = data.Coins or 0
	localGems  = data.Gems  or 0
	coinsLabel.Text = formatNumber(localCoins)
	gemsLabel.Text  = formatNumber(localGems)
end)

loadoutUpdatedRemote.OnClientEvent:Connect(function(snapshot: table)
	applyProfileSnapshot(snapshot)
end)

-- ============================================================
-- GAME STATE TOGGLE
-- ============================================================

local function updateToggleBtn(state: string)
	if state == "InRound" then
		toggleBtn.Text = "⏹ STOP"
		toggleBtn.BackgroundColor3 = C.RED
		if panelOpen then slideClose() end
		arrowBtn.Visible = false
		activePanel = nil
		setTabActive(nil)
	else
		toggleBtn.Text = "▶ START"
		toggleBtn.BackgroundColor3 = C.GREEN
		arrowBtn.Visible = true
	end
end

toggleBtn.MouseButton1Click:Connect(function()
	toggleStateRemote:FireServer()
end)

gameStateChanged.OnClientEvent:Connect(function(newState: string)
	updateToggleBtn(newState)
end)

if gameStateValue then
	updateToggleBtn(gameStateValue.Value)
end

-- ============================================================
-- INITIAL SETUP
-- ============================================================

buildTowerListEntries()
switchQuestTab("Daily")
switchBanner("standard")
requestProfile("Get", {})
