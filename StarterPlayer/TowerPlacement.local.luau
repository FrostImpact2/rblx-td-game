--[[
	TowerPlacementClient (LocalScript)
	Place in StarterPlayer → StarterPlayerScripts
]]

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local player    = Players.LocalPlayer
local mouse     = player:GetMouse()
local playerGui = player:WaitForChild("PlayerGui")

local placeRemote = ReplicatedStorage:WaitForChild("PlaceTower", 10)
local moveRemote  = ReplicatedStorage:WaitForChild("MoveTower", 10)

local towersFolder  = Workspace:WaitForChild("Towers", 15)
local enemiesFolder = Workspace:WaitForChild("Enemies", 15)

local placing = false
local selectedTower = "Warrior"
local selectedTowerModel: Model? = nil
local canPlace = false

local ghostFolder: Folder? = nil
local ghostParts = {}
local rangePreview: Part? = nil
local ghostParented = false
local updateConnection: RBXScriptConnection? = nil

local towerHpGuis = {}
local towerBarAttachments = {}

local PLACE_KEY_DEADEYE  = Enum.KeyCode.T   -- T → place Deadeye
local PLACE_KEY_WARRIOR  = Enum.KeyCode.U
local PLACE_KEY_VITALIST = Enum.KeyCode.Y   -- Y → place Vitalist
local GHOST_TRANSPARENCY = 0.5
local VALID_COLOR   = Color3.fromRGB(100, 255, 100)
local INVALID_COLOR = Color3.fromRGB(255, 80, 80)
local HP_BAR_GAP    = 1.5

-- Per-tower range studs for the ghost preview circle
local TOWER_RANGE_STUDS = {
	Warrior  = 8,
	Deadeye  = 30,
	Vitalist = 20,
}

-- ============================================================
-- MOUSE POSITION
-- ============================================================

local function getMouseScreenPos(): (number, number)
	local pos = UserInputService:GetMouseLocation()
	return pos.X, pos.Y
end

-- ============================================================
-- GROUND RAYCAST
-- ============================================================

local function raycastGround(): Vector3?
	local camera = Workspace.CurrentCamera
	local mx, my = getMouseScreenPos()
	local unitRay = camera:ViewportPointToRay(mx, my)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local ignoreList = {}
	if ghostFolder then table.insert(ignoreList, ghostFolder) end
	if enemiesFolder then table.insert(ignoreList, enemiesFolder) end
	if towersFolder then table.insert(ignoreList, towersFolder) end
	if player.Character then table.insert(ignoreList, player.Character) end

	for _, child in ipairs(Workspace:GetChildren()) do
		local n = child.Name
		if n == "MoveIndicator" or n == "LeapIndicator"
			or n == "ParticleAnchor" or n == "SlashVFXAnchor"
			or n == "HealVFXAnchor" or n == "ImpactRing" then
			table.insert(ignoreList, child)
		end
	end

	params.FilterDescendantsInstances = ignoreList

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * 1000, params)
	if result and result.Normal.Y > 0.5 then
		return result.Position
	end
	return nil
end

-- ============================================================
-- GHOST
-- ============================================================

local ghostPartDefs = {
	{ "Torso",     Vector3.new(2, 2.4, 1.2), Vector3.new(0, 3.5, 0) },
	{ "Head",      Vector3.new(1.4, 1.4, 1.4), Vector3.new(0, 5.6, 0) },
	{ "LeftArm",   Vector3.new(0.8, 2.4, 1),   Vector3.new(-1.4, 3.3, 0) },
	{ "RightArm",  Vector3.new(0.8, 2.4, 1),   Vector3.new(1.4, 3.3, 0) },
	{ "LeftLeg",   Vector3.new(0.9, 2.4, 1),   Vector3.new(-0.5, 1.2, 0) },
	{ "RightLeg",  Vector3.new(0.9, 2.4, 1),   Vector3.new(0.5, 1.2, 0) },
}

local function destroyGhost()
	if ghostFolder then ghostFolder:Destroy(); ghostFolder = nil end
	ghostParts = {}; rangePreview = nil; ghostParented = false
end

local function createGhost()
	destroyGhost()
	local folder = Instance.new("Folder")
	folder.Name = "PlacementGhostFolder"
	ghostParts = {}

	for _, def in ipairs(ghostPartDefs) do
		local p = Instance.new("Part")
		p.Name = def[1]; p.Size = def[2]; p.Color = VALID_COLOR
		p.Transparency = GHOST_TRANSPARENCY; p.Anchored = true; p.CanCollide = false
		p.Material = Enum.Material.SmoothPlastic
		p.CFrame = CFrame.new(0, -1000, 0); p.Parent = folder
		table.insert(ghostParts, { part = p, offset = def[3] })
	end

	local rangeStuds = TOWER_RANGE_STUDS[selectedTower] or 8
	local range = Instance.new("Part")
	range.Name = "RangePreview"; range.Shape = Enum.PartType.Cylinder
	range.Size = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	range.Color = Color3.fromRGB(100, 200, 100); range.Transparency = 0.7
	range.Anchored = true; range.CanCollide = false
	range.Material = Enum.Material.SmoothPlastic
	range.CFrame = CFrame.new(0, -1000, 0); range.Parent = folder

	ghostFolder = folder; rangePreview = range; ghostParented = false
end

local function updateGhostPosition()
	local groundPos = raycastGround()
	if not groundPos then
		canPlace = false
		for _, data in ipairs(ghostParts) do data.part.Color = INVALID_COLOR end
		return
	end
	if not ghostParented and ghostFolder then
		ghostFolder.Parent = Workspace; ghostParented = true
	end
	canPlace = true
	for _, data in ipairs(ghostParts) do
		data.part.CFrame = CFrame.new(groundPos + data.offset)
		data.part.Color = VALID_COLOR
	end
	if rangePreview then
		rangePreview.CFrame = CFrame.new(groundPos.X, groundPos.Y + 0.1, groundPos.Z)
			* CFrame.Angles(0, 0, math.rad(90))
	end
end

-- ============================================================
-- TOWER RANGE DISPLAY (attack + leap)
-- ============================================================

local function showTowerRange(towerModel: Model)
	local circle = towerModel:FindFirstChild("RangeCircle")
	if circle then
		circle.Transparency = 0.6
		local torso = towerModel.PrimaryPart
		if torso then
			local pos = torso.Position
			circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end

	local leapCircle = towerModel:FindFirstChild("LeapRangeCircle")
	if leapCircle then
		local cdEnd = towerModel:GetAttribute("LeapSlashCooldown") or 0
		if tick() >= cdEnd then
			leapCircle.Transparency = 0.8
		else
			leapCircle.Transparency = 0.92
		end
		local torso = towerModel.PrimaryPart
		if torso then
			local pos = torso.Position
			leapCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end
end

local function hideTowerRange(towerModel: Model)
	local circle = towerModel:FindFirstChild("RangeCircle")
	if circle then circle.Transparency = 1 end
	local leapCircle = towerModel:FindFirstChild("LeapRangeCircle")
	if leapCircle then leapCircle.Transparency = 1 end
end

-- ============================================================
-- FORWARD DECLARATIONS
-- ============================================================

local infoGui: ScreenGui? = nil

local function deselectTower()
	if selectedTowerModel and selectedTowerModel.Parent then
		hideTowerRange(selectedTowerModel)
	end
	selectedTowerModel = nil
	if infoGui then infoGui:Destroy(); infoGui = nil end
end

-- ============================================================
-- PLACEMENT MODE
-- ============================================================

local function stopPlacing()
	placing = false; destroyGhost()
	if updateConnection then updateConnection:Disconnect(); updateConnection = nil end
end

local function startPlacing(towerType: string)
	-- If already placing the same tower type, pressing the key again cancels placement.
	-- Otherwise (different type or not currently placing), switch to the new tower.
	if placing and selectedTower == towerType then stopPlacing(); return end
	selectedTower = towerType
	placing = true; deselectTower(); createGhost()
	updateConnection = RunService.RenderStepped:Connect(function()
		if placing then updateGhostPosition() end
	end)
end

-- ============================================================
-- TOWER INFO GUI (with cooldown bar)
-- ============================================================

local function getTowerFromPart(part: Instance): Model?
	if not part then return nil end
	local current = part
	while current and current ~= Workspace do
		if current.Parent == towersFolder then return current :: Model end
		current = current.Parent
	end
	return nil
end

-- Tower-type display data for the info panel
local TOWER_PANEL_DATA = {
	Deadeye = {
		displayName  = "Hired Deadeye",
		sellValue    = 165,
		upgradeCost  = 5000,
		upgradeLines = { "+3 Damage, +4 Range", "1.2s > 0.8s Attack Rate", "250% > 350% Max Attack Rate Buff", "[Cost reduced $20 per Deadeye attack]" },
		upgradeName  = "Productive Work Effort Initiative",
		level        = 0,
		maxLevel     = 3,
	},
	Vitalist = {
		displayName  = "Vitalist",
		sellValue    = 155,
		upgradeCost  = 4500,
		upgradeLines = { "+4 AP, +5 Range", "1.2s > 0.9s Attack Rate", "Nano Blast pierces 2 extra targets" },
		upgradeName  = "Medical Supply Enhancement",
		level        = 0,
		maxLevel     = 3,
	},
	Warrior = {
		displayName  = "Warrior",
		sellValue    = 130,
		upgradeCost  = 3000,
		upgradeLines = { "+5 Damage, +2 Range", "1.0s > 0.8s Attack Rate", "Leaping Slash cone +15°" },
		upgradeName  = "Combat Training",
		level        = 0,
		maxLevel     = 3,
	},
}

local function createInfoGui(towerModel: Model)
	if infoGui then infoGui:Destroy() end

	local towerType = towerModel:GetAttribute("TowerType") or "Warrior"
	local atk       = towerModel:GetAttribute("ATK")     or 0
	local atkSpd    = towerModel:GetAttribute("ATK_SPD") or 0
	local rng       = towerModel:GetAttribute("RNG")     or 0

	local info = TOWER_PANEL_DATA[towerType] or TOWER_PANEL_DATA.Warrior

	local gui = Instance.new("ScreenGui")
	gui.Name          = "TowerInfoGUI"
	gui.ResetOnSpawn  = false
	gui.DisplayOrder  = 10
	gui.Parent        = playerGui

	-- ── Main panel ──────────────────────────────────────────────────────────
	local panel = Instance.new("Frame")
	panel.Name             = "Panel"
	panel.Size             = UDim2.new(0, 510, 0, 320)
	panel.Position         = UDim2.new(0.5, -255, 1, -360)
	panel.BackgroundColor3 = Color3.fromRGB(50, 55, 65)
	panel.BorderSizePixel  = 0
	panel.Parent           = gui
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

	-- ── Title bar ───────────────────────────────────────────────────────────
	local titleBg = Instance.new("Frame")
	titleBg.Size             = UDim2.new(1, 0, 0, 44)
	titleBg.BackgroundColor3 = Color3.fromRGB(65, 70, 80)
	titleBg.BorderSizePixel  = 0
	titleBg.Parent           = panel
	do
		Instance.new("UICorner", titleBg).CornerRadius = UDim.new(0, 8)
		local fix = Instance.new("Frame")
		fix.Size             = UDim2.new(1, 0, 0.5, 0)
		fix.Position         = UDim2.new(0, 0, 0.5, 0)
		fix.BackgroundColor3 = Color3.fromRGB(65, 70, 80)
		fix.BorderSizePixel  = 0
		fix.Parent           = titleBg
	end

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size               = UDim2.new(1, -50, 1, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text               = info.displayName
	titleLabel.TextColor3         = Color3.fromRGB(255, 255, 255)
	titleLabel.Font               = Enum.Font.GothamBold
	titleLabel.TextSize           = 20
	titleLabel.TextXAlignment     = Enum.TextXAlignment.Center
	titleLabel.Parent             = titleBg

	-- Close (X) button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Size             = UDim2.new(0, 44, 0, 44)
	closeBtn.Position         = UDim2.new(1, -44, 0, 0)
	closeBtn.BackgroundColor3 = Color3.fromRGB(100, 60, 60)
	closeBtn.BorderSizePixel  = 0
	closeBtn.Text             = "X"
	closeBtn.TextColor3       = Color3.fromRGB(230, 230, 230)
	closeBtn.Font             = Enum.Font.GothamBold
	closeBtn.TextSize         = 18
	closeBtn.Parent           = panel
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 8)
	closeBtn.MouseButton1Click:Connect(deselectTower)

	-- ── Left box: portrait + DMG ─────────────────────────────────────────────
	local leftBox = Instance.new("Frame")
	leftBox.Size             = UDim2.new(0, 138, 0, 138)
	leftBox.Position         = UDim2.new(0, 8, 0, 50)
	leftBox.BackgroundColor3 = Color3.fromRGB(70, 75, 85)
	leftBox.BorderSizePixel  = 0
	leftBox.Parent           = panel
	Instance.new("UICorner", leftBox).CornerRadius = UDim.new(0, 6)

	local dmgLabel = Instance.new("TextLabel")
	dmgLabel.Name                 = "DMGLabel"
	dmgLabel.Size                 = UDim2.new(1, 0, 0, 28)
	dmgLabel.BackgroundTransparency = 1
	dmgLabel.Text                 = "DMG: " .. tostring(atk)
	dmgLabel.TextColor3           = Color3.fromRGB(200, 200, 210)
	dmgLabel.Font                 = Enum.Font.GothamBold
	dmgLabel.TextSize             = 15
	dmgLabel.Parent               = leftBox

	local portrait = Instance.new("ImageLabel")
	portrait.Size                   = UDim2.new(1, -10, 0, 100)
	portrait.Position               = UDim2.new(0, 5, 0, 30)
	portrait.BackgroundColor3       = Color3.fromRGB(40, 45, 55)
	portrait.BackgroundTransparency = 0
	portrait.BorderSizePixel        = 0
	portrait.Image                  = "rbxassetid://0"
	portrait.Parent                 = leftBox
	Instance.new("UICorner", portrait).CornerRadius = UDim.new(0.5, 0)

	-- ── Right section: upgrade info ─────────────────────────────────────────
	local rightX   = 154
	local rightW   = 510 - rightX - 8
	local lineY    = 50
	for i, line in ipairs(info.upgradeLines) do
		local lbl = Instance.new("TextLabel")
		lbl.Size               = UDim2.new(0, rightW, 0, 22)
		lbl.Position           = UDim2.new(0, rightX, 0, lineY + (i-1) * 23)
		lbl.BackgroundTransparency = 1
		lbl.Text               = line
		lbl.Font               = Enum.Font.GothamBold
		lbl.TextSize           = 13
		lbl.TextWrapped        = true
		lbl.TextXAlignment     = Enum.TextXAlignment.Left
		lbl.TextYAlignment     = Enum.TextYAlignment.Center
		lbl.Parent             = panel
		if i == 1 then
			lbl.TextColor3 = Color3.fromRGB(80, 220, 80)
		elseif i <= 3 then
			lbl.TextColor3 = Color3.fromRGB(220, 220, 220)
		else
			lbl.TextColor3 = Color3.fromRGB(150, 160, 175)
			lbl.Font       = Enum.Font.Gotham
		end
	end

	-- ── Level + next upgrade ─────────────────────────────────────────────────
	local levelLabel = Instance.new("TextLabel")
	levelLabel.Name               = "LevelLabel"
	levelLabel.Size               = UDim2.new(0, 240, 0, 26)
	levelLabel.Position           = UDim2.new(0, 8, 0, 193)
	levelLabel.BackgroundTransparency = 1
	levelLabel.Text               = "Level " .. info.level .. "/" .. info.maxLevel
	levelLabel.TextColor3         = Color3.fromRGB(255, 255, 255)
	levelLabel.Font               = Enum.Font.GothamBold
	levelLabel.TextSize           = 18
	levelLabel.TextXAlignment     = Enum.TextXAlignment.Left
	levelLabel.Parent             = panel

	local nextLbl = Instance.new("TextLabel")
	nextLbl.Size               = UDim2.new(1, -16, 0, 20)
	nextLbl.Position           = UDim2.new(0, 8, 0, 217)
	nextLbl.BackgroundTransparency = 1
	nextLbl.Text               = "Next Upgrade - " .. info.upgradeName
	nextLbl.TextColor3         = Color3.fromRGB(190, 195, 210)
	nextLbl.Font               = Enum.Font.Gotham
	nextLbl.TextSize           = 12
	nextLbl.TextXAlignment     = Enum.TextXAlignment.Left
	nextLbl.TextTruncate       = Enum.TextTruncate.AtEnd
	nextLbl.Parent             = panel

	-- Divider
	local divLine = Instance.new("Frame")
	divLine.Size             = UDim2.new(1, -16, 0, 1)
	divLine.Position         = UDim2.new(0, 8, 0, 240)
	divLine.BackgroundColor3 = Color3.fromRGB(80, 85, 95)
	divLine.BorderSizePixel  = 0
	divLine.Parent           = panel

	-- ── Button row ──────────────────────────────────────────────────────────
	-- Upgrade button (green)
	local upgradeBtn = Instance.new("TextButton")
	upgradeBtn.Size             = UDim2.new(0, 164, 0, 46)
	upgradeBtn.Position         = UDim2.new(0, 8, 0, 246)
	upgradeBtn.BackgroundColor3 = Color3.fromRGB(55, 165, 55)
	upgradeBtn.BorderSizePixel  = 0
	upgradeBtn.Text             = "Upgrade: $" .. tostring(info.upgradeCost)
	upgradeBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
	upgradeBtn.Font             = Enum.Font.GothamBold
	upgradeBtn.TextSize         = 15
	upgradeBtn.Parent           = panel
	Instance.new("UICorner", upgradeBtn).CornerRadius = UDim.new(0, 6)

	-- Target toggle (blue, stacked two rows)
	local targetBox = Instance.new("Frame")
	targetBox.Size             = UDim2.new(0, 115, 0, 46)
	targetBox.Position         = UDim2.new(0, 180, 0, 246)
	targetBox.BackgroundColor3 = Color3.fromRGB(40, 100, 185)
	targetBox.BorderSizePixel  = 0
	targetBox.Parent           = panel
	Instance.new("UICorner", targetBox).CornerRadius = UDim.new(0, 6)

	local targetTop = Instance.new("TextLabel")
	targetTop.Name               = "TargetModeLabel"
	targetTop.Size               = UDim2.new(1, 0, 0.5, 0)
	targetTop.BackgroundTransparency = 1
	targetTop.Text               = "Targets: First"
	targetTop.TextColor3         = Color3.fromRGB(215, 235, 255)
	targetTop.Font               = Enum.Font.GothamBold
	targetTop.TextSize           = 12
	targetTop.Parent             = targetBox

	local targetBot = Instance.new("Frame")
	targetBot.Size             = UDim2.new(1, 0, 0.5, 0)
	targetBot.Position         = UDim2.new(0, 0, 0.5, 0)
	targetBot.BackgroundColor3 = Color3.fromRGB(50, 120, 205)
	targetBot.BorderSizePixel  = 0
	targetBot.Parent           = targetBox
	do
		Instance.new("UICorner", targetBot).CornerRadius = UDim.new(0, 6)
		local fix = Instance.new("Frame")
		fix.Size             = UDim2.new(1, 0, 0.5, 0)
		fix.BackgroundColor3 = Color3.fromRGB(50, 120, 205)
		fix.BorderSizePixel  = 0
		fix.Parent           = targetBot
		local t = Instance.new("TextLabel")
		t.Size               = UDim2.new(1, 0, 1, 0)
		t.BackgroundTransparency = 1
		t.Text               = "Manual"
		t.TextColor3         = Color3.fromRGB(215, 235, 255)
		t.Font               = Enum.Font.GothamBold
		t.TextSize           = 12
		t.Parent             = targetBot
	end

	-- Sell button (red)
	local sellBtn = Instance.new("TextButton")
	sellBtn.Size             = UDim2.new(0, 186, 0, 46)
	sellBtn.Position         = UDim2.new(0, 303, 0, 246)
	sellBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)
	sellBtn.BorderSizePixel  = 0
	sellBtn.Text             = "Sell: $" .. tostring(info.sellValue)
	sellBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
	sellBtn.Font             = Enum.Font.GothamBold
	sellBtn.TextSize         = 15
	sellBtn.Parent           = panel
	Instance.new("UICorner", sellBtn).CornerRadius = UDim.new(0, 6)

	-- ── Bottom stats bar ─────────────────────────────────────────────────────
	local statsBar = Instance.new("Frame")
	statsBar.Size             = UDim2.new(1, 0, 0, 46)
	statsBar.Position         = UDim2.new(0, 0, 1, -46)
	statsBar.BackgroundColor3 = Color3.fromRGB(38, 42, 52)
	statsBar.BorderSizePixel  = 0
	statsBar.Parent           = panel
	do
		Instance.new("UICorner", statsBar).CornerRadius = UDim.new(0, 8)
		local fix = Instance.new("Frame")
		fix.Size             = UDim2.new(1, 0, 0.5, 0)
		fix.BackgroundColor3 = Color3.fromRGB(38, 42, 52)
		fix.BorderSizePixel  = 0
		fix.Parent           = statsBar
	end

	local statCells = {
		{ name = "ATKStat", value = tostring(atk),                   icon = "⚔" },
		{ name = "RNGStat", value = tostring(rng),                   icon = "◎" },
		{ name = "SPDStat", value = string.format("%.1f", atkSpd),   icon = "⏱" },
	}
	local cellW = 510 / 3
	for i, s in ipairs(statCells) do
		local cell = Instance.new("Frame")
		cell.Name             = s.name
		cell.Size             = UDim2.new(0, cellW - 4, 1, 0)
		cell.Position         = UDim2.new(0, (i-1) * cellW + 2, 0, 0)
		cell.BackgroundTransparency = 1
		cell.Parent           = statsBar

		local valLbl = Instance.new("TextLabel")
		valLbl.Name               = "Value"
		valLbl.Size               = UDim2.new(0.55, 0, 1, 0)
		valLbl.Position           = UDim2.new(0, 12, 0, 0)
		valLbl.BackgroundTransparency = 1
		valLbl.Text               = s.value
		valLbl.TextColor3         = Color3.fromRGB(225, 225, 225)
		valLbl.Font               = Enum.Font.GothamBold
		valLbl.TextSize           = 20
		valLbl.TextXAlignment     = Enum.TextXAlignment.Left
		valLbl.Parent             = cell

		local iconLbl = Instance.new("TextLabel")
		iconLbl.Size               = UDim2.new(0.45, -12, 1, 0)
		iconLbl.Position           = UDim2.new(0.55, 0, 0, 0)
		iconLbl.BackgroundTransparency = 1
		iconLbl.Text               = s.icon
		iconLbl.TextColor3         = Color3.fromRGB(140, 165, 210)
		iconLbl.Font               = Enum.Font.GothamBold
		iconLbl.TextSize           = 22
		iconLbl.TextXAlignment     = Enum.TextXAlignment.Right
		iconLbl.Parent             = cell
	end

	infoGui = gui
end

local function selectTower(towerModel: Model)
	if selectedTowerModel and selectedTowerModel.Parent then
		hideTowerRange(selectedTowerModel)
	end
	if selectedTowerModel == towerModel then deselectTower(); return end
	selectedTowerModel = towerModel
	showTowerRange(towerModel)
	createInfoGui(towerModel)
end

-- ============================================================
-- TOWER HEALTH BARS
-- ============================================================

local function getTowerCenterAttachment(m: Model): Attachment
	if towerBarAttachments[m] then return towerBarAttachments[m] end
	local root = m.PrimaryPart; if not root then return nil end
	local a = Instance.new("Attachment"); a.Name = "TowerBarAnchor"; a.Parent = root
	towerBarAttachments[m] = a; return a
end

local function updateTowerAttachment(m: Model)
	local a = towerBarAttachments[m]; if not a then return end
	local root = m.PrimaryPart; if not root then return end
	local cf, sz = m:GetBoundingBox()
	local topWorld = cf.Position + Vector3.new(0, sz.Y/2 + HP_BAR_GAP, 0)
	a.Position = root.CFrame:PointToObjectSpace(topWorld)
end

local function createTowerHPBar(m: Model): BillboardGui
	local root = m.PrimaryPart; if not root then return nil end
	local hp = m:GetAttribute("HP") or 0
	local maxHp = m:GetAttribute("MaxHP") or 1
	local a = getTowerCenterAttachment(m); if not a then return nil end
	updateTowerAttachment(m)

	local bb = Instance.new("BillboardGui")
	bb.Name = "TowerHPBar"; bb.Adornee = a
	bb.Size = UDim2.new(4,0,0.4,0); bb.AlwaysOnTop = true; bb.Parent = m

	local c = Instance.new("Frame"); c.Name = "Container"
	c.Size = UDim2.new(1,0,1,0); c.BackgroundTransparency = 1; c.Parent = bb

	local o = Instance.new("Frame"); o.Name = "Outline"
	o.Size = UDim2.new(1,0,1,0); o.BackgroundColor3 = Color3.fromRGB(0,0,0)
	o.BorderSizePixel = 0; o.Parent = c

	local bg = Instance.new("Frame"); bg.Name = "HPBarBg"
	bg.Size = UDim2.new(1,-2,1,-2); bg.Position = UDim2.new(0,1,0,1)
	bg.BackgroundColor3 = Color3.fromRGB(40,40,40); bg.BorderSizePixel = 0; bg.Parent = o

	local ratio = math.clamp(hp/maxHp, 0, 1)
	local fill = Instance.new("Frame"); fill.Name = "HPBarFill"
	fill.Size = UDim2.new(ratio,0,1,0)
	fill.BackgroundColor3 = Color3.fromRGB(60,180,60); fill.BorderSizePixel = 0; fill.Parent = bg

	local t = Instance.new("TextLabel"); t.Name = "HPText"
	t.Size = UDim2.new(1,0,1,0); t.BackgroundTransparency = 1
	t.Text = hp.."/"..maxHp; t.TextColor3 = Color3.fromRGB(255,255,255)
	t.TextScaled = true; t.Font = Enum.Font.SourceSans
	t.TextStrokeTransparency = 0.5; t.Parent = bg

	return bb
end

local function attachTowerHPBar(m: Model)
	if towerHpGuis[m] then return end
	if not m.PrimaryPart then task.wait(0.1); if not m.PrimaryPart then return end end
	local g = createTowerHPBar(m)
	if g then towerHpGuis[m] = g end
end

for _, c in ipairs(towersFolder:GetChildren()) do
	if c:IsA("Model") then attachTowerHPBar(c) end
end
towersFolder.ChildAdded:Connect(function(c)
	if c:IsA("Model") then attachTowerHPBar(c) end
end)
towersFolder.ChildRemoved:Connect(function(c)
	if towerHpGuis[c] then
		if towerHpGuis[c].Parent then towerHpGuis[c]:Destroy() end
		towerHpGuis[c] = nil
	end
	if towerBarAttachments[c] then
		if towerBarAttachments[c].Parent then towerBarAttachments[c]:Destroy() end
		towerBarAttachments[c] = nil
	end
	if selectedTowerModel == c then deselectTower() end
end)

-- Cleanup orphans
for _, c in ipairs(Workspace:GetChildren()) do
	if c.Name == "PlacementGhostFolder" and c:IsA("Folder") then c:Destroy() end
end

-- ============================================================
-- UPDATE LOOP
-- ============================================================

RunService.RenderStepped:Connect(function(dt)
	-- HP bars
	for model, gui in pairs(towerHpGuis) do
		if model and model.Parent then
			updateTowerAttachment(model)
			local hp = model:GetAttribute("HP") or 0
			local maxHp = model:GetAttribute("MaxHP") or 1
			local ratio = math.clamp(hp/maxHp, 0, 1)
			local cont = gui:FindFirstChild("Container")
			if not cont then continue end
			local outline = cont:FindFirstChild("Outline")
			if not outline then continue end
			local bg = outline:FindFirstChild("HPBarBg")
			if bg then
				local f = bg:FindFirstChild("HPBarFill")
				if f then
					-- Smoothly lerp the fill bar toward the actual ratio
					local currentRatio = f.Size.X.Scale
					local smoothed = currentRatio + (ratio - currentRatio) * math.min(dt * 10, 1)
					f.Size = UDim2.new(smoothed, 0, 1, 0)
				end
				local t = bg:FindFirstChild("HPText")
				if t then
					local newText = math.floor(hp).."/"..maxHp
					if t.Text ~= newText then t.Text = newText end
				end
			end
		else
			if gui and gui.Parent then gui:Destroy() end
			towerHpGuis[model] = nil
		end
	end

	-- Info GUI live updates
	if selectedTowerModel and selectedTowerModel.Parent and infoGui then
		showTowerRange(selectedTowerModel)

		local panel = infoGui:FindFirstChild("Panel")
		if panel then
			-- Update ATK stat value in the bottom bar
			local atkCell = panel:FindFirstChild("ATKStat", true)
			if atkCell then
				local v = atkCell:FindFirstChild("Value")
				if v then
					local newAtk = tostring(selectedTowerModel:GetAttribute("ATK") or 0)
					if v.Text ~= newAtk then v.Text = newAtk end
				end
			end

			-- Update DMG label in the left box
			local dmgLabel = panel:FindFirstChild("DMGLabel", true)
			if dmgLabel then
				local newAtk = tostring(selectedTowerModel:GetAttribute("ATK") or 0)
				local expected = "DMG: " .. newAtk
				if dmgLabel.Text ~= expected then dmgLabel.Text = expected end
			end
		end
	elseif selectedTowerModel and not selectedTowerModel.Parent then
		deselectTower()
	end
end)

-- ============================================================
-- INPUT
-- ============================================================

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == PLACE_KEY_DEADEYE then
		startPlacing("Deadeye")
	elseif input.KeyCode == PLACE_KEY_VITALIST then
		startPlacing("Vitalist")
	elseif input.KeyCode == PLACE_KEY_WARRIOR then
		startPlacing("Warrior")
	end
end)

mouse.Button1Down:Connect(function()
	if placing then
		if not canPlace then return end
		local groundPos = raycastGround()
		if groundPos then
			placeRemote:FireServer(selectedTower, groundPos)
			stopPlacing()
		end
		return
	end
	local target = mouse.Target
	local tm = getTowerFromPart(target)
	if tm then selectTower(tm) else deselectTower() end
end)

mouse.Button2Down:Connect(function()
	if placing then stopPlacing(); return end
	if selectedTowerModel and selectedTowerModel.Parent then
		local state = selectedTowerModel:GetAttribute("State") or "Idle"
		if state == "Moving" or state == "Leaping" then return end
		local groundPos = raycastGround()
		if groundPos then
			moveRemote:FireServer(selectedTowerModel, groundPos + Vector3.new(0, 3.5, 0))
		end
	end
end)

print("[TowerPlacement] Ready!")