--[[
LobbyGui (LocalScript)
Place in StarterGui/

Implements all three main out-of-round GUIs:
  • INVENTORY  – tower/equipment viewer and shop
  • QUESTS     – daily / weekly / challenge quest tabs
  • GACHA      – standard and special banner pull system

Sleek bottom-panel design with slanted tabs, smooth slide-up
animation, and camera manipulation. An arrow button at the
bottom of the screen toggles the panel open/closed.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TowerData = require(ReplicatedStorage:WaitForChild("TowerData", 30))

-- ============================================================
-- REMOTES  (wait for CurrencyManager / GameStateManager to create them)
-- ============================================================

local updateCurrencyRemote = ReplicatedStorage:WaitForChild("UpdateCurrency",    30)
local gachaPullRemote      = ReplicatedStorage:WaitForChild("GachaPull",         30)
local gachaResultRemote    = ReplicatedStorage:WaitForChild("GachaResult",       30)
local toggleStateRemote    = ReplicatedStorage:WaitForChild("ToggleGameState",   30)
local gameStateChanged     = ReplicatedStorage:WaitForChild("GameStateChanged",  30)
local gameStateValue       = ReplicatedStorage:WaitForChild("GameState",         30)

-- ============================================================
-- LOCAL STATE
-- ============================================================

local localCoins      = 0
local localGems       = 0
local activeBanner    = "standard"
local activePanel     = nil   -- "inventory" | "quests" | "gacha" | nil

local unlockedTowers  = { Warrior = true }
local ownedEquipment  = {}
local selectedTower   = nil
local activeQuestTab  = "Daily"
local panelOpen       = false

-- ============================================================
-- COLOUR PALETTE  (sleek light-theme with accents)
-- ============================================================

local C = {
	BG        = Color3.fromRGB(235, 237, 245),
	PANEL     = Color3.fromRGB(255, 255, 255),
	PANEL2    = Color3.fromRGB(242, 243, 250),
	BORDER    = Color3.fromRGB(200, 205, 218),
	ACCENT    = Color3.fromRGB(255, 90, 120),
	ACCENT2   = Color3.fromRGB(80, 140, 255),
	GREEN     = Color3.fromRGB(60,  200, 100),
	RED       = Color3.fromRGB(220, 70,  70),
	GOLD      = Color3.fromRGB(255, 185, 40),
	GEM       = Color3.fromRGB(140, 80,  255),
	TEXT      = Color3.fromRGB(35,  38,  52),
	TEXTSUB   = Color3.fromRGB(100, 105, 125),
	TEXTDIM   = Color3.fromRGB(155, 160, 178),
	WHITE     = Color3.fromRGB(255, 255, 255),
	BLACK     = Color3.fromRGB(0,   0,   0),
	TAB_BG    = Color3.fromRGB(42,  44,  58),
	}

local TAB_SLANT_DEGREES = -4

-- Camera cinematic angle offsets
local CAMERA_OFFSET        = Vector3.new(8, 5, 8)
local CAMERA_LOOKAT_OFFSET = Vector3.new(0, 1, 0)

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
	c.CornerRadius = UDim.new(0, radius or 6)
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

local function makeLabel(parent, text, size, pos, textColor, bgColor, bgTrans)
	local f = Instance.new("TextLabel")
	f.Size = size
	f.Position = pos or UDim2.new(0,0,0,0)
	f.BackgroundColor3 = bgColor or C.PANEL
	f.BackgroundTransparency = bgTrans ~= nil and bgTrans or 1
	f.BorderSizePixel = 0
	f.Text = text
	f.TextColor3 = textColor or C.TEXT
	f.Font = Enum.Font.GothamBold
	f.TextScaled = false
	f.TextSize = 13
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
	b.TextSize = 13
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
	d.BackgroundColor3 = C.BORDER
	d.BackgroundTransparency = 0.3
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
	return string.rep("★", n) .. string.rep("☆", 5 - n)
end

-- ============================================================
-- MAIN BOTTOM PANEL  (slides up from the bottom of the screen)
-- ============================================================

local PANEL_HEIGHT = 0.55

local mainPanel              = Instance.new("Frame")
mainPanel.Name               = "MainPanel"
mainPanel.Size               = UDim2.new(1, 0, PANEL_HEIGHT, 0)
mainPanel.Position           = UDim2.new(0, 0, 1, 0)
mainPanel.BackgroundColor3   = C.PANEL
mainPanel.BackgroundTransparency = 0
mainPanel.BorderSizePixel    = 0
mainPanel.ClipsDescendants   = true
mainPanel.ZIndex             = 5
mainPanel.Parent             = screenGui

local accentStripe           = Instance.new("Frame")
accentStripe.Size            = UDim2.new(1, 0, 0, 3)
accentStripe.Position        = UDim2.new(0, 0, 0, 0)
accentStripe.BackgroundColor3 = C.ACCENT
accentStripe.BorderSizePixel = 0
accentStripe.ZIndex          = 20
accentStripe.Parent          = mainPanel

-- ============================================================
-- TAB BAR  (dark header with slanted tab buttons)
-- ============================================================

local TAB_BAR_HEIGHT = 46

local tabBar              = Instance.new("Frame")
tabBar.Name               = "TabBar"
tabBar.Size               = UDim2.new(1, 0, 0, TAB_BAR_HEIGHT)
tabBar.Position           = UDim2.new(0, 0, 0, 3)
tabBar.BackgroundColor3   = C.TAB_BG
tabBar.BorderSizePixel    = 0
tabBar.ClipsDescendants   = true
tabBar.ZIndex             = 10
tabBar.Parent             = mainPanel

local currencyArea        = Instance.new("Frame")
currencyArea.Size         = UDim2.new(0, 280, 0, 32)
currencyArea.Position     = UDim2.new(1, -290, 0.5, -16)
currencyArea.BackgroundTransparency = 1
currencyArea.BorderSizePixel = 0
currencyArea.ZIndex       = 12
currencyArea.Parent       = tabBar

local coinsFrame          = Instance.new("Frame")
coinsFrame.Size           = UDim2.new(0, 120, 0, 28)
coinsFrame.Position       = UDim2.new(0, 0, 0.5, -14)
coinsFrame.BackgroundColor3 = Color3.fromRGB(60, 62, 78)
coinsFrame.BorderSizePixel = 0
coinsFrame.ZIndex         = 13
coinsFrame.Parent         = currencyArea
makeCorner(coinsFrame, 4)

local coinsIcon = makeLabel(coinsFrame, "🪙",
	UDim2.new(0, 24, 1, 0), UDim2.new(0, 4, 0, 0),
	C.GOLD, nil, 1)
coinsIcon.TextSize = 14
coinsIcon.TextXAlignment = Enum.TextXAlignment.Center
coinsIcon.ZIndex = 14

local coinsLabel = makeLabel(coinsFrame, "1,000",
	UDim2.new(1, -30, 1, 0), UDim2.new(0, 28, 0, 0),
	C.GOLD, nil, 1)
coinsLabel.TextSize = 13
coinsLabel.Font = Enum.Font.GothamBold
coinsLabel.ZIndex = 14

local gemsFrame           = Instance.new("Frame")
gemsFrame.Size            = UDim2.new(0, 100, 0, 28)
gemsFrame.Position        = UDim2.new(0, 130, 0.5, -14)
gemsFrame.BackgroundColor3 = Color3.fromRGB(60, 62, 78)
gemsFrame.BorderSizePixel = 0
gemsFrame.ZIndex          = 13
gemsFrame.Parent          = currencyArea
makeCorner(gemsFrame, 4)

local gemsIcon = makeLabel(gemsFrame, "💎",
	UDim2.new(0, 24, 1, 0), UDim2.new(0, 4, 0, 0),
	C.GEM, nil, 1)
gemsIcon.TextSize = 14
gemsIcon.TextXAlignment = Enum.TextXAlignment.Center
gemsIcon.ZIndex = 14

local gemsLabel = makeLabel(gemsFrame, "50",
	UDim2.new(1, -30, 1, 0), UDim2.new(0, 28, 0, 0),
	C.GEM, nil, 1)
gemsLabel.TextSize = 13
gemsLabel.Font = Enum.Font.GothamBold
gemsLabel.ZIndex = 14

local toggleBtn = makeButton(tabBar, "▶ START",
	UDim2.new(0, 90, 0, 28),
	UDim2.new(1, -390, 0.5, -14),
	C.GREEN, C.WHITE)
makeCorner(toggleBtn, 4)
toggleBtn.TextSize = 11
toggleBtn.ZIndex = 13

-- ============================================================
-- SLANTED TAB BUTTONS
-- ============================================================

local tabButtons = {}

local TAB_DEFS = {
	{ key = "inventory", label = "INVENTORY", icon = "🎒", order = 1 },
	{ key = "quests",    label = "QUESTS",    icon = "📜", order = 2 },
	{ key = "gacha",     label = "GACHA",     icon = "⭐",    order = 3 },
	}

local TAB_WIDTH = 140
local TAB_GAP   = 4

for i, def in ipairs(TAB_DEFS) do
	local tabContainer              = Instance.new("Frame")
	tabContainer.Name               = "Tab_" .. def.key
	tabContainer.Size               = UDim2.new(0, TAB_WIDTH, 0, TAB_BAR_HEIGHT)
	tabContainer.Position           = UDim2.new(0, (i - 1) * (TAB_WIDTH + TAB_GAP) + 12, 0, 0)
	tabContainer.BackgroundTransparency = 1
	tabContainer.ClipsDescendants   = true
	tabContainer.BorderSizePixel    = 0
	tabContainer.ZIndex             = 11
	tabContainer.Parent             = tabBar

	local slantBg              = Instance.new("Frame")
	slantBg.Name               = "SlantBg"
	slantBg.Size               = UDim2.new(1, 20, 1, 10)
	slantBg.Position           = UDim2.new(0.5, 0, 0.5, 0)
	slantBg.AnchorPoint        = Vector2.new(0.5, 0.5)
	slantBg.Rotation           = TAB_SLANT_DEGREES
	slantBg.BackgroundColor3   = C.PANEL2
	slantBg.BackgroundTransparency = 0.8
	slantBg.BorderSizePixel    = 0
	slantBg.ZIndex             = 11
	slantBg.Parent             = tabContainer

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
	tabLabel.Size             = UDim2.new(1, 0, 1, 0)
	tabLabel.BackgroundTransparency = 1
	tabLabel.Text             = def.icon .. "  " .. def.label
	tabLabel.TextColor3       = Color3.fromRGB(180, 182, 195)
	tabLabel.Font             = Enum.Font.GothamBold
	tabLabel.TextSize         = 13
	tabLabel.ZIndex           = 13
	tabLabel.Parent           = tabContainer

	local activeIndicator              = Instance.new("Frame")
	activeIndicator.Name               = "ActiveIndicator"
	activeIndicator.Size               = UDim2.new(0.7, 0, 0, 3)
	activeIndicator.Position           = UDim2.new(0.15, 0, 1, -3)
	activeIndicator.BackgroundColor3   = C.ACCENT
	activeIndicator.BorderSizePixel    = 0
	activeIndicator.Visible            = false
	activeIndicator.ZIndex             = 15
	activeIndicator.Parent             = tabContainer

	tabButtons[def.key] = {
		container = tabContainer,
		slantBg   = slantBg,
		button    = tabBtn,
		label     = tabLabel,
		indicator = activeIndicator,
		}
end

-- ============================================================
-- CONTENT AREA
-- ============================================================

local contentArea              = Instance.new("Frame")
contentArea.Name               = "ContentArea"
contentArea.Size               = UDim2.new(1, 0, 1, -(TAB_BAR_HEIGHT + 3))
contentArea.Position           = UDim2.new(0, 0, 0, TAB_BAR_HEIGHT + 3)
contentArea.BackgroundColor3   = C.BG
contentArea.BackgroundTransparency = 0
contentArea.BorderSizePixel    = 0
contentArea.ClipsDescendants   = true
contentArea.ZIndex             = 5
contentArea.Parent             = mainPanel

-- ============================================================
-- ARROW TOGGLE BUTTON
-- ============================================================

local arrowBtn              = Instance.new("TextButton")
arrowBtn.Name               = "ArrowToggle"
arrowBtn.Size               = UDim2.new(0, 60, 0, 30)
arrowBtn.Position           = UDim2.new(0.5, -30, 1, -36)
arrowBtn.BackgroundColor3   = C.TAB_BG
arrowBtn.BorderSizePixel    = 0
arrowBtn.Text               = "▲"
arrowBtn.TextColor3         = C.WHITE
arrowBtn.Font               = Enum.Font.GothamBold
arrowBtn.TextSize           = 18
arrowBtn.AutoButtonColor    = true
arrowBtn.ZIndex             = 30
arrowBtn.Parent             = screenGui
makeCorner(arrowBtn, 8)

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
towerListFrame.Size               = UDim2.new(0, 200, 1, -16)
towerListFrame.Position           = UDim2.new(0, 8, 0, 8)
towerListFrame.BackgroundColor3   = C.PANEL
towerListFrame.BorderSizePixel    = 0
towerListFrame.ClipsDescendants   = true
towerListFrame.ZIndex             = 7
towerListFrame.Parent             = invPanel
makeCorner(towerListFrame, 8)
makeStroke(towerListFrame, C.BORDER, 1, 0.3)

local towerListHeader = makeLabel(towerListFrame, "TOWERS",
	UDim2.new(1, 0, 0, 32),
	UDim2.new(0, 0, 0, 0),
	C.TEXTSUB, C.PANEL, 0)
towerListHeader.TextSize = 11
towerListHeader.TextXAlignment = Enum.TextXAlignment.Center
towerListHeader.ZIndex = 8
makeDivider(towerListHeader, true).Position = UDim2.new(0, 0, 1, 0)

local towerScrollFrame            = Instance.new("ScrollingFrame")
towerScrollFrame.Name             = "Scroll"
towerScrollFrame.Size             = UDim2.new(1, 0, 1, -32)
towerScrollFrame.Position         = UDim2.new(0, 0, 0, 32)
towerScrollFrame.BackgroundTransparency = 1
towerScrollFrame.BorderSizePixel  = 0
towerScrollFrame.ScrollBarThickness = 3
towerScrollFrame.ScrollBarImageColor3 = C.ACCENT
towerScrollFrame.CanvasSize       = UDim2.new(0, 0, 0, 0)
towerScrollFrame.ZIndex           = 8
towerScrollFrame.Parent           = towerListFrame

local towerScrollLayout           = Instance.new("UIListLayout")
towerScrollLayout.SortOrder       = Enum.SortOrder.LayoutOrder
towerScrollLayout.Padding         = UDim.new(0, 4)
towerScrollLayout.Parent          = towerScrollFrame

local towerViewer              = Instance.new("Frame")
towerViewer.Name               = "TowerViewer"
towerViewer.Size               = UDim2.new(1, -224, 1, -16)
towerViewer.Position           = UDim2.new(0, 216, 0, 8)
towerViewer.BackgroundColor3   = C.PANEL
towerViewer.BorderSizePixel    = 0
towerViewer.ZIndex             = 7
towerViewer.Parent             = invPanel
makeCorner(towerViewer, 8)
makeStroke(towerViewer, C.BORDER, 1, 0.3)

local portraitBox              = Instance.new("Frame")
portraitBox.Name               = "Portrait"
portraitBox.Size               = UDim2.new(0, 100, 0, 100)
portraitBox.Position           = UDim2.new(0.5, -50, 0, 14)
portraitBox.BackgroundColor3   = C.PANEL2
portraitBox.BorderSizePixel    = 0
portraitBox.ZIndex             = 8
portraitBox.Parent             = towerViewer
makeCorner(portraitBox, 10)
makeStroke(portraitBox, C.BORDER, 1, 0.2)

local portraitLabel = makeLabel(portraitBox, "?",
	UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
	C.TEXTDIM, nil, 1)
portraitLabel.TextSize = 36
portraitLabel.TextXAlignment = Enum.TextXAlignment.Center
portraitLabel.TextYAlignment = Enum.TextYAlignment.Center
portraitLabel.ZIndex = 9

local viewerName = makeLabel(towerViewer, "Select a tower",
	UDim2.new(1, -10, 0, 24),
	UDim2.new(0, 6, 0, 120),
	C.TEXT, nil, 1)
viewerName.TextSize = 16
viewerName.TextXAlignment = Enum.TextXAlignment.Center
viewerName.ZIndex = 8

local viewerRarity = makeLabel(towerViewer, "──────",
	UDim2.new(1, -10, 0, 18),
	UDim2.new(0, 6, 0, 146),
	C.TEXTSUB, nil, 1)
viewerRarity.TextSize = 12
viewerRarity.TextXAlignment = Enum.TextXAlignment.Center
viewerRarity.ZIndex = 8

local viewerDesc = Instance.new("TextLabel")
viewerDesc.Size               = UDim2.new(1, -16, 0, 60)
viewerDesc.Position           = UDim2.new(0, 8, 0, 170)
viewerDesc.BackgroundTransparency = 1
viewerDesc.Text               = "No tower selected.\nClick a tower from the list."
viewerDesc.TextColor3         = C.TEXTSUB
viewerDesc.Font               = Enum.Font.Gotham
viewerDesc.TextSize           = 12
viewerDesc.TextWrapped        = true
viewerDesc.TextXAlignment     = Enum.TextXAlignment.Left
viewerDesc.TextYAlignment     = Enum.TextYAlignment.Top
viewerDesc.ZIndex             = 8
viewerDesc.Parent             = towerViewer

local statsRow              = Instance.new("Frame")
statsRow.Name               = "StatsRow"
statsRow.Size               = UDim2.new(1, -16, 0, 48)
statsRow.Position           = UDim2.new(0, 8, 0, 236)
statsRow.BackgroundColor3   = C.PANEL2
statsRow.BorderSizePixel    = 0
statsRow.ZIndex             = 8
statsRow.Parent             = towerViewer
makeCorner(statsRow, 6)

local statsLayout           = Instance.new("UIListLayout")
statsLayout.FillDirection   = Enum.FillDirection.Horizontal
statsLayout.SortOrder       = Enum.SortOrder.LayoutOrder
statsLayout.Padding         = UDim.new(0, 0)
statsLayout.Parent          = statsRow

local TowerStats = require(ReplicatedStorage:WaitForChild("TowerStats", 30))

local function makeStatCell(parent, icon, statName, layoutOrder)
	local cell             = Instance.new("Frame")
	cell.Size              = UDim2.new(0.25, 0, 1, 0)
	cell.BackgroundTransparency = 1
	cell.BorderSizePixel   = 0
	cell.LayoutOrder       = layoutOrder
	cell.ZIndex            = 9
	cell.Parent            = parent

	local iconL = makeLabel(cell, icon, UDim2.new(1, 0, 0, 18),
		UDim2.new(0, 0, 0, 4), C.TEXTSUB, nil, 1)
	iconL.TextSize = 14
	iconL.TextXAlignment = Enum.TextXAlignment.Center
	iconL.ZIndex = 10

	local valL = makeLabel(cell, "–",
		UDim2.new(1, 0, 0, 16),
		UDim2.new(0, 0, 0, 24),
		C.TEXT, nil, 1)
	valL.Name = "Value"
	valL.TextSize = 12
	valL.Font = Enum.Font.GothamBold
	valL.TextXAlignment = Enum.TextXAlignment.Center
	valL.ZIndex = 10

	return valL
end

local statAtk  = makeStatCell(statsRow, "⚔️",  "ATK", 1)
local statRng  = makeStatCell(statsRow, "🎯",  "RNG", 2)
local statSpd  = makeStatCell(statsRow, "⚡",  "SPD", 3)
local statHP   = makeStatCell(statsRow, "❤️",  "HP",  4)

local equipHeader = makeLabel(towerViewer, "EQUIPMENT SLOTS",
	UDim2.new(1, -16, 0, 18),
	UDim2.new(0, 8, 0, 292),
	C.TEXTSUB, nil, 1)
equipHeader.TextSize = 10
equipHeader.ZIndex = 8

local equipRow              = Instance.new("Frame")
equipRow.Name               = "EquipRow"
equipRow.Size               = UDim2.new(1, -16, 0, 52)
equipRow.Position           = UDim2.new(0, 8, 0, 312)
equipRow.BackgroundTransparency = 1
equipRow.BorderSizePixel    = 0
equipRow.ZIndex             = 8
equipRow.Parent             = towerViewer

local equipSlotLabels = {}

local function buildEquipSlots(slotCount)
	for _, s in ipairs(equipSlotLabels) do
		s:Destroy()
	end
	equipSlotLabels = {}

	local slotW = 50
	local gap   = 6
	for i = 1, slotCount do
		local slot              = Instance.new("Frame")
		slot.Size               = UDim2.new(0, slotW, 0, 50)
		slot.Position           = UDim2.new(0, (i-1) * (slotW + gap), 0, 0)
		slot.BackgroundColor3   = C.PANEL2
		slot.BorderSizePixel    = 0
		slot.ZIndex             = 9
		slot.Parent             = equipRow
		makeCorner(slot, 6)
		makeStroke(slot, C.BORDER, 1, 0.2)

		local slotLabel = makeLabel(slot, "+",
			UDim2.new(1, 0, 1, 0),
			UDim2.new(0, 0, 0, 0),
			C.TEXTDIM, nil, 1)
		slotLabel.TextSize = 18
		slotLabel.TextXAlignment = Enum.TextXAlignment.Center
		slotLabel.TextYAlignment = Enum.TextYAlignment.Center
		slotLabel.ZIndex = 10
		table.insert(equipSlotLabels, slot)
	end
end

buildEquipSlots(0)

-- ============================================================
-- Build the tower list entries
-- ============================================================

local towerEntryButtons = {}

local function updateViewerForTower(towerName: string)
	selectedTower    = towerName
	local td         = TowerData.Towers[towerName]
	local ts         = TowerStats and TowerStats.Templates[towerName]
	local isUnlocked = unlockedTowers[towerName] == true

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
		entry.Size             = UDim2.new(1, -8, 0, 60)
		entry.BackgroundColor3 = isUnlocked and C.PANEL or C.PANEL2
		entry.BackgroundTransparency = 0.1
		entry.BorderSizePixel  = 0
		entry.ZIndex           = 9
		entry.LayoutOrder      = isUnlocked and 0 or 1
		entry.Parent           = towerScrollFrame
		makeCorner(entry, 6)
		makeStroke(entry, isUnlocked and C.ACCENT or C.BORDER, 1, isUnlocked and 0.5 or 0.4)

		local nameL = makeLabel(entry, td.displayName,
			UDim2.new(1, -10, 0, 18),
			UDim2.new(0, 8, 0, 8),
			isUnlocked and C.TEXT or C.TEXTDIM, nil, 1)
		nameL.TextSize = 13
		nameL.ZIndex = 10

		local rarityL = makeLabel(entry, rarityStars(td.rarity),
			UDim2.new(1, -10, 0, 14),
			UDim2.new(0, 8, 0, 28),
			rarityColor(td.rarity), nil, 1)
		rarityL.TextSize = 10
		rarityL.Font = Enum.Font.Gotham
		rarityL.ZIndex = 10

		if not isUnlocked then
			local lockL = makeLabel(entry, "🔒",
				UDim2.new(0, 24, 0, 24),
				UDim2.new(1, -30, 0.5, -12),
				C.RED, nil, 1)
			lockL.TextSize = 16
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
				b.BackgroundTransparency = n == name and 0.05 or 0.3
			end
		end)

		towerEntryButtons[name] = entry
		totalH = totalH + 64
	end

	towerScrollFrame.CanvasSize = UDim2.new(0, 0, 0, totalH)
end

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
questTabBar.Size              = UDim2.new(1, 0, 0, 36)
questTabBar.BackgroundColor3  = C.PANEL
questTabBar.BackgroundTransparency = 0
questTabBar.BorderSizePixel   = 0
questTabBar.ZIndex            = 7
questTabBar.Parent            = questPanel

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
questScrollContainer.Size               = UDim2.new(1, 0, 1, -36)
questScrollContainer.Position           = UDim2.new(0, 0, 0, 36)
questScrollContainer.BackgroundTransparency = 1
questScrollContainer.BorderSizePixel    = 0
questScrollContainer.ZIndex             = 7
questScrollContainer.Parent             = questPanel

for _, tabDef in ipairs(tabDefs) do
	local key = tabDef.key

	local tabBtn              = Instance.new("TextButton")
	tabBtn.Size               = UDim2.new(0, 160, 1, 0)
	tabBtn.BackgroundColor3   = C.PANEL2
	tabBtn.BackgroundTransparency = 0.2
	tabBtn.BorderSizePixel    = 0
	tabBtn.Text               = tabDef.label
	tabBtn.TextColor3         = C.TEXTSUB
	tabBtn.Font               = Enum.Font.GothamBold
	tabBtn.TextSize           = 12
	tabBtn.AutoButtonColor    = false
	tabBtn.LayoutOrder        = tabDef.layoutOrder
	tabBtn.ZIndex             = 8
	tabBtn.Parent             = questTabBar
	questTabBtns[key]         = tabBtn

	local scroll              = Instance.new("ScrollingFrame")
	scroll.Name               = key .. "Scroll"
	scroll.Size               = UDim2.new(1, 0, 1, 0)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel    = 0
	scroll.ScrollBarThickness = 3
	scroll.ScrollBarImageColor3 = C.ACCENT
	scroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
	scroll.Visible            = (key == "Daily")
	scroll.ZIndex             = 8
	scroll.Parent             = questScrollContainer

	local scrollLayout        = Instance.new("UIListLayout")
	scrollLayout.SortOrder    = Enum.SortOrder.LayoutOrder
	scrollLayout.Padding      = UDim.new(0, 6)
	scrollLayout.Parent       = scroll

	local scrollPad           = Instance.new("UIPadding")
	scrollPad.PaddingTop      = UDim.new(0, 8)
	scrollPad.PaddingLeft     = UDim.new(0, 8)
	scrollPad.PaddingRight    = UDim.new(0, 8)
	scrollPad.Parent          = scroll

	questScrolls[key] = scroll

	local quests  = TowerData.Quests[key] or {}
	local totalH  = 8
	for _, quest in ipairs(quests) do
		local card              = Instance.new("Frame")
		card.Name               = quest.id
		card.Size               = UDim2.new(1, 0, 0, 80)
		card.BackgroundColor3   = C.PANEL
		card.BackgroundTransparency = 0
		card.BorderSizePixel    = 0
		card.ZIndex             = 9
		card.Parent             = scroll
		makeCorner(card, 8)
		makeStroke(card, C.BORDER, 1, 0.3)

		local qname = makeLabel(card, quest.displayName,
			UDim2.new(1, -100, 0, 20),
			UDim2.new(0, 10, 0, 8),
			C.TEXT, nil, 1)
		qname.TextSize = 14
		qname.ZIndex = 10

		local qdesc = makeLabel(card, quest.description,
			UDim2.new(1, -100, 0, 28),
			UDim2.new(0, 10, 0, 28),
			C.TEXTSUB, nil, 1)
		qdesc.TextSize = 11
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
			UDim2.new(1, -120, 0, 16),
			UDim2.new(0, 10, 0, 58),
			C.GOLD, nil, 1)
		rewardL.TextSize = 11
		rewardL.Font = Enum.Font.Gotham
		rewardL.ZIndex = 10

		local progBg              = Instance.new("Frame")
		progBg.Size               = UDim2.new(0, 100, 0, 8)
		progBg.Position           = UDim2.new(1, -110, 0, 12)
		progBg.BackgroundColor3   = C.PANEL2
		progBg.BorderSizePixel    = 0
		progBg.ZIndex             = 10
		progBg.Parent             = card
		makeCorner(progBg, 4)

		local progFill            = Instance.new("Frame")
		progFill.Size             = UDim2.new(0, 0, 1, 0)
		progFill.BackgroundColor3 = C.GREEN
		progFill.BorderSizePixel  = 0
		progFill.ZIndex           = 11
		progFill.Parent           = progBg
		makeCorner(progFill, 4)

		local progText = makeLabel(card, "0 / " .. quest.goal,
			UDim2.new(0, 100, 0, 14),
			UDim2.new(1, -110, 0, 24),
			C.TEXTSUB, nil, 1)
		progText.TextSize = 10
		progText.TextXAlignment = Enum.TextXAlignment.Center
		progText.ZIndex = 10

		local claimBtn = makeButton(card, "Claim",
			UDim2.new(0, 90, 0, 26),
			UDim2.new(1, -102, 1, -34),
			C.TEXTDIM, C.TEXT)
		claimBtn.TextSize = 12
		claimBtn.ZIndex = 10
		makeCorner(claimBtn, 5)

		totalH = totalH + 86
	end
	scroll.CanvasSize = UDim2.new(0, 0, 0, totalH)
end

local function switchQuestTab(key: string)
	activeQuestTab = key
	for k, scroll in pairs(questScrolls) do
		scroll.Visible = (k == key)
	end
	for k, btn in pairs(questTabBtns) do
		if k == key then
			btn.BackgroundTransparency = 0
			btn.TextColor3 = C.ACCENT
			btn.BackgroundColor3 = C.PANEL
		else
			btn.BackgroundTransparency = 0.2
			btn.TextColor3 = C.TEXTSUB
			btn.BackgroundColor3 = C.PANEL2
		end
	end
end

for k, btn in pairs(questTabBtns) do
	btn.MouseButton1Click:Connect(function()
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
bannerRow.Size               = UDim2.new(1, -16, 0, 60)
bannerRow.Position           = UDim2.new(0, 8, 0, 8)
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
	bBtn.BackgroundColor3   = isActive and C.ACCENT or C.PANEL
	bBtn.BackgroundTransparency = isActive and 0.1 or 0
	bBtn.BorderSizePixel    = 0
	bBtn.Text               = ""
	bBtn.AutoButtonColor    = false
	bBtn.ZIndex             = 8
	bBtn.Parent             = bannerRow
	makeCorner(bBtn, 8)
	local bStroke = makeStroke(bBtn, isActive and C.ACCENT or C.BORDER, 1, isActive and 0.2 or 0.4)

	local bName = makeLabel(bBtn, bData.displayName,
		UDim2.new(1, -10, 0, 20),
		UDim2.new(0, 10, 0, 8),
		isActive and C.WHITE or C.TEXT, nil, 1)
	bName.TextSize = 13
	bName.ZIndex = 9

	local bType = makeLabel(bBtn, bKey == "special" and "⭐ RATE-UP BANNER" or "📦 STANDARD",
		UDim2.new(1, -10, 0, 16),
		UDim2.new(0, 10, 0, 30),
		bKey == "special" and C.GOLD or C.TEXTSUB, nil, 1)
	bType.TextSize = 10
	bType.ZIndex = 9

	bannerBtns[bKey] = { button = bBtn, nameLabel = bName, typeLabel = bType, stroke = bStroke }
end

local bannerDesc              = Instance.new("TextLabel")
bannerDesc.Size               = UDim2.new(1, -16, 0, 56)
bannerDesc.Position           = UDim2.new(0, 8, 0, 76)
bannerDesc.BackgroundColor3   = C.PANEL
bannerDesc.BackgroundTransparency = 0
bannerDesc.BorderSizePixel    = 0
bannerDesc.Text               = TowerData.Banners.standard.description
bannerDesc.TextColor3         = C.TEXTSUB
bannerDesc.Font               = Enum.Font.Gotham
bannerDesc.TextSize           = 11
bannerDesc.TextWrapped        = true
bannerDesc.TextXAlignment     = Enum.TextXAlignment.Left
bannerDesc.TextYAlignment     = Enum.TextYAlignment.Top
bannerDesc.ZIndex             = 7
bannerDesc.Parent             = gachaPanel
makeCorner(bannerDesc, 8)
makeStroke(bannerDesc, C.BORDER, 1, 0.3)

local descPad = Instance.new("UIPadding")
descPad.PaddingTop   = UDim.new(0, 6)
descPad.PaddingLeft  = UDim.new(0, 8)
descPad.PaddingRight = UDim.new(0, 8)
descPad.Parent       = bannerDesc

local rateUpLabel             = makeLabel(gachaPanel, "Rate-Up: Deadeye",
	UDim2.new(1, -16, 0, 20),
	UDim2.new(0, 8, 0, 138),
	C.GOLD, nil, 1)
rateUpLabel.TextSize = 12
rateUpLabel.Visible = (activeBanner == "special")
rateUpLabel.ZIndex = 7

local pityLabel               = makeLabel(gachaPanel, "Pity: 0 / 70  (Gem pulls only)",
	UDim2.new(1, -16, 0, 18),
	UDim2.new(0, 8, 0, 162),
	C.TEXTSUB, nil, 1)
pityLabel.TextSize = 11
pityLabel.Font = Enum.Font.Gotham
pityLabel.ZIndex = 7

local pullRow               = Instance.new("Frame")
pullRow.Size                = UDim2.new(1, -16, 0, 46)
pullRow.Position            = UDim2.new(0, 8, 0, 188)
pullRow.BackgroundTransparency = 1
pullRow.BorderSizePixel     = 0
pullRow.ZIndex              = 7
pullRow.Parent              = gachaPanel

local gem1Btn = makeButton(pullRow, "💎 ×1  (160)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0, 0, 0, 0),
	C.GEM, C.WHITE)
makeCorner(gem1Btn, 6)
gem1Btn.TextSize = 12
gem1Btn.ZIndex = 8

local gem10Btn = makeButton(pullRow, "💎 ×10  (1,600)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0.25, 4, 0, 0),
	C.GEM, C.WHITE)
makeCorner(gem10Btn, 6)
gem10Btn.TextSize = 12
gem10Btn.ZIndex = 8

local coin1Btn = makeButton(pullRow, "🪙 ×1  (1,000)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0.5, 4, 0, 0),
	Color3.fromRGB(200, 170, 80), C.TEXT)
makeCorner(coin1Btn, 6)
coin1Btn.TextSize = 12
coin1Btn.ZIndex = 8

local coin10Btn = makeButton(pullRow, "🪙 ×10  (10,000)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0.75, 8, 0, 0),
	Color3.fromRGB(200, 170, 80), C.TEXT)
makeCorner(coin10Btn, 6)
coin10Btn.TextSize = 12
coin10Btn.ZIndex = 8

local noPityNote = makeLabel(gachaPanel, "⚠ Coin pulls do not count toward pity.",
	UDim2.new(1, -16, 0, 16),
	UDim2.new(0, 8, 0, 240),
	C.RED, nil, 1)
noPityNote.TextSize = 10
noPityNote.Font = Enum.Font.Gotham
noPityNote.ZIndex = 7

local resultsHeader = makeLabel(gachaPanel, "RECENT PULLS",
	UDim2.new(1, -16, 0, 18),
	UDim2.new(0, 8, 0, 264),
	C.TEXTSUB, nil, 1)
resultsHeader.TextSize = 10
resultsHeader.ZIndex = 7

local resultsScroll              = Instance.new("ScrollingFrame")
resultsScroll.Name               = "ResultsScroll"
resultsScroll.Size               = UDim2.new(1, -16, 1, -294)
resultsScroll.Position           = UDim2.new(0, 8, 0, 286)
resultsScroll.BackgroundColor3   = C.PANEL
resultsScroll.BackgroundTransparency = 0
resultsScroll.BorderSizePixel    = 0
resultsScroll.ScrollBarThickness = 3
resultsScroll.ScrollBarImageColor3 = C.ACCENT
resultsScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
resultsScroll.ZIndex             = 7
resultsScroll.Parent             = gachaPanel
makeCorner(resultsScroll, 8)
makeStroke(resultsScroll, C.BORDER, 1, 0.3)

local resultsLayout              = Instance.new("UIListLayout")
resultsLayout.FillDirection      = Enum.FillDirection.Horizontal
resultsLayout.SortOrder          = Enum.SortOrder.LayoutOrder
resultsLayout.Padding            = UDim.new(0, 6)
resultsLayout.Wraps              = true
resultsLayout.Parent             = resultsScroll

local resultsPad                 = Instance.new("UIPadding")
resultsPad.PaddingTop            = UDim.new(0, 6)
resultsPad.PaddingLeft           = UDim.new(0, 6)
resultsPad.PaddingRight          = UDim.new(0, 6)
resultsPad.Parent                = resultsScroll

local resultCards = {}

local function addResultCard(towerName: string, rarity: string, isNew: boolean)
	local td     = TowerData.Towers[towerName]
	local rColor = rarityColor(rarity)

	local card              = Instance.new("Frame")
	card.Size               = UDim2.new(0, 72, 0, 80)
	card.BackgroundColor3   = C.PANEL
	card.BorderSizePixel    = 0
	card.LayoutOrder        = -(#resultCards)
	card.ZIndex             = 8
	card.Parent             = resultsScroll
	makeCorner(card, 8)
	makeStroke(card, rColor, 2, 0)

	local icon = makeLabel(card, td and td.displayName:sub(1,2) or "??",
		UDim2.new(1, 0, 0, 40),
		UDim2.new(0, 0, 0, 4),
		rColor, nil, 1)
	icon.TextSize = 18
	icon.TextXAlignment = Enum.TextXAlignment.Center
	icon.ZIndex = 9

	local nameL = makeLabel(card, td and td.displayName or towerName,
		UDim2.new(1, -4, 0, 24),
		UDim2.new(0, 2, 0, 44),
		C.TEXT, nil, 1)
	nameL.TextSize = 10
	nameL.TextWrapped = true
	nameL.TextXAlignment = Enum.TextXAlignment.Center
	nameL.ZIndex = 9

	if isNew then
		local newTag = makeLabel(card, "NEW",
			UDim2.new(1, 0, 0, 16),
			UDim2.new(0, 0, 0, 64),
			C.GREEN, nil, 1)
		newTag.TextSize = 10
		newTag.Font = Enum.Font.GothamBold
		newTag.TextXAlignment = Enum.TextXAlignment.Center
		newTag.ZIndex = 9
	end

	table.insert(resultCards, card)
	local contentH = math.ceil(#resultCards / 6) * 92 + 12
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
		info.button.BackgroundColor3 = isActive and C.ACCENT or C.PANEL
		info.button.BackgroundTransparency = isActive and 0.1 or 0
		info.nameLabel.TextColor3 = isActive and C.WHITE or C.TEXT
		if info.stroke then
			info.stroke.Color = isActive and C.ACCENT or C.BORDER
			info.stroke.Transparency = isActive and 0.2 or 0.4
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
		if res.isNew then
			unlockedTowers[res.tower] = true
			buildTowerListEntries()
		end
	end
end)

-- ============================================================
-- PANEL SWITCHING LOGIC
-- ============================================================

local panels = {
	inventory = { frame = invPanel,   title = "INVENTORY" },
	quests    = { frame = questPanel, title = "QUESTS"    },
	gacha     = { frame = gachaPanel, title = "GACHA"     },
	}

local function setTabActive(key: string | nil)
	for k, info in pairs(tabButtons) do
		local isActive = (k == key)
		info.indicator.Visible = isActive
		info.slantBg.BackgroundColor3     = isActive and C.ACCENT or C.PANEL2
		info.slantBg.BackgroundTransparency = isActive and 0.15 or 0.8
		info.label.TextColor3 = isActive and C.WHITE or Color3.fromRGB(180, 182, 195)
	end
end

local function openPanel(key: string)
	if activePanel == key then
		return
	end
	activePanel = key
	for k, p in pairs(panels) do
		p.frame.Visible = (k == key)
	end
	setTabActive(key)

	if key == "inventory" then
		buildTowerListEntries()
	end
end

-- ============================================================
-- SLIDE ANIMATION  +  CAMERA MANIPULATION
-- ============================================================

local camera = Workspace.CurrentCamera
local originalCameraType = nil
local originalCameraCF   = nil

local SLIDE_TIME = 0.5
local TWEEN_INFO = TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function slideOpen()
	panelOpen = true
	arrowBtn.Text = "▼"

	local targetPos = UDim2.new(0, 0, 1 - PANEL_HEIGHT, 0)
	TweenService:Create(mainPanel, TWEEN_INFO, { Position = targetPos }):Play()

	local arrowTarget = UDim2.new(0.5, -30, 1 - PANEL_HEIGHT, -36)
	TweenService:Create(arrowBtn, TWEEN_INFO, { Position = arrowTarget }):Play()

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
		openPanel("inventory")
	end
end

local function restoreCameraType()
	camera.CameraType = originalCameraType or Enum.CameraType.Custom
end

local function slideClose()
	panelOpen = false
	arrowBtn.Text = "▲"

	TweenService:Create(mainPanel, TWEEN_INFO, { Position = UDim2.new(0, 0, 1, 0) }):Play()
	TweenService:Create(arrowBtn, TWEEN_INFO, { Position = UDim2.new(0.5, -30, 1, -36) }):Play()

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
	if panelOpen then
		slideClose()
	else
		slideOpen()
	end
end

arrowBtn.MouseButton1Click:Connect(togglePanel)

for key, info in pairs(tabButtons) do
	info.button.MouseButton1Click:Connect(function()
		if not panelOpen then
			slideOpen()
		end
		openPanel(key)
	end)
end

-- ============================================================
-- CURRENCY UPDATE HANDLER
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

-- ============================================================
-- GAME STATE TOGGLE
-- ============================================================

local function updateToggleBtn(state: string)
	if state == "InRound" then
		toggleBtn.Text = "⏹ STOP"
		toggleBtn.BackgroundColor3 = C.RED
		if panelOpen then
			slideClose()
		end
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