--[[
	LobbyGui (LocalScript)
	Place in StarterGui/

	Implements all three main out-of-round GUIs:
	  • INVENTORY  – tower/equipment viewer and shop
	  • QUESTS     – daily / weekly / challenge quest tabs
	  • GACHA      – standard and special banner pull system

	Also renders the currency HUD (Coins + Gems) and a temporary
	"Start/Stop Round" toggle button for testing the lobby ↔ in-round switch.

	This script is completely separate from the in-round HUD scripts
	(TowerHUD, TowerPlacement, DamageIndicatorClient, EnemyViewingClient).
	The lobby panels are hidden automatically when the game state is "InRound".
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

-- Player's unlocked towers (starts with Warrior free; updated from server data)
local unlockedTowers  = { Warrior = true }

-- Equipment owned
local ownedEquipment  = {}

-- Currently-selected tower in Inventory
local selectedTower   = nil

-- Active quest tab
local activeQuestTab  = "Daily"

-- ============================================================
-- COLOUR PALETTE  (shared across all panels)
-- ============================================================

local C = {
	BG        = Color3.fromRGB(22,  24,  32),   -- deepest background
	PANEL     = Color3.fromRGB(30,  33,  44),   -- panel background
	PANEL2    = Color3.fromRGB(38,  42,  56),   -- secondary panel layer
	BORDER    = Color3.fromRGB(60,  65,  90),   -- border lines
	ACCENT    = Color3.fromRGB(80, 140, 255),   -- primary accent (blue)
	ACCENT2   = Color3.fromRGB(120, 80, 220),   -- secondary accent (purple)
	GREEN     = Color3.fromRGB(60,  200, 100),  -- positive / unlocked
	RED       = Color3.fromRGB(220, 70,  70),   -- negative / locked
	GOLD      = Color3.fromRGB(255, 195, 50),   -- coins colour
	GEM       = Color3.fromRGB(140, 80,  255),  -- gems colour
	TEXT      = Color3.fromRGB(220, 220, 230),  -- primary text
	TEXTSUB   = Color3.fromRGB(150, 155, 170),  -- secondary text
	TEXTDIM   = Color3.fromRGB(90,  95,  115),  -- dimmed text
	WHITE     = Color3.fromRGB(255, 255, 255),
	BLACK     = Color3.fromRGB(0,   0,   0),
}

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
	d.BackgroundTransparency = 0.4
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
-- TOP-BAR: CURRENCY HUD
-- ============================================================

local topBar              = Instance.new("Frame")
topBar.Name               = "TopBar"
topBar.Size               = UDim2.new(1, 0, 0, 44)
topBar.Position           = UDim2.new(0, 0, 0, 0)
topBar.BackgroundColor3   = C.BG
topBar.BackgroundTransparency = 0.1
topBar.BorderSizePixel    = 0
topBar.ZIndex             = 20
topBar.Parent             = screenGui

makeStroke(topBar, C.BORDER, 1, 0.5)

-- Coins display (right side)
local coinsFrame          = Instance.new("Frame")
coinsFrame.Size           = UDim2.new(0, 140, 0, 30)
coinsFrame.Position       = UDim2.new(1, -300, 0.5, -15)
coinsFrame.BackgroundColor3 = C.PANEL2
coinsFrame.BorderSizePixel = 0
coinsFrame.Parent         = topBar
makeCorner(coinsFrame, 6)
makeStroke(coinsFrame, C.GOLD, 1, 0.3)

local coinsIcon = makeLabel(coinsFrame, "🪙", UDim2.new(0, 26, 1, 0), UDim2.new(0, 4, 0, 0), C.GOLD, nil, 1)
coinsIcon.TextSize = 16
coinsIcon.TextXAlignment = Enum.TextXAlignment.Center

local coinsLabel = makeLabel(coinsFrame, "1,000", UDim2.new(1, -34, 1, 0), UDim2.new(0, 32, 0, 0), C.GOLD, nil, 1)
coinsLabel.TextSize = 14
coinsLabel.Font = Enum.Font.GothamBold

-- Gems display
local gemsFrame           = Instance.new("Frame")
gemsFrame.Size            = UDim2.new(0, 120, 0, 30)
gemsFrame.Position        = UDim2.new(1, -160, 0.5, -15)
gemsFrame.BackgroundColor3 = C.PANEL2
gemsFrame.BorderSizePixel = 0
gemsFrame.Parent          = topBar
makeCorner(gemsFrame, 6)
makeStroke(gemsFrame, C.GEM, 1, 0.3)

local gemsIcon = makeLabel(gemsFrame, "💎", UDim2.new(0, 26, 1, 0), UDim2.new(0, 4, 0, 0), C.GEM, nil, 1)
gemsIcon.TextSize = 16
gemsIcon.TextXAlignment = Enum.TextXAlignment.Center

local gemsLabel = makeLabel(gemsFrame, "50", UDim2.new(1, -34, 1, 0), UDim2.new(0, 32, 0, 0), C.GEM, nil, 1)
gemsLabel.TextSize = 14
gemsLabel.Font = Enum.Font.GothamBold

-- Game-state toggle button (temporary testing)
local toggleBtn = makeButton(topBar, "▶ Start Round",
	UDim2.new(0, 140, 0, 30),
	UDim2.new(1, -460, 0.5, -15),
	C.GREEN, C.WHITE)
makeCorner(toggleBtn, 6)

-- ============================================================
-- LEFT NAVIGATION BAR
-- ============================================================

local NAV_WIDTH  = 54
local NAV_TOP    = 44   -- below top bar

local navBar              = Instance.new("Frame")
navBar.Name               = "NavBar"
navBar.Size               = UDim2.new(0, NAV_WIDTH, 1, -NAV_TOP)
navBar.Position           = UDim2.new(0, 0, 0, NAV_TOP)
navBar.BackgroundColor3   = C.BG
navBar.BackgroundTransparency = 0.05
navBar.BorderSizePixel    = 0
navBar.ZIndex             = 10
navBar.Parent             = screenGui

makeStroke(navBar, C.BORDER, 1, 0.4)

-- Navigation button factory
local navButtons = {}
local function makeNavBtn(icon, label, yOffset, panelKey)
	local btn              = Instance.new("TextButton")
	btn.Size               = UDim2.new(1, 0, 0, 54)
	btn.Position           = UDim2.new(0, 0, 0, yOffset)
	btn.BackgroundColor3   = C.PANEL
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel    = 0
	btn.Text               = ""
	btn.AutoButtonColor    = false
	btn.ZIndex             = 11
	btn.Parent             = navBar

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Size              = UDim2.new(1, 0, 0, 28)
	iconLabel.Position          = UDim2.new(0, 0, 0, 6)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text              = icon
	iconLabel.TextSize          = 22
	iconLabel.Font              = Enum.Font.GothamBold
	iconLabel.TextColor3        = C.TEXTSUB
	iconLabel.TextXAlignment    = Enum.TextXAlignment.Center
	iconLabel.ZIndex            = 12
	iconLabel.Parent            = btn

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size              = UDim2.new(1, 0, 0, 14)
	nameLabel.Position          = UDim2.new(0, 0, 0, 36)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text              = label
	nameLabel.TextSize          = 9
	nameLabel.Font              = Enum.Font.Gotham
	nameLabel.TextColor3        = C.TEXTDIM
	nameLabel.TextXAlignment    = Enum.TextXAlignment.Center
	nameLabel.ZIndex            = 12
	nameLabel.Parent            = btn

	-- Active indicator (left bar)
	local activeBar            = Instance.new("Frame")
	activeBar.Name             = "ActiveBar"
	activeBar.Size             = UDim2.new(0, 3, 0, 36)
	activeBar.Position         = UDim2.new(0, 0, 0.5, -18)
	activeBar.BackgroundColor3 = C.ACCENT
	activeBar.BorderSizePixel  = 0
	activeBar.Visible          = false
	activeBar.ZIndex           = 13
	activeBar.Parent           = btn

	navButtons[panelKey] = {
		button    = btn,
		iconLabel = iconLabel,
		nameLabel = nameLabel,
		activeBar = activeBar,
	}
	return btn
end

local btnInventory = makeNavBtn("🎒", "INVENTORY", 8,   "inventory")
local btnQuests    = makeNavBtn("📜", "QUESTS",    70,  "quests")
local btnGacha     = makeNavBtn("⭐", "GACHA",     132, "gacha")

-- ============================================================
-- PANEL CONTAINER
-- ============================================================

local PANEL_X      = NAV_WIDTH
local PANEL_Y      = NAV_TOP
local PANEL_WIDTH  = 540
local PANEL_HEIGHT_FULL = 0  -- computed below

local panelContainer              = Instance.new("Frame")
panelContainer.Name               = "PanelContainer"
panelContainer.Size               = UDim2.new(0, PANEL_WIDTH, 1, -PANEL_Y)
panelContainer.Position           = UDim2.new(0, PANEL_X, 0, PANEL_Y)
panelContainer.BackgroundColor3   = C.PANEL
panelContainer.BackgroundTransparency = 0.04
panelContainer.BorderSizePixel    = 0
panelContainer.ClipsDescendants   = true
panelContainer.Visible            = false
panelContainer.ZIndex             = 5
panelContainer.Parent             = screenGui

makeStroke(panelContainer, C.BORDER, 1, 0.3)

-- Panel header
local panelHeader             = Instance.new("Frame")
panelHeader.Name              = "Header"
panelHeader.Size              = UDim2.new(1, 0, 0, 42)
panelHeader.BackgroundColor3  = C.BG
panelHeader.BackgroundTransparency = 0.1
panelHeader.BorderSizePixel   = 0
panelHeader.ZIndex            = 6
panelHeader.Parent            = panelContainer

local panelTitle = makeLabel(panelHeader, "INVENTORY",
	UDim2.new(1, -50, 1, 0),
	UDim2.new(0, 14, 0, 0),
	C.WHITE, nil, 1)
panelTitle.TextSize = 15

local closeBtn = makeButton(panelHeader, "✕",
	UDim2.new(0, 34, 0, 34),
	UDim2.new(1, -42, 0.5, -17),
	C.RED, C.WHITE)
makeCorner(closeBtn, 4)
closeBtn.TextSize = 14

makeDivider(panelHeader, true).Position = UDim2.new(0, 0, 1, -1)

-- ============================================================
-- ============================================================
-- INVENTORY PANEL
-- ============================================================
-- ============================================================

local invPanel              = Instance.new("Frame")
invPanel.Name               = "InventoryPanel"
invPanel.Size               = UDim2.new(1, 0, 1, -42)
invPanel.Position           = UDim2.new(0, 0, 0, 42)
invPanel.BackgroundTransparency = 1
invPanel.BorderSizePixel    = 0
invPanel.Visible            = false
invPanel.ZIndex             = 6
invPanel.Parent             = panelContainer

-- ---- Left column: tower list --------------------------------
local towerListFrame              = Instance.new("Frame")
towerListFrame.Name               = "TowerList"
towerListFrame.Size               = UDim2.new(0, 180, 1, -8)
towerListFrame.Position           = UDim2.new(0, 6, 0, 4)
towerListFrame.BackgroundColor3   = C.PANEL2
towerListFrame.BorderSizePixel    = 0
towerListFrame.ClipsDescendants   = true
towerListFrame.ZIndex             = 7
towerListFrame.Parent             = invPanel
makeCorner(towerListFrame, 6)
makeStroke(towerListFrame, C.BORDER, 1, 0.4)

local towerListHeader = makeLabel(towerListFrame, "TOWERS",
	UDim2.new(1, 0, 0, 28),
	UDim2.new(0, 0, 0, 0),
	C.TEXTSUB, C.BG, 0.3)
towerListHeader.TextSize = 10
towerListHeader.TextXAlignment = Enum.TextXAlignment.Center
makeDivider(towerListHeader, true).Position = UDim2.new(0, 0, 1, 0)

local towerScrollFrame            = Instance.new("ScrollingFrame")
towerScrollFrame.Name             = "Scroll"
towerScrollFrame.Size             = UDim2.new(1, 0, 1, -28)
towerScrollFrame.Position         = UDim2.new(0, 0, 0, 28)
towerScrollFrame.BackgroundTransparency = 1
towerScrollFrame.BorderSizePixel  = 0
towerScrollFrame.ScrollBarThickness = 3
towerScrollFrame.ScrollBarImageColor3 = C.ACCENT
towerScrollFrame.CanvasSize       = UDim2.new(0, 0, 0, 0)
towerScrollFrame.ZIndex           = 8
towerScrollFrame.Parent           = towerListFrame

local towerScrollLayout           = Instance.new("UIListLayout")
towerScrollLayout.SortOrder       = Enum.SortOrder.LayoutOrder
towerScrollLayout.Padding         = UDim.new(0, 3)
towerScrollLayout.Parent          = towerScrollFrame

-- ---- Right column: tower viewer -----------------------------
local towerViewer              = Instance.new("Frame")
towerViewer.Name               = "TowerViewer"
towerViewer.Size               = UDim2.new(1, -194, 1, -8)
towerViewer.Position           = UDim2.new(0, 192, 0, 4)
towerViewer.BackgroundColor3   = C.PANEL2
towerViewer.BorderSizePixel    = 0
towerViewer.ZIndex             = 7
towerViewer.Parent             = invPanel
makeCorner(towerViewer, 6)
makeStroke(towerViewer, C.BORDER, 1, 0.4)

-- Portrait box
local portraitBox              = Instance.new("Frame")
portraitBox.Name               = "Portrait"
portraitBox.Size               = UDim2.new(0, 100, 0, 100)
portraitBox.Position           = UDim2.new(0.5, -50, 0, 12)
portraitBox.BackgroundColor3   = C.BG
portraitBox.BorderSizePixel    = 0
portraitBox.ZIndex             = 8
portraitBox.Parent             = towerViewer
makeCorner(portraitBox, 8)
makeStroke(portraitBox, C.BORDER, 1, 0.3)

local portraitLabel = makeLabel(portraitBox, "?",
	UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
	C.TEXTDIM, nil, 1)
portraitLabel.TextSize = 36
portraitLabel.TextXAlignment = Enum.TextXAlignment.Center
portraitLabel.TextYAlignment = Enum.TextYAlignment.Center

-- Tower name in viewer
local viewerName = makeLabel(towerViewer, "Select a tower",
	UDim2.new(1, -10, 0, 22),
	UDim2.new(0, 6, 0, 118),
	C.WHITE, nil, 1)
viewerName.TextSize = 16
viewerName.TextXAlignment = Enum.TextXAlignment.Center

-- Rarity stars
local viewerRarity = makeLabel(towerViewer, "──────",
	UDim2.new(1, -10, 0, 18),
	UDim2.new(0, 6, 0, 142),
	C.TEXTSUB, nil, 1)
viewerRarity.TextSize = 12
viewerRarity.TextXAlignment = Enum.TextXAlignment.Center

-- Description
local viewerDesc = Instance.new("TextLabel")
viewerDesc.Size               = UDim2.new(1, -16, 0, 70)
viewerDesc.Position           = UDim2.new(0, 8, 0, 166)
viewerDesc.BackgroundTransparency = 1
viewerDesc.Text               = "No tower selected.\nClick a tower from the list on the left."
viewerDesc.TextColor3         = C.TEXTSUB
viewerDesc.Font               = Enum.Font.Gotham
viewerDesc.TextSize           = 12
viewerDesc.TextWrapped        = true
viewerDesc.TextXAlignment     = Enum.TextXAlignment.Left
viewerDesc.TextYAlignment     = Enum.TextYAlignment.Top
viewerDesc.ZIndex             = 8
viewerDesc.Parent             = towerViewer

-- Stats row
local statsRow              = Instance.new("Frame")
statsRow.Name               = "StatsRow"
statsRow.Size               = UDim2.new(1, -16, 0, 48)
statsRow.Position           = UDim2.new(0, 8, 0, 240)
statsRow.BackgroundColor3   = C.BG
statsRow.BorderSizePixel    = 0
statsRow.ZIndex             = 8
statsRow.Parent             = towerViewer
makeCorner(statsRow, 5)

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

	local valL = makeLabel(cell, "–",
		UDim2.new(1, 0, 0, 16),
		UDim2.new(0, 0, 0, 22),
		C.WHITE, nil, 1)
	valL.Name = "Value"
	valL.TextSize = 12
	valL.Font = Enum.Font.GothamBold
	valL.TextXAlignment = Enum.TextXAlignment.Center

	return valL   -- return the value label so caller can update it
end

local statAtk  = makeStatCell(statsRow, "⚔️",  "ATK", 1)
local statRng  = makeStatCell(statsRow, "🎯",  "RNG", 2)
local statSpd  = makeStatCell(statsRow, "⚡",  "SPD", 3)
local statHP   = makeStatCell(statsRow, "❤️",  "HP",  4)

-- Equipment slots section
local equipHeader = makeLabel(towerViewer, "EQUIPMENT SLOTS",
	UDim2.new(1, -16, 0, 18),
	UDim2.new(0, 8, 0, 298),
	C.TEXTSUB, nil, 1)
equipHeader.TextSize = 10

local equipRow              = Instance.new("Frame")
equipRow.Name               = "EquipRow"
equipRow.Size               = UDim2.new(1, -16, 0, 52)
equipRow.Position           = UDim2.new(0, 8, 0, 318)
equipRow.BackgroundTransparency = 1
equipRow.BorderSizePixel    = 0
equipRow.ZIndex             = 8
equipRow.Parent             = towerViewer

local equipSlotLabels = {}

local function buildEquipSlots(slotCount)
	-- Clear existing slots
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
		slot.BackgroundColor3   = C.BG
		slot.BorderSizePixel    = 0
		slot.ZIndex             = 9
		slot.Parent             = equipRow
		makeCorner(slot, 6)
		makeStroke(slot, C.BORDER, 1, 0.3)

		local slotLabel = makeLabel(slot, "+",
			UDim2.new(1, 0, 1, 0),
			UDim2.new(0, 0, 0, 0),
			C.TEXTDIM, nil, 1)
		slotLabel.TextSize = 18
		slotLabel.TextXAlignment = Enum.TextXAlignment.Center
		slotLabel.TextYAlignment = Enum.TextYAlignment.Center
		table.insert(equipSlotLabels, slot)
	end
end

buildEquipSlots(0)  -- empty until tower selected

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
	viewerName.TextColor3 = isUnlocked and C.WHITE or C.TEXTDIM

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
	-- Clear existing entries
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
		entry.Size             = UDim2.new(1, -6, 0, 60)
		entry.BackgroundColor3 = isUnlocked and C.PANEL or C.BG
		entry.BackgroundTransparency = 0.3
		entry.BorderSizePixel  = 0
		entry.ZIndex           = 9
		entry.LayoutOrder      = isUnlocked and 0 or 1  -- unlocked first
		entry.Parent           = towerScrollFrame
		makeCorner(entry, 5)
		makeStroke(entry, isUnlocked and C.ACCENT or C.BORDER, 1, isUnlocked and 0.6 or 0.5)

		-- Tower name
		local nameL = makeLabel(entry, td.displayName,
			UDim2.new(1, -10, 0, 18),
			UDim2.new(0, 8, 0, 8),
			isUnlocked and C.WHITE or C.TEXTDIM, nil, 1)
		nameL.TextSize = 13

		-- Rarity stars
		local rarityL = makeLabel(entry, rarityStars(td.rarity),
			UDim2.new(1, -10, 0, 14),
			UDim2.new(0, 8, 0, 28),
			rarityColor(td.rarity), nil, 1)
		rarityL.TextSize = 10
		rarityL.Font = Enum.Font.Gotham

		-- Lock icon
		if not isUnlocked then
			local lockL = makeLabel(entry, "🔒",
				UDim2.new(0, 24, 0, 24),
				UDim2.new(1, -30, 0.5, -12),
				C.RED, nil, 1)
			lockL.TextSize = 16
			lockL.TextXAlignment = Enum.TextXAlignment.Center
		end

		-- Click
		local btn              = Instance.new("TextButton")
		btn.Size               = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Text               = ""
		btn.ZIndex             = 10
		btn.Parent             = entry

		btn.MouseButton1Click:Connect(function()
			updateViewerForTower(name)
			-- Highlight selected
			for n, b in pairs(towerEntryButtons) do
				b.BackgroundTransparency = n == name and 0.05 or 0.3
			end
		end)

		towerEntryButtons[name] = entry
		totalH = totalH + 63
	end

	towerScrollFrame.CanvasSize = UDim2.new(0, 0, 0, totalH)
end

-- ============================================================
-- ============================================================
-- QUESTS PANEL
-- ============================================================
-- ============================================================

local questPanel              = Instance.new("Frame")
questPanel.Name               = "QuestsPanel"
questPanel.Size               = UDim2.new(1, 0, 1, -42)
questPanel.Position           = UDim2.new(0, 0, 0, 42)
questPanel.BackgroundTransparency = 1
questPanel.BorderSizePixel    = 0
questPanel.Visible            = false
questPanel.ZIndex             = 6
questPanel.Parent             = panelContainer

-- Tab bar
local tabBar              = Instance.new("Frame")
tabBar.Size               = UDim2.new(1, 0, 0, 36)
tabBar.BackgroundColor3   = C.BG
tabBar.BackgroundTransparency = 0.2
tabBar.BorderSizePixel    = 0
tabBar.ZIndex             = 7
tabBar.Parent             = questPanel

local tabLayout           = Instance.new("UIListLayout")
tabLayout.FillDirection   = Enum.FillDirection.Horizontal
tabLayout.SortOrder       = Enum.SortOrder.LayoutOrder
tabLayout.Parent          = tabBar

local questTabBtns = {}
local questScrolls = {}

local tabDefs = {
	{ key = "Daily",      label = "DAILY",      layoutOrder = 1 },
	{ key = "Weekly",     label = "WEEKLY",     layoutOrder = 2 },
	{ key = "Challenges", label = "CHALLENGES", layoutOrder = 3 },
}

-- Quest scroll area
local questScrollContainer              = Instance.new("Frame")
questScrollContainer.Size               = UDim2.new(1, 0, 1, -36)
questScrollContainer.Position           = UDim2.new(0, 0, 0, 36)
questScrollContainer.BackgroundTransparency = 1
questScrollContainer.BorderSizePixel    = 0
questScrollContainer.ZIndex             = 7
questScrollContainer.Parent             = questPanel

for _, tabDef in ipairs(tabDefs) do
	local key = tabDef.key

	-- Tab button
	local tabBtn              = Instance.new("TextButton")
	tabBtn.Size               = UDim2.new(0, 160, 1, 0)
	tabBtn.BackgroundColor3   = C.PANEL2
	tabBtn.BackgroundTransparency = 0.3
	tabBtn.BorderSizePixel    = 0
	tabBtn.Text               = tabDef.label
	tabBtn.TextColor3         = C.TEXTSUB
	tabBtn.Font               = Enum.Font.GothamBold
	tabBtn.TextSize           = 12
	tabBtn.AutoButtonColor    = false
	tabBtn.LayoutOrder        = tabDef.layoutOrder
	tabBtn.ZIndex             = 8
	tabBtn.Parent             = tabBar
	questTabBtns[key]         = tabBtn

	-- Scroll frame for this tab
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

	-- Build quest entries
	local quests  = TowerData.Quests[key] or {}
	local totalH  = 8
	for _, quest in ipairs(quests) do
		local card              = Instance.new("Frame")
		card.Name               = quest.id
		card.Size               = UDim2.new(1, 0, 0, 80)
		card.BackgroundColor3   = C.PANEL2
		card.BackgroundTransparency = 0.2
		card.BorderSizePixel    = 0
		card.ZIndex             = 9
		card.Parent             = scroll
		makeCorner(card, 6)
		makeStroke(card, C.BORDER, 1, 0.4)

		local qname = makeLabel(card, quest.displayName,
			UDim2.new(1, -100, 0, 20),
			UDim2.new(0, 10, 0, 8),
			C.WHITE, nil, 1)
		qname.TextSize = 14

		local qdesc = makeLabel(card, quest.description,
			UDim2.new(1, -100, 0, 28),
			UDim2.new(0, 10, 0, 28),
			C.TEXTSUB, nil, 1)
		qdesc.TextSize = 11
		qdesc.Font = Enum.Font.Gotham
		qdesc.TextWrapped = true

		-- Reward text
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

		-- Progress bar
		local progBg              = Instance.new("Frame")
		progBg.Size               = UDim2.new(0, 100, 0, 8)
		progBg.Position           = UDim2.new(1, -110, 0, 12)
		progBg.BackgroundColor3   = C.BG
		progBg.BorderSizePixel    = 0
		progBg.ZIndex             = 10
		progBg.Parent             = card
		makeCorner(progBg, 4)

		local progFill            = Instance.new("Frame")
		progFill.Size             = UDim2.new(0, 0, 1, 0)  -- 0 progress initially
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

		-- Claim button (disabled until complete)
		local claimBtn = makeButton(card, "Claim",
			UDim2.new(0, 90, 0, 26),
			UDim2.new(1, -102, 1, -34),
			C.TEXTDIM, C.TEXT)
		claimBtn.TextSize = 12
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
			btn.TextColor3 = C.WHITE
		else
			btn.BackgroundTransparency = 0.3
			btn.TextColor3 = C.TEXTSUB
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
-- ============================================================
-- GACHA PANEL
-- ============================================================
-- ============================================================

local gachaPanel              = Instance.new("Frame")
gachaPanel.Name               = "GachaPanel"
gachaPanel.Size               = UDim2.new(1, 0, 1, -42)
gachaPanel.Position           = UDim2.new(0, 0, 0, 42)
gachaPanel.BackgroundTransparency = 1
gachaPanel.BorderSizePixel    = 0
gachaPanel.Visible            = false
gachaPanel.ZIndex             = 6
gachaPanel.Parent             = panelContainer

-- Banner selection row
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
	bBtn.Position           = UDim2.new((i-1)*0.5, (i-1)*6 + (i==1 and 0 or 0), 0, 0)
	bBtn.BackgroundColor3   = isActive and C.ACCENT or C.PANEL2
	bBtn.BackgroundTransparency = isActive and 0.2 or 0.4
	bBtn.BorderSizePixel    = 0
	bBtn.Text               = ""
	bBtn.AutoButtonColor    = false
	bBtn.ZIndex             = 8
	bBtn.Parent             = bannerRow
	makeCorner(bBtn, 6)
	local bStroke = makeStroke(bBtn, isActive and C.ACCENT or C.BORDER, 1, isActive and 0.2 or 0.5)

	local bName = makeLabel(bBtn, bData.displayName,
		UDim2.new(1, -10, 0, 20),
		UDim2.new(0, 8, 0, 8),
		isActive and C.WHITE or C.TEXTSUB, nil, 1)
	bName.TextSize = 13

	local bType = makeLabel(bBtn, bKey == "special" and "⭐ RATE-UP BANNER" or "📦 STANDARD",
		UDim2.new(1, -10, 0, 16),
		UDim2.new(0, 8, 0, 30),
		bKey == "special" and C.GOLD or C.TEXTSUB, nil, 1)
	bType.TextSize = 10

	bannerBtns[bKey] = { button = bBtn, nameLabel = bName, typeLabel = bType, stroke = bStroke }
end

-- Banner description area
local bannerDesc              = Instance.new("TextLabel")
bannerDesc.Size               = UDim2.new(1, -16, 0, 56)
bannerDesc.Position           = UDim2.new(0, 8, 0, 76)
bannerDesc.BackgroundColor3   = C.PANEL2
bannerDesc.BackgroundTransparency = 0.2
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
makeCorner(bannerDesc, 6)

local descPad = Instance.new("UIPadding")
descPad.PaddingTop   = UDim.new(0, 6)
descPad.PaddingLeft  = UDim.new(0, 8)
descPad.PaddingRight = UDim.new(0, 8)
descPad.Parent       = bannerDesc

-- Rate-Up label (special banner only)
local rateUpLabel             = makeLabel(gachaPanel, "Rate-Up: Deadeye",
	UDim2.new(1, -16, 0, 20),
	UDim2.new(0, 8, 0, 138),
	C.GOLD, nil, 1)
rateUpLabel.TextSize = 12
rateUpLabel.Visible = (activeBanner == "special")

-- Pity display
local pityLabel               = makeLabel(gachaPanel, "Pity: 0 / 70  (Gem pulls only)",
	UDim2.new(1, -16, 0, 18),
	UDim2.new(0, 8, 0, 162),
	C.TEXTSUB, nil, 1)
pityLabel.TextSize = 11
pityLabel.Font = Enum.Font.Gotham

-- ---- Pull buttons ----
local pullRow               = Instance.new("Frame")
pullRow.Size                = UDim2.new(1, -16, 0, 46)
pullRow.Position            = UDim2.new(0, 8, 0, 188)
pullRow.BackgroundTransparency = 1
pullRow.BorderSizePixel     = 0
pullRow.ZIndex              = 7
pullRow.Parent              = gachaPanel

-- Gems pull buttons
local gem1Btn = makeButton(pullRow, "💎 ×1  (160)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0, 0, 0, 0),
	C.GEM, C.WHITE)
makeCorner(gem1Btn, 6)
gem1Btn.TextSize = 12

local gem10Btn = makeButton(pullRow, "💎 ×10  (1,600)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0.25, 4, 0, 0),
	C.GEM, C.WHITE)
makeCorner(gem10Btn, 6)
gem10Btn.TextSize = 12

-- Coin pull buttons (no pity)
local coin1Btn = makeButton(pullRow, "🪙 ×1  (1,000)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0.5, 4, 0, 0),
	Color3.fromRGB(100, 80, 30), C.GOLD)
makeCorner(coin1Btn, 6)
coin1Btn.TextSize = 12

local coin10Btn = makeButton(pullRow, "🪙 ×10  (10,000)",
	UDim2.new(0.25, -4, 1, 0), UDim2.new(0.75, 8, 0, 0),
	Color3.fromRGB(100, 80, 30), C.GOLD)
makeCorner(coin10Btn, 6)
coin10Btn.TextSize = 12

-- Coin no-pity note
local noPityNote = makeLabel(gachaPanel, "⚠ Coin pulls do not count toward pity.",
	UDim2.new(1, -16, 0, 16),
	UDim2.new(0, 8, 0, 240),
	C.RED, nil, 1)
noPityNote.TextSize = 10
noPityNote.Font = Enum.Font.Gotham

-- ---- Results area ----
local resultsHeader = makeLabel(gachaPanel, "RECENT PULLS",
	UDim2.new(1, -16, 0, 18),
	UDim2.new(0, 8, 0, 264),
	C.TEXTSUB, nil, 1)
resultsHeader.TextSize = 10

local resultsScroll              = Instance.new("ScrollingFrame")
resultsScroll.Name               = "ResultsScroll"
resultsScroll.Size               = UDim2.new(1, -16, 1, -294)
resultsScroll.Position           = UDim2.new(0, 8, 0, 286)
resultsScroll.BackgroundColor3   = C.PANEL2
resultsScroll.BackgroundTransparency = 0.3
resultsScroll.BorderSizePixel    = 0
resultsScroll.ScrollBarThickness = 3
resultsScroll.ScrollBarImageColor3 = C.ACCENT
resultsScroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
resultsScroll.ZIndex             = 7
resultsScroll.Parent             = gachaPanel
makeCorner(resultsScroll, 6)

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
	card.BackgroundColor3   = C.BG
	card.BorderSizePixel    = 0
	card.LayoutOrder        = -(#resultCards)   -- newest first
	card.ZIndex             = 8
	card.Parent             = resultsScroll
	makeCorner(card, 6)
	makeStroke(card, rColor, 2, 0)

	local icon = makeLabel(card, td and td.displayName:sub(1,2) or "??",
		UDim2.new(1, 0, 0, 40),
		UDim2.new(0, 0, 0, 4),
		rColor, nil, 1)
	icon.TextSize = 18
	icon.TextXAlignment = Enum.TextXAlignment.Center

	local nameL = makeLabel(card, td and td.displayName or towerName,
		UDim2.new(1, -4, 0, 24),
		UDim2.new(0, 2, 0, 44),
		C.TEXT, nil, 1)
	nameL.TextSize = 10
	nameL.TextWrapped = true
	nameL.TextXAlignment = Enum.TextXAlignment.Center

	if isNew then
		local newTag = makeLabel(card, "NEW",
			UDim2.new(1, 0, 0, 16),
			UDim2.new(0, 0, 0, 64),
			C.GREEN, nil, 1)
		newTag.TextSize = 10
		newTag.Font = Enum.Font.GothamBold
		newTag.TextXAlignment = Enum.TextXAlignment.Center
	end

	table.insert(resultCards, card)
	-- Scroll to show newest
	local contentH = math.ceil(#resultCards / 6) * 92 + 12
	resultsScroll.CanvasSize = UDim2.new(0, 0, 0, contentH)
	resultsScroll.CanvasPosition = Vector2.new(0, 0)
end

-- Banner switching logic
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
		info.button.BackgroundColor3 = isActive and C.ACCENT or C.PANEL2
		info.button.BackgroundTransparency = isActive and 0.2 or 0.4
		info.nameLabel.TextColor3 = isActive and C.WHITE or C.TEXTSUB
		if info.stroke then
			info.stroke.Color = isActive and C.ACCENT or C.BORDER
			info.stroke.Transparency = isActive and 0.2 or 0.5
		end
	end
end

for bKey, info in pairs(bannerBtns) do
	info.button.MouseButton1Click:Connect(function()
		switchBanner(bKey)
	end)
end

-- Pull button handlers
local function firePull(count: number, useGems: boolean)
	gachaPullRemote:FireServer(activeBanner, count, useGems)
end

gem1Btn.MouseButton1Click:Connect(function()   firePull(1,  true)  end)
gem10Btn.MouseButton1Click:Connect(function()  firePull(10, true)  end)
coin1Btn.MouseButton1Click:Connect(function()  firePull(1,  false) end)
coin10Btn.MouseButton1Click:Connect(function() firePull(10, false) end)

-- Receive pull results from server
gachaResultRemote.OnClientEvent:Connect(function(results: table)
	for _, res in ipairs(results) do
		addResultCard(res.tower, res.rarity, res.isNew)
		-- If player gained a new tower, refresh inventory list
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

local function setNavActive(key: string | nil)
	for k, info in pairs(navButtons) do
		local isActive = (k == key)
		info.activeBar.Visible    = isActive
		info.iconLabel.TextColor3 = isActive and C.ACCENT or C.TEXTSUB
		info.nameLabel.TextColor3 = isActive and C.WHITE  or C.TEXTDIM
	end
end

local function openPanel(key: string)
	if activePanel == key then
		-- Toggle: close if already open
		panelContainer.Visible = false
		activePanel = nil
		setNavActive(nil)
		return
	end
	activePanel = key
	panelTitle.Text = panels[key] and panels[key].title or key:upper()
	for k, p in pairs(panels) do
		p.frame.Visible = (k == key)
	end
	panelContainer.Visible = true
	setNavActive(key)

	-- Refresh inventory list when opening that panel
	if key == "inventory" then
		buildTowerListEntries()
	end
end

local function closePanel()
	panelContainer.Visible = false
	activePanel = nil
	setNavActive(nil)
end

btnInventory.MouseButton1Click:Connect(function() openPanel("inventory") end)
btnQuests.MouseButton1Click:Connect(function()    openPanel("quests")    end)
btnGacha.MouseButton1Click:Connect(function()     openPanel("gacha")     end)
closeBtn.MouseButton1Click:Connect(closePanel)

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

	-- Update pity display from server-side data (server doesn't push pity currently,
	-- but the label defaults are fine for display)
end)

-- ============================================================
-- GAME STATE TOGGLE
-- ============================================================

local function updateToggleBtn(state: string)
	if state == "InRound" then
		toggleBtn.Text = "⏹ Stop Round"
		toggleBtn.BackgroundColor3 = C.RED
		-- Hide lobby panels during round
		navBar.Visible = false
		panelContainer.Visible = false
		activePanel = nil
		setNavActive(nil)
	else
		toggleBtn.Text = "▶ Start Round"
		toggleBtn.BackgroundColor3 = C.GREEN
		navBar.Visible = true
	end
end

toggleBtn.MouseButton1Click:Connect(function()
	toggleStateRemote:FireServer()
end)

gameStateChanged.OnClientEvent:Connect(function(newState: string)
	updateToggleBtn(newState)
end)

-- Initialise based on current state
if gameStateValue then
	updateToggleBtn(gameStateValue.Value)
end

-- ============================================================
-- INITIAL SETUP
-- ============================================================

buildTowerListEntries()
switchQuestTab("Daily")
switchBanner("standard")
