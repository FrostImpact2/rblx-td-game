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

local PLACE_KEY_DEADEYE  = Enum.KeyCode.T
local PLACE_KEY_WARRIOR  = Enum.KeyCode.U
local PLACE_KEY_VITALIST = Enum.KeyCode.Y
local GHOST_TRANSPARENCY = 0.5
local VALID_COLOR   = Color3.fromRGB(100, 255, 100)
local INVALID_COLOR = Color3.fromRGB(255, 80, 80)
local HP_BAR_GAP    = 1.5

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
-- TOWER RANGE DISPLAY
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
	if placing and selectedTower == towerType then stopPlacing(); return end
	selectedTower = towerType
	placing = true; deselectTower(); createGhost()
	updateConnection = RunService.RenderStepped:Connect(function()
		if placing then updateGhostPosition() end
	end)
end

-- ============================================================
-- TOWER INFO GUI
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

local TOWER_PANEL_DATA = {
	Deadeye = {
		displayName  = "Deadeye",
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
		upgradeLines = { "+5 Damage, +2 Range", "1.0s > 0.8s Attack Rate", "Leaping Slash cone +15 deg" },
		upgradeName  = "Combat Training",
		level        = 0,
		maxLevel     = 3,
	},
}

-- Panel dimensions
local PANEL_W = 540
local PANEL_H = 310

-- Helper: make a UICorner
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

-- Helper: make a TextLabel
local function makeLabel(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	for k, v in pairs(props) do l[k] = v end
	l.Parent = parent
	return l
end

-- Helper: make a Frame
local function makeFrame(parent, props)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	for k, v in pairs(props) do f[k] = v end
	f.Parent = parent
	return f
end

local function createInfoGui(towerModel: Model)
	if infoGui then infoGui:Destroy() end

	local towerType = towerModel:GetAttribute("TowerType") or "Warrior"
	local atk       = towerModel:GetAttribute("ATK")     or 0
	local atkSpd    = towerModel:GetAttribute("ATK_SPD") or 0
	local rng       = towerModel:GetAttribute("RNG")     or 0

	local info = TOWER_PANEL_DATA[towerType] or TOWER_PANEL_DATA.Warrior

	local gui = Instance.new("ScreenGui")
	gui.Name         = "TowerInfoGUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent       = playerGui

	-- ── Main panel (left side of screen) ────────────────────────────────────
	local panel = Instance.new("Frame")
	panel.Name             = "Panel"
	panel.Size             = UDim2.new(0, PANEL_W, 0, PANEL_H)
	-- Anchored to the bottom-left with a small margin
	panel.Position         = UDim2.new(0, 14, 1, -(PANEL_H + 14))
	panel.BackgroundColor3 = Color3.fromRGB(52, 57, 68)
	panel.BorderSizePixel  = 0
	panel.ClipsDescendants = false
	panel.Parent           = gui
	corner(panel, 10)

	-- ── Title bar ───────────────────────────────────────────────────────────
	local titleBg = makeFrame(panel, {
		Size             = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = Color3.fromRGB(68, 73, 86),
	})
	corner(titleBg, 10)
	-- Cover bottom-rounded corners on title bar
	makeFrame(titleBg, {
		Size             = UDim2.new(1, 0, 0.5, 0),
		Position         = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(68, 73, 86),
	})

	makeLabel(titleBg, {
		Size             = UDim2.new(1, -48, 1, 0),
		Position         = UDim2.new(0, 0, 0, 0),
		Text             = info.displayName,
		TextColor3       = Color3.fromRGB(255, 255, 255),
		Font             = Enum.Font.GothamBold,
		TextSize         = 20,
		TextXAlignment   = Enum.TextXAlignment.Center,
	})

	-- Close (X) button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Size             = UDim2.new(0, 42, 0, 42)
	closeBtn.Position         = UDim2.new(1, -42, 0, 0)
	closeBtn.BackgroundColor3 = Color3.fromRGB(105, 55, 55)
	closeBtn.BorderSizePixel  = 0
	closeBtn.Text             = "X"
	closeBtn.TextColor3       = Color3.fromRGB(230, 230, 230)
	closeBtn.Font             = Enum.Font.GothamBold
	closeBtn.TextSize         = 17
	closeBtn.Parent           = panel
	corner(closeBtn, 8)
	closeBtn.MouseButton1Click:Connect(deselectTower)

	-- ── Portrait box (left) ──────────────────────────────────────────────────
	local portraitBox = makeFrame(panel, {
		Name             = "PortraitBox",
		Size             = UDim2.new(0, 132, 0, 132),
		Position         = UDim2.new(0, 10, 0, 48),
		BackgroundColor3 = Color3.fromRGB(72, 77, 90),
	})
	corner(portraitBox, 7)

	-- DMG label inside portrait box
	makeLabel(portraitBox, {
		Name           = "DMGLabel",
		Size           = UDim2.new(1, 0, 0, 26),
		Position       = UDim2.new(0, 0, 0, 0),
		Text           = "DMG: " .. tostring(atk),
		TextColor3     = Color3.fromRGB(205, 210, 220),
		Font           = Enum.Font.GothamBold,
		TextSize       = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	-- Portrait image area
	local portrait = Instance.new("ImageLabel")
	portrait.Size                   = UDim2.new(1, -8, 0, 98)
	portrait.Position               = UDim2.new(0, 4, 0, 28)
	portrait.BackgroundColor3       = Color3.fromRGB(42, 46, 57)
	portrait.BackgroundTransparency = 0
	portrait.BorderSizePixel        = 0
	portrait.Image                  = "rbxassetid://0"
	portrait.Parent                 = portraitBox
	corner(portrait, 5)

	-- ── Right section: upgrade info ─────────────────────────────────────────
	local rightX = 152
	local rightW = PANEL_W - rightX - 10

	for i, line in ipairs(info.upgradeLines) do
		local lbl = makeLabel(panel, {
			Size           = UDim2.new(0, rightW, 0, 22),
			Position       = UDim2.new(0, rightX, 0, 48 + (i - 1) * 23),
			Text           = line,
			Font           = Enum.Font.GothamBold,
			TextSize       = 13,
			TextWrapped    = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
		})
		if i == 1 then
			lbl.TextColor3 = Color3.fromRGB(80, 225, 80)
		elseif i <= 3 then
			lbl.TextColor3 = Color3.fromRGB(220, 220, 220)
		else
			lbl.TextColor3 = Color3.fromRGB(150, 160, 175)
			lbl.Font       = Enum.Font.Gotham
		end
	end

	-- ── Level + next upgrade label ──────────────────────────────────────────
	makeLabel(panel, {
		Name           = "LevelLabel",
		Size           = UDim2.new(0, 230, 0, 24),
		Position       = UDim2.new(0, 10, 0, 184),
		Text           = "Level " .. info.level .. "/" .. info.maxLevel,
		TextColor3     = Color3.fromRGB(255, 255, 255),
		Font           = Enum.Font.GothamBold,
		TextSize       = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	makeLabel(panel, {
		Size           = UDim2.new(1, -20, 0, 18),
		Position       = UDim2.new(0, 10, 0, 207),
		Text           = "Next Upgrade - " .. info.upgradeName,
		TextColor3     = Color3.fromRGB(185, 192, 208),
		Font           = Enum.Font.Gotham,
		TextSize       = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate   = Enum.TextTruncate.AtEnd,
	})

	-- Thin divider
	makeFrame(panel, {
		Size             = UDim2.new(1, -16, 0, 1),
		Position         = UDim2.new(0, 8, 0, 228),
		BackgroundColor3 = Color3.fromRGB(80, 86, 100),
	})

	-- ── Button row ──────────────────────────────────────────────────────────
	local BTN_Y     = 232
	local BTN_H     = 44

	-- Upgrade button (green)
	local upgradeBtn = Instance.new("TextButton")
	upgradeBtn.Size             = UDim2.new(0, 158, 0, BTN_H)
	upgradeBtn.Position         = UDim2.new(0, 8, 0, BTN_Y)
	upgradeBtn.BackgroundColor3 = Color3.fromRGB(55, 168, 55)
	upgradeBtn.BorderSizePixel  = 0
	upgradeBtn.Text             = "Upgrade: $" .. tostring(info.upgradeCost)
	upgradeBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
	upgradeBtn.Font             = Enum.Font.GothamBold
	upgradeBtn.TextSize         = 14
	upgradeBtn.Parent           = panel
	corner(upgradeBtn, 7)

	-- Target toggle box (blue, two stacked rows)
	local targetBox = makeFrame(panel, {
		Size             = UDim2.new(0, 112, 0, BTN_H),
		Position         = UDim2.new(0, 174, 0, BTN_Y),
		BackgroundColor3 = Color3.fromRGB(38, 102, 188),
	})
	corner(targetBox, 7)

	makeLabel(targetBox, {
		Name           = "TargetModeLabel",
		Size           = UDim2.new(1, 0, 0.5, 0),
		Text           = "Targets: First",
		TextColor3     = Color3.fromRGB(215, 235, 255),
		Font           = Enum.Font.GothamBold,
		TextSize       = 12,
	})

	local targetBot = makeFrame(targetBox, {
		Size             = UDim2.new(1, 0, 0.5, 0),
		Position         = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(48, 118, 208),
	})
	corner(targetBot, 7)
	-- Cover top-rounded corners on bottom half
	makeFrame(targetBot, {
		Size             = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(48, 118, 208),
	})
	makeLabel(targetBot, {
		Size           = UDim2.new(1, 0, 1, 0),
		Text           = "Manual",
		TextColor3     = Color3.fromRGB(215, 235, 255),
		Font           = Enum.Font.GothamBold,
		TextSize       = 12,
	})

	-- Sell button (red)
	local sellBtn = Instance.new("TextButton")
	sellBtn.Size             = UDim2.new(0, 236, 0, BTN_H)
	sellBtn.Position         = UDim2.new(0, 294, 0, BTN_Y)
	sellBtn.BackgroundColor3 = Color3.fromRGB(182, 45, 45)
	sellBtn.BorderSizePixel  = 0
	sellBtn.Text             = "Sell: $" .. tostring(info.sellValue)
	sellBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
	sellBtn.Font             = Enum.Font.GothamBold
	sellBtn.TextSize         = 14
	sellBtn.Parent           = panel
	corner(sellBtn, 7)

	-- ── Bottom stats bar (inside the panel) ──────────────────────────────────
	local STATS_Y = PANEL_H - 46
	local statsBar = makeFrame(panel, {
		Size             = UDim2.new(1, 0, 0, 46),
		Position         = UDim2.new(0, 0, 0, STATS_Y),
		BackgroundColor3 = Color3.fromRGB(36, 40, 50),
	})
	corner(statsBar, 10)
	-- Cover top-rounded corners on stats bar
	makeFrame(statsBar, {
		Size             = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(36, 40, 50),
	})

	-- Gray symbol characters (plain text, not emoji) for each stat
	-- Using simple Unicode that renders as plain text in Roblox's Gotham font
	local statCells = {
		{ name = "ATKStat", value = tostring(atk),               symbol = "/" },   -- sword-like slash
		{ name = "RNGStat", value = tostring(rng),               symbol = "o" },   -- range circle
		{ name = "SPDStat", value = string.format("%.1f", atkSpd), symbol = "s" }, -- speed
	}

	-- We'll use custom small icon frames instead of emoji for cleaner look.
	-- Icon definitions: simple geometric shapes drawn with frames.
	local function makeSwordIcon(parent, cx, cy, sz)
		-- Blade (thin tall rect, rotated)
		local blade = makeFrame(parent, {
			Size             = UDim2.new(0, 3, 0, sz),
			Position         = UDim2.new(0, cx - 1, 0, cy - sz / 2),
			BackgroundColor3 = Color3.fromRGB(150, 158, 175),
			Rotation         = 45,
		})
		-- Guard (horizontal bar)
		makeFrame(parent, {
			Size             = UDim2.new(0, sz * 0.55, 0, 3),
			Position         = UDim2.new(0, cx - sz * 0.275, 0, cy + sz * 0.08),
			BackgroundColor3 = Color3.fromRGB(150, 158, 175),
		})
	end

	local function makeCircleIcon(parent, cx, cy, r)
		-- Approximate circle with a square + UICorner
		local ring = makeFrame(parent, {
			Size             = UDim2.new(0, r * 2, 0, r * 2),
			Position         = UDim2.new(0, cx - r, 0, cy - r),
			BackgroundColor3 = Color3.fromRGB(150, 158, 175),
		})
		corner(ring, r)
		-- Hollow inner
		local inner = makeFrame(ring, {
			Size             = UDim2.new(0, r * 2 - 4, 0, r * 2 - 4),
			Position         = UDim2.new(0, 2, 0, 2),
			BackgroundColor3 = Color3.fromRGB(36, 40, 50),
		})
		corner(inner, r - 2)
		-- Center dot
		makeFrame(ring, {
			Size             = UDim2.new(0, 4, 0, 4),
			Position         = UDim2.new(0, r - 2, 0, r - 2),
			BackgroundColor3 = Color3.fromRGB(150, 158, 175),
		})
	end

	local function makeClockIcon(parent, cx, cy, r)
		-- Clock face (circle outline)
		local face = makeFrame(parent, {
			Size             = UDim2.new(0, r * 2, 0, r * 2),
			Position         = UDim2.new(0, cx - r, 0, cy - r),
			BackgroundColor3 = Color3.fromRGB(150, 158, 175),
		})
		corner(face, r)
		local inner = makeFrame(face, {
			Size             = UDim2.new(0, r * 2 - 4, 0, r * 2 - 4),
			Position         = UDim2.new(0, 2, 0, 2),
			BackgroundColor3 = Color3.fromRGB(36, 40, 50),
		})
		corner(inner, r - 2)
		-- Hour hand (pointing up-right)
		makeFrame(face, {
			Size             = UDim2.new(0, 2, 0, r * 0.55),
			Position         = UDim2.new(0, r - 1, 0, r - r * 0.55),
			BackgroundColor3 = Color3.fromRGB(150, 158, 175),
		})
		-- Minute hand (pointing right)
		makeFrame(face, {
			Size             = UDim2.new(0, r * 0.55, 0, 2),
			Position         = UDim2.new(0, r, 0, r - 1),
			BackgroundColor3 = Color3.fromRGB(150, 158, 175),
		})
	end

	local iconDrawers = { makeSwordIcon, makeCircleIcon, makeClockIcon }
	local cellW = PANEL_W / 3
	local iconCY = 23 -- vertical center within stats bar

	for i, s in ipairs(statCells) do
		local cellLeft = (i - 1) * cellW

		-- Value (number) label, left-aligned within cell
		local valLbl = makeLabel(statsBar, {
			Name           = s.name,
			Size           = UDim2.new(0, cellW * 0.5, 1, 0),
			Position       = UDim2.new(0, cellLeft + 12, 0, 0),
			Text           = s.value,
			TextColor3     = Color3.fromRGB(225, 228, 235),
			Font           = Enum.Font.GothamBold,
			TextSize       = 20,
			TextXAlignment = Enum.TextXAlignment.Left,
		})

		-- Icon drawn on the right side of the cell
		local iconCX = cellLeft + cellW * 0.78
		iconDrawers[i](statsBar, iconCX, iconCY, 10)

		-- Thin vertical divider between cells (not after last)
		if i < 3 then
			makeFrame(statsBar, {
				Size             = UDim2.new(0, 1, 0, 28),
				Position         = UDim2.new(0, cellLeft + cellW - 1, 0, 9),
				BackgroundColor3 = Color3.fromRGB(60, 65, 78),
			})
		end
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
			local atkStat = panel:FindFirstChild("ATKStat", true)
			if atkStat then
				local newAtk = tostring(selectedTowerModel:GetAttribute("ATK") or 0)
				if atkStat.Text ~= newAtk then atkStat.Text = newAtk end
			end

			-- Update DMG label in the portrait box
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
