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

local placeRemote           = ReplicatedStorage:WaitForChild("PlaceTower",       10)
local moveRemote            = ReplicatedStorage:WaitForChild("MoveTower",        10)
local strikeSkillRemote     = ReplicatedStorage:WaitForChild("StrikeSkill",      10)
local sellTowerRemote       = ReplicatedStorage:WaitForChild("SellTower",        10)
local setTargetModeRemote   = ReplicatedStorage:WaitForChild("SetTargetMode",    10)
local loadoutConfigRemote   = ReplicatedStorage:WaitForChild("LoadoutConfigRequest", 10)
local loadoutUpdatedRemote  = ReplicatedStorage:WaitForChild("LoadoutConfigUpdated", 10)
local gameStateChanged      = ReplicatedStorage:WaitForChild("GameStateChanged",  10)
local gameStateValue        = ReplicatedStorage:WaitForChild("GameState",         10)
local CombatMath            = require(ReplicatedStorage:WaitForChild("CombatMath", 10))

local towersFolder  = Workspace:WaitForChild("Towers",  15)
local enemiesFolder = Workspace:WaitForChild("Enemies", 15)

local placing             = false
local selectedTower       = "Warrior"
local selectedTowerModel: Model? = nil
local canPlace            = false
local loadoutTowers       = { "Warrior" }
local selectedLoadoutSlot = 1

-- Strike Skill aiming state (Dynamite)
local strikeAiming       = false
local strikeTowerModel: Model? = nil
local strikeGhost: Part?       = nil      -- main cylinder body
local strikeRangeCircle: Part? = nil      -- flat range-indicator ring on the ground
local strikeCanPlace     = false

-- Strike Skill aiming state (Vitalist Nano Blast)
local vitalistAiming    = false
local vitalistAimTower: Model?         = nil
local vitalistAimRect: Part?           = nil
local vitalistAimConnection: RBXScriptConnection? = nil

-- Strike Skill aiming state (Pathfinder Soulbind)
local pathfinderAiming      = false
local pathfinderAimTower: Model?        = nil
local pathfinderAimGhost: Part?         = nil
local pathfinderRangeCircle: Part?      = nil
local pathfinderCanPlace    = false
local pathfinderAimConnection: RBXScriptConnection? = nil

local ghostFolder: Folder? = nil
local ghostParts    = {}
local rangePreview: Part? = nil
local ghostParented = false
local updateConnection: RBXScriptConnection? = nil

local towerHpGuis        = {}
local towerBarAttachments = {}

local STRIKE_SKILL_KEY     = Enum.KeyCode.Q
local GHOST_TRANSPARENCY = 0.5
local VALID_COLOR        = Color3.fromRGB(100, 255, 100)
local INVALID_COLOR      = Color3.fromRGB(255, 80,  80)
local HP_BAR_GAP         = 1.5

-- Dynamite range is half the tower's RNG attribute (resolved at aim-start)
local dynamiteRange      = 10   -- updated when aiming begins

local TOWER_RANGE_STUDS = {
	Warrior    = 8,
	Deadeye    = 30,
	Vitalist   = 20,
	Wanderer   = 60,
	Pathfinder = 20,
}

local startPlacing

local HOTBAR_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
}

local HOTBAR_COLORS = {
	Warrior = Color3.fromRGB(255, 120, 120),
	Deadeye = Color3.fromRGB(130, 170, 255),
	Vitalist = Color3.fromRGB(120, 255, 180),
	Wanderer = Color3.fromRGB(255, 210, 110),
	Pathfinder = Color3.fromRGB(180, 140, 255),
}

local hotbarGui = Instance.new("ScreenGui")
hotbarGui.Name = "TowerLoadoutHotbar"
hotbarGui.ResetOnSpawn = false
hotbarGui.IgnoreGuiInset = true
hotbarGui.Enabled = false
hotbarGui.Parent = playerGui

local hotbarContainer = Instance.new("Frame")
hotbarContainer.Name = "HotbarContainer"
hotbarContainer.Size = UDim2.new(0, 560, 0, 100)
hotbarContainer.Position = UDim2.new(0.5, -280, 1, -125)
hotbarContainer.BackgroundColor3 = Color3.fromRGB(35, 37, 50)
hotbarContainer.BackgroundTransparency = 0.15
hotbarContainer.BorderSizePixel = 0
hotbarContainer.Parent = hotbarGui

local hotbarCorner = Instance.new("UICorner")
hotbarCorner.CornerRadius = UDim.new(0, 10)
hotbarCorner.Parent = hotbarContainer

local hotbarStroke = Instance.new("UIStroke")
hotbarStroke.Color = Color3.fromRGB(255, 90, 120)
hotbarStroke.Thickness = 1
hotbarStroke.Transparency = 0.25
hotbarStroke.Parent = hotbarContainer

local hotbarLayout = Instance.new("UIListLayout")
hotbarLayout.FillDirection = Enum.FillDirection.Horizontal
hotbarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
hotbarLayout.VerticalAlignment = Enum.VerticalAlignment.Center
hotbarLayout.Padding = UDim.new(0, 10)
hotbarLayout.Parent = hotbarContainer

local hotbarPadding = Instance.new("UIPadding")
hotbarPadding.PaddingLeft = UDim.new(0, 10)
hotbarPadding.PaddingRight = UDim.new(0, 10)
hotbarPadding.PaddingTop = UDim.new(0, 8)
hotbarPadding.PaddingBottom = UDim.new(0, 8)
hotbarPadding.Parent = hotbarContainer

local hotbarSlots = {}

local function buildPreviewModel(towerType: string): Model
	local model = Instance.new("Model")
	model.Name = towerType .. "Preview"
	local color = HOTBAR_COLORS[towerType] or Color3.fromRGB(200, 200, 200)

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2.6, 1.4)
	torso.Color = color
	torso.Anchored = true
	torso.CanCollide = false
	torso.Material = Enum.Material.SmoothPlastic
	torso.Position = Vector3.new(0, 1.8, 0)
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.25, 1.25, 1.25)
	head.Color = Color3.new(1, 1, 1)
	head.Anchored = true
	head.CanCollide = false
	head.Material = Enum.Material.SmoothPlastic
	head.Position = Vector3.new(0, 3.45, 0)
	head.Parent = model

	local left = Instance.new("Part")
	left.Name = "Left"
	left.Size = Vector3.new(0.7, 2.0, 0.7)
	left.Color = color:Lerp(Color3.new(0, 0, 0), 0.2)
	left.Anchored = true
	left.CanCollide = false
	left.Material = Enum.Material.SmoothPlastic
	left.Position = Vector3.new(-0.9, 1.7, 0)
	left.Parent = model

	local right = left:Clone()
	right.Name = "Right"
	right.Position = Vector3.new(0.9, 1.7, 0)
	right.Parent = model

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.Position = Vector3.new(0, 1.8, 0)
	root.Parent = model
	model.PrimaryPart = root

	return model
end

local function updateHotbarSelectionVisuals()
	for i, slot in ipairs(hotbarSlots) do
		local isSelected = (i == selectedLoadoutSlot and loadoutTowers[i] == selectedTower)
		slot.stroke.Color = isSelected and Color3.fromRGB(255, 220, 120) or Color3.fromRGB(180, 185, 210)
		slot.stroke.Thickness = isSelected and 2 or 1
		slot.frame.BackgroundColor3 = isSelected and Color3.fromRGB(62, 66, 90) or Color3.fromRGB(46, 50, 70)
	end
end

local function rebuildHotbar()
	for _, slot in ipairs(hotbarSlots) do
		if slot.preview then
			slot.preview:Destroy()
		end
		slot.frame:Destroy()
	end
	hotbarSlots = {}

	local slotCount = math.max(#loadoutTowers, 1)
	hotbarContainer.Size = UDim2.new(0, 20 + (slotCount * 94), 0, 100)
	hotbarContainer.Position = UDim2.new(0.5, -(20 + (slotCount * 94)) / 2, 1, -125)

	for i, towerType in ipairs(loadoutTowers) do
		local button = Instance.new("TextButton")
		button.Name = "Slot" .. i
		button.Size = UDim2.new(0, 84, 1, 0)
		button.BackgroundColor3 = Color3.fromRGB(46, 50, 70)
		button.BorderSizePixel = 0
		button.Text = ""
		button.AutoButtonColor = false
		button.Parent = hotbarContainer

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(180, 185, 210)
		stroke.Thickness = 1
		stroke.Parent = button

		local viewport = Instance.new("ViewportFrame")
		viewport.Size = UDim2.new(1, -8, 1, -28)
		viewport.Position = UDim2.new(0, 4, 0, 4)
		viewport.BackgroundTransparency = 1
		viewport.BorderSizePixel = 0
		viewport.Parent = button

		local cam = Instance.new("Camera")
		cam.CFrame = CFrame.lookAt(Vector3.new(0, 3, 6), Vector3.new(0, 2, 0))
		cam.Parent = viewport
		viewport.CurrentCamera = cam

		local previewModel = buildPreviewModel(towerType)
		previewModel.Parent = viewport

		local keyLabel = Instance.new("TextLabel")
		keyLabel.Size = UDim2.new(0, 18, 0, 18)
		keyLabel.Position = UDim2.new(0, 3, 1, -21)
		keyLabel.BackgroundColor3 = Color3.fromRGB(25, 27, 37)
		keyLabel.BorderSizePixel = 0
		keyLabel.Text = tostring(i)
		keyLabel.TextColor3 = Color3.fromRGB(240, 240, 250)
		keyLabel.TextScaled = true
		keyLabel.Font = Enum.Font.GothamBold
		keyLabel.Parent = button
		local keyCorner = Instance.new("UICorner")
		keyCorner.CornerRadius = UDim.new(0, 5)
		keyCorner.Parent = keyLabel

		local towerLabel = Instance.new("TextLabel")
		towerLabel.Size = UDim2.new(1, -24, 0, 18)
		towerLabel.Position = UDim2.new(0, 22, 1, -21)
		towerLabel.BackgroundTransparency = 1
		towerLabel.TextXAlignment = Enum.TextXAlignment.Left
		towerLabel.Text = towerType
		towerLabel.TextColor3 = Color3.fromRGB(230, 235, 250)
		towerLabel.TextScaled = true
		towerLabel.Font = Enum.Font.GothamBold
		towerLabel.Parent = button

		button.MouseButton1Click:Connect(function()
			selectedLoadoutSlot = i
			startPlacing(towerType)
			updateHotbarSelectionVisuals()
		end)

		table.insert(hotbarSlots, {
			frame = button,
			stroke = stroke,
			preview = previewModel,
			tower = towerType,
		})
	end

	updateHotbarSelectionVisuals()
end

local function syncLoadoutFromSnapshot(snapshot: table?)
	if type(snapshot) ~= "table" then return end
	if type(snapshot.loadout) == "table" and #snapshot.loadout > 0 then
		loadoutTowers = {}
		for _, towerType in ipairs(snapshot.loadout) do
			if type(towerType) == "string" then
				table.insert(loadoutTowers, towerType)
			end
		end
	end
	if #loadoutTowers == 0 then
		loadoutTowers = { "Warrior" }
	end
	selectedLoadoutSlot = math.clamp(selectedLoadoutSlot, 1, #loadoutTowers)
	selectedTower = loadoutTowers[selectedLoadoutSlot] or loadoutTowers[1]
	rebuildHotbar()
end

local function requestLoadoutSnapshot()
	local ok, response = pcall(function()
		return loadoutConfigRemote:InvokeServer("Get", {})
	end)
	if ok and type(response) == "table" and response.data then
		syncLoadoutFromSnapshot(response.data)
	end
end

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
	if ghostFolder    then table.insert(ignoreList, ghostFolder)    end
	if enemiesFolder  then table.insert(ignoreList, enemiesFolder)  end
	if towersFolder   then table.insert(ignoreList, towersFolder)   end
	if player.Character then table.insert(ignoreList, player.Character) end

	-- Ignore all dynamite/strike ghosts
	if strikeGhost       and strikeGhost.Parent       then table.insert(ignoreList, strikeGhost)       end
	if strikeRangeCircle and strikeRangeCircle.Parent then table.insert(ignoreList, strikeRangeCircle) end
	if vitalistAimRect   and vitalistAimRect.Parent   then table.insert(ignoreList, vitalistAimRect)   end

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
	{ "Torso",    Vector3.new(2,   2.4, 1.2), Vector3.new( 0,    3.5, 0) },
	{ "Head",     Vector3.new(1.4, 1.4, 1.4), Vector3.new( 0,    5.6, 0) },
	{ "LeftArm",  Vector3.new(0.8, 2.4, 1),   Vector3.new(-1.4,  3.3, 0) },
	{ "RightArm", Vector3.new(0.8, 2.4, 1),   Vector3.new( 1.4,  3.3, 0) },
	{ "LeftLeg",  Vector3.new(0.9, 2.4, 1),   Vector3.new(-0.5,  1.2, 0) },
	{ "RightLeg", Vector3.new(0.9, 2.4, 1),   Vector3.new( 0.5,  1.2, 0) },
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
	range.Color = Color3.fromRGB(50, 150, 255); range.Transparency = 0.7
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
		data.part.Color  = VALID_COLOR
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
	local torso = towerModel.PrimaryPart
	local pos   = torso and torso.Position

	local circle = towerModel:FindFirstChild("RangeCircle")
	if circle then
		circle.Transparency = 0.6
		if pos then
			circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end

	local leapCircle = towerModel:FindFirstChild("LeapRangeCircle")
	if leapCircle then
		local cdEnd = towerModel:GetAttribute("LeapSlashCooldown") or 0
		leapCircle.Transparency = tick() >= cdEnd and 0.8 or 0.92
		if pos then
			leapCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end

	-- Vitalist protocol-switch range indicator (yellow, same as strike indicator)
	local moveCircle = towerModel:FindFirstChild("MoveRangeCircle")
	if moveCircle then
		moveCircle.Transparency = 0.75
		if pos then
			moveCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end

	-- Wanderer drone range circle (follows the drone's current position)
	local droneRangeCircle = towerModel:FindFirstChild("DroneRangeCircle")
	if droneRangeCircle then
		local droneModel = towerModel:FindFirstChild("Drone")
		local dronePart  = droneModel and droneModel.PrimaryPart
		if dronePart then
			local dp = dronePart.Position
			droneRangeCircle.CFrame = CFrame.new(dp.X, dp.Y - 5.5, dp.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
		droneRangeCircle.Transparency = 0.65
	end
end

local function hideTowerRange(towerModel: Model)
	local circle = towerModel:FindFirstChild("RangeCircle")
	if circle then circle.Transparency = 1 end
	local leapCircle = towerModel:FindFirstChild("LeapRangeCircle")
	if leapCircle then leapCircle.Transparency = 1 end
	local moveCircle = towerModel:FindFirstChild("MoveRangeCircle")
	if moveCircle then moveCircle.Transparency = 1 end
	local droneRangeCircle = towerModel:FindFirstChild("DroneRangeCircle")
	if droneRangeCircle then droneRangeCircle.Transparency = 1 end
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

startPlacing = function(towerType: string)
	if strikeAiming then
		-- will be cleaned up below via stopStrikeAiming (declared later but fine here)
	end
	if placing and selectedTower == towerType then stopPlacing(); return end
	selectedTower = towerType
	local idx = table.find(loadoutTowers, towerType)
	if idx then selectedLoadoutSlot = idx end
	updateHotbarSelectionVisuals()
	placing = true; deselectTower(); createGhost()
	if updateConnection then updateConnection:Disconnect(); updateConnection = nil end
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
	while current and current ~= workspace do
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
		strikeSkill  = {
			name    = "DYNAMITE  [Q]",
			desc    = "Place within half the tower's range. Deadeye auto-targets it with Headhunter. Explodes for 0.6× ATK AoE + 0.2× AP/s fire (3s).",
			skillId = "Dynamite",
		},
	},
	Vitalist = {
		displayName  = "Vitalist",
		sellValue    = 155,
		upgradeCost  = 4500,
		upgradeLines = { "+4 AP, +5 Range", "1.2s > 0.9s Attack Rate", "Nano Blast pierces 2 extra targets" },
		upgradeName  = "Medical Supply Enhancement",
		level        = 0,
		maxLevel     = 3,
		strikeSkill  = {
			name    = "NANO BLAST  [Q]",
			desc    = "SUPP: green laser heals nearest ally 2× AP. ATK: blue laser deals 2× AP. 12s cooldown.",
			skillId = "NanoBlast",
		},
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
	Wanderer = {
		displayName  = "Wanderer",
		sellValue    = 250,
		upgradeCost  = 6000,
		upgradeLines = {
			"+4 ATK, +5 Range (drone)",
			"Suppressing Fire radius +2, duration +2s",
			"Reconnaissance: +3s duration, High Caliber damage +0.5×",
		},
		upgradeName  = "Advanced Drone Package",
		level        = 0,
		maxLevel     = 3,
		strikeSkill  = {
			name    = "RECONNAISSANCE  [Q]",
			desc    = "Drone pulses green light for 6s. Wanderer targets enemies in drone range, firing High Caliber (1.5× ATK) instead of Heavy Rounds. 20s cooldown.",
			skillId = "Reconnaissance",
		},
	},
	Pathfinder = {
		displayName  = "Pathfinder",
		sellValue    = 250,
		upgradeCost  = 6000,
		upgradeLines = {
			"+3 ATK, +3 Range",
			"Soulbind: 4s > 3s CD, max 5 souls",
			"Reclamation: +0.1× waypoint amplification",
		},
		upgradeName  = "Ethereal Mastery",
		level        = 0,
		maxLevel     = 3,
		strikeSkill  = {
			name    = "SOULBIND  [Q]",
			desc    = "Fire a spectral bolt (0.8× ATK). Lodges a Tethered Soul for 8s (max 4). If host dies, soul becomes Untethered for 12s. 4s cooldown.",
			skillId = "Soulbind",
		},
	},
}

local PANEL_W = 540
local PANEL_H = 365

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function makeLabel(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	for k, v in pairs(props) do l[k] = v end
	l.Parent = parent
	return l
end

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
	local atkSpd    = CombatMath.ResolveIntegerStat(towerModel:GetAttribute("ATK_SPD"), 0, 0)
	local rng       = towerModel:GetAttribute("RNG")     or 0
	local def       = towerModel:GetAttribute("DEF")     or 0
	local moveSpd   = towerModel:GetAttribute("MOVE_SPD") or 0

	local info = TOWER_PANEL_DATA[towerType] or TOWER_PANEL_DATA.Warrior

	local gui = Instance.new("ScreenGui")
	gui.Name         = "TowerInfoGUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent       = playerGui

	local panel = Instance.new("Frame")
	panel.Name             = "Panel"
	panel.Size             = UDim2.new(0, PANEL_W, 0, PANEL_H)
	panel.Position         = UDim2.new(0, 14, 1, -(PANEL_H + 14))
	panel.BackgroundColor3 = Color3.fromRGB(52, 57, 68)
	panel.BorderSizePixel  = 0
	panel.ClipsDescendants = false
	panel.Parent           = gui
	corner(panel, 10)

	local titleBg = makeFrame(panel, {
		Size             = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = Color3.fromRGB(68, 73, 86),
	})
	corner(titleBg, 10)
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

	local portraitBox = makeFrame(panel, {
		Name             = "PortraitBox",
		Size             = UDim2.new(0, 132, 0, 132),
		Position         = UDim2.new(0, 10, 0, 48),
		BackgroundColor3 = Color3.fromRGB(72, 77, 90),
	})
	corner(portraitBox, 7)

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

	local portrait = Instance.new("ImageLabel")
	portrait.Size                   = UDim2.new(1, -8, 0, 98)
	portrait.Position               = UDim2.new(0, 4, 0, 28)
	portrait.BackgroundColor3       = Color3.fromRGB(42, 46, 57)
	portrait.BackgroundTransparency = 0
	portrait.BorderSizePixel        = 0
	portrait.Image                  = "rbxassetid://0"
	portrait.Parent                 = portraitBox
	corner(portrait, 5)

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

	makeFrame(panel, {
		Size             = UDim2.new(1, -16, 0, 1),
		Position         = UDim2.new(0, 8, 0, 228),
		BackgroundColor3 = Color3.fromRGB(80, 86, 100),
	})

	local BTN_Y = 232
	local BTN_H = 44

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
	sellBtn.MouseButton1Click:Connect(function()
		if towerModel and towerModel.Parent then
			sellTowerRemote:FireServer(towerModel)
			deselectTower()
		end
	end)

	-- Targeting mode cycling
	local TARGET_MODES = { "First", "Last", "Strongest", "Weakest", "Random" }
	local currentModeIdx = 1
	local function getTargetModeIdx(mode)
		for i, m in ipairs(TARGET_MODES) do if m == mode then return i end end
		return 1
	end
	currentModeIdx = getTargetModeIdx(towerModel:GetAttribute("TargetMode") or "First")
	local targetModeLbl = targetBox:FindFirstChild("TargetModeLabel", true)
	if targetModeLbl then
		targetModeLbl.Text = "Targets: " .. TARGET_MODES[currentModeIdx]
	end
	local targetClickBtn = Instance.new("TextButton")
	targetClickBtn.Size             = UDim2.new(1, 0, 1, 0)
	targetClickBtn.BackgroundTransparency = 1
	targetClickBtn.Text             = ""
	targetClickBtn.Parent           = targetBox
	targetClickBtn.ZIndex           = 5
	targetClickBtn.MouseButton1Click:Connect(function()
		currentModeIdx = (currentModeIdx % #TARGET_MODES) + 1
		local newMode = TARGET_MODES[currentModeIdx]
		if targetModeLbl then
			targetModeLbl.Text = "Targets: " .. newMode
		end
		if towerModel and towerModel.Parent then
			setTargetModeRemote:FireServer(towerModel, newMode)
		end
	end)

	-- ─── Cooldown bars ───────────────────────────────────────────
	local CD_BAR_Y  = BTN_Y + BTN_H + 4
	local CD_BAR_H  = 10
	local CD_HALF_W = (PANEL_W - 24) / 2

	-- Strike cooldown bar
	local strikeCdBg = makeFrame(panel, {
		Size             = UDim2.new(0, CD_HALF_W, 0, CD_BAR_H),
		Position         = UDim2.new(0, 8, 0, CD_BAR_Y),
		BackgroundColor3 = Color3.fromRGB(30, 30, 40),
		ClipsDescendants = true,
	})
	corner(strikeCdBg, 4)
	local strikeCdFill = makeFrame(strikeCdBg, {
		Name             = "StrikeCDFill",
		Size             = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(255, 200, 50),
	})
	makeLabel(strikeCdBg, {
		Name           = "StrikeCDLabel",
		Size           = UDim2.new(1, 0, 1, 0),
		Text           = "Strike CD: 0",
		TextColor3     = Color3.fromRGB(220, 220, 220),
		Font           = Enum.Font.Gotham,
		TextSize        = 9,
	})

	-- Move cooldown bar
	local moveCdBg = makeFrame(panel, {
		Size             = UDim2.new(0, CD_HALF_W, 0, CD_BAR_H),
		Position         = UDim2.new(0, 8 + CD_HALF_W + 8, 0, CD_BAR_Y),
		BackgroundColor3 = Color3.fromRGB(30, 30, 40),
		ClipsDescendants = true,
	})
	corner(moveCdBg, 4)
	local moveCdFill = makeFrame(moveCdBg, {
		Name             = "MoveCDFill",
		Size             = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(50, 180, 255),
	})
	makeLabel(moveCdBg, {
		Name           = "MoveCDLabel",
		Size           = UDim2.new(1, 0, 1, 0),
		Text           = "Move CD: 0",
		TextColor3     = Color3.fromRGB(220, 220, 220),
		Font           = Enum.Font.Gotham,
		TextSize        = 9,
	})

	-- Store references on the panel for the update loop
	strikeCdFill.Name = "StrikeCDFill"
	moveCdFill.Name   = "MoveCDFill"

	local STATS_Y = PANEL_H - 58
	local statsBar = makeFrame(panel, {
		Size             = UDim2.new(1, 0, 0, 58),
		Position         = UDim2.new(0, 0, 0, STATS_Y),
		BackgroundColor3 = Color3.fromRGB(36, 40, 50),
	})
	corner(statsBar, 10)
	makeFrame(statsBar, {
		Size             = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(36, 40, 50),
	})

	local statCells = {
		{ name = "ATKStat", value = tostring(atk),               symbol = "/" },
		{ name = "RNGStat", value = tostring(rng),               symbol = "o" },
		{ name = "SPDStat", value = tostring(atkSpd), symbol = "s" },
	}

	local function makeSwordIcon(parent, cx, cy, sz)
		makeFrame(parent, { Size = UDim2.new(0, 3, 0, sz),       Position = UDim2.new(0, cx - 1, 0, cy - sz / 2), BackgroundColor3 = Color3.fromRGB(150, 158, 175), Rotation = 45 })
		makeFrame(parent, { Size = UDim2.new(0, sz * 0.55, 0, 3), Position = UDim2.new(0, cx - sz * 0.275, 0, cy + sz * 0.08), BackgroundColor3 = Color3.fromRGB(150, 158, 175) })
	end

	local function makeCircleIcon(parent, cx, cy, r)
		local ring = makeFrame(parent, { Size = UDim2.new(0, r*2, 0, r*2), Position = UDim2.new(0, cx-r, 0, cy-r), BackgroundColor3 = Color3.fromRGB(150, 158, 175) })
		corner(ring, r)
		local inner = makeFrame(ring, { Size = UDim2.new(0, r*2-4, 0, r*2-4), Position = UDim2.new(0, 2, 0, 2), BackgroundColor3 = Color3.fromRGB(36, 40, 50) })
		corner(inner, r - 2)
		makeFrame(ring, { Size = UDim2.new(0, 4, 0, 4), Position = UDim2.new(0, r-2, 0, r-2), BackgroundColor3 = Color3.fromRGB(150, 158, 175) })
	end

	local function makeClockIcon(parent, cx, cy, r)
		local face = makeFrame(parent, { Size = UDim2.new(0, r*2, 0, r*2), Position = UDim2.new(0, cx-r, 0, cy-r), BackgroundColor3 = Color3.fromRGB(150, 158, 175) })
		corner(face, r)
		local inner = makeFrame(face, { Size = UDim2.new(0, r*2-4, 0, r*2-4), Position = UDim2.new(0, 2, 0, 2), BackgroundColor3 = Color3.fromRGB(36, 40, 50) })
		corner(inner, r - 2)
		makeFrame(face, { Size = UDim2.new(0, 2, 0, r*0.55), Position = UDim2.new(0, r-1, 0, r-r*0.55), BackgroundColor3 = Color3.fromRGB(150, 158, 175) })
		makeFrame(face, { Size = UDim2.new(0, r*0.55, 0, 2), Position = UDim2.new(0, r, 0, r-1),         BackgroundColor3 = Color3.fromRGB(150, 158, 175) })
	end

	local iconDrawers = { makeSwordIcon, makeCircleIcon, makeClockIcon }
	local cellW  = PANEL_W / 3
	local iconCY = 23

	for i, s in ipairs(statCells) do
		local cellLeft = (i - 1) * cellW
		makeLabel(statsBar, {
			Name           = s.name,
			Size           = UDim2.new(0, cellW * 0.5, 1, 0),
			Position       = UDim2.new(0, cellLeft + 12, 0, 0),
			Text           = s.value,
			TextColor3     = Color3.fromRGB(225, 228, 235),
			Font           = Enum.Font.GothamBold,
			TextSize       = 20,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		iconDrawers[i](statsBar, cellLeft + cellW * 0.78, iconCY, 10)
		if i < 3 then
			makeFrame(statsBar, {
				Size             = UDim2.new(0, 1, 0, 28),
				Position         = UDim2.new(0, cellLeft + cellW - 1, 0, 9),
				BackgroundColor3 = Color3.fromRGB(60, 65, 78),
			})
		end
	end

	makeLabel(statsBar, {
		Name           = "SecondaryStatLabel",
		Size           = UDim2.new(1, -16, 0, 16),
		Position       = UDim2.new(0, 8, 0, 40),
		Text           = ("DEF %d  |  MVE %d  |  ATK_SPD %ds"):format(def, moveSpd, atkSpd),
		TextColor3     = Color3.fromRGB(172, 178, 194),
		Font           = Enum.Font.GothamSemibold,
		TextSize       = 10,
		TextXAlignment = Enum.TextXAlignment.Center,
	})

	if info.strikeSkill then
		makeFrame(panel, {
			Size             = UDim2.new(1, -16, 0, 1),
			Position         = UDim2.new(0, 8, 0, 277),
			BackgroundColor3 = Color3.fromRGB(80, 86, 100),
		})
		makeLabel(panel, {
			Size           = UDim2.new(1, -16, 0, 16),
			Position       = UDim2.new(0, 8, 0, 281),
			Text           = "STRIKE SKILL",
			TextColor3     = Color3.fromRGB(255, 200, 50),
			Font           = Enum.Font.GothamBold,
			TextSize       = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local nameBadge = makeFrame(panel, {
			Size             = UDim2.new(0, 180, 0, 22),
			Position         = UDim2.new(0, 8, 0, 298),
			BackgroundColor3 = Color3.fromRGB(45, 55, 70),
		})
		corner(nameBadge, 5)
		makeLabel(nameBadge, {
			Size           = UDim2.new(1, -8, 1, 0),
			Position       = UDim2.new(0, 4, 0, 0),
			Text           = info.strikeSkill.name,
			TextColor3     = Color3.fromRGB(100, 200, 255),
			Font           = Enum.Font.GothamBold,
			TextSize       = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		makeLabel(panel, {
			Size           = UDim2.new(1, -200, 0, 44),
			Position       = UDim2.new(0, 196, 0, 278),
			Text           = info.strikeSkill.desc,
			TextColor3     = Color3.fromRGB(185, 192, 208),
			Font           = Enum.Font.Gotham,
			TextSize       = 10,
			TextWrapped    = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})
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
	local hp   = m:GetAttribute("HP")    or 0
	local maxHp = m:GetAttribute("MaxHP") or 1
	local a    = getTowerCenterAttachment(m); if not a then return nil end
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

for _, c in ipairs(Workspace:GetChildren()) do
	if c.Name == "PlacementGhostFolder" and c:IsA("Folder") then c:Destroy() end
end

-- ============================================================
-- UPDATE LOOP
-- ============================================================

RunService.RenderStepped:Connect(function(dt)
	for model, gui in pairs(towerHpGuis) do
		if model and model.Parent then
			updateTowerAttachment(model)
			local hp    = model:GetAttribute("HP")    or 0
			local maxHp = model:GetAttribute("MaxHP") or 1
			local ratio = math.clamp(hp/maxHp, 0, 1)
			local cont  = gui:FindFirstChild("Container")
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

	if selectedTowerModel and selectedTowerModel.Parent and infoGui then
		showTowerRange(selectedTowerModel)
		local panel = infoGui:FindFirstChild("Panel")
		if panel then
			local atkStat = panel:FindFirstChild("ATKStat", true)
			if atkStat then
				local newAtk = tostring(selectedTowerModel:GetAttribute("ATK") or 0)
				if atkStat.Text ~= newAtk then atkStat.Text = newAtk end
			end
			local rngStat = panel:FindFirstChild("RNGStat", true)
			if rngStat then
				local newRng = tostring(selectedTowerModel:GetAttribute("RNG") or 0)
				if rngStat.Text ~= newRng then rngStat.Text = newRng end
			end
			local spdStat = panel:FindFirstChild("SPDStat", true)
			if spdStat then
				local newSpd = tostring(CombatMath.ResolveIntegerStat(selectedTowerModel:GetAttribute("ATK_SPD"), 0, 0))
				if spdStat.Text ~= newSpd then spdStat.Text = newSpd end
			end
			local secondary = panel:FindFirstChild("SecondaryStatLabel", true)
			if secondary then
				local def = selectedTowerModel:GetAttribute("DEF") or 0
				local mve = selectedTowerModel:GetAttribute("MOVE_SPD") or 0
				local atkSpd = CombatMath.ResolveIntegerStat(selectedTowerModel:GetAttribute("ATK_SPD"), 0, 0)
				local text = ("DEF %d  |  MVE %d  |  ATK_SPD %ds"):format(def, mve, atkSpd)
				if secondary.Text ~= text then secondary.Text = text end
			end
			local dmgLabel = panel:FindFirstChild("DMGLabel", true)
			if dmgLabel then
				local newAtk   = tostring(selectedTowerModel:GetAttribute("ATK") or 0)
				local expected = "DMG: " .. newAtk
				if dmgLabel.Text ~= expected then dmgLabel.Text = expected end
			end

			-- Update Strike cooldown bar
			local strikeFill = panel:FindFirstChild("StrikeCDFill", true)
			if strikeFill then
				local cdEnd = selectedTowerModel:GetAttribute("StrikeCooldownEnd") or 0
				local cdMax = selectedTowerModel:GetAttribute("StrikeCooldownMax") or 1
				local remaining = math.max(0, cdEnd - tick())
				local fraction  = cdMax > 0 and math.clamp(remaining / cdMax, 0, 1) or 0
				strikeFill.Size = UDim2.new(fraction, 0, 1, 0)
				local strikeLabel = panel:FindFirstChild("StrikeCDLabel", true)
				if strikeLabel then
					strikeLabel.Text = "Strike CD: " .. tostring(math.ceil(remaining))
				end
			end

			-- Update Move cooldown bar
			local moveFill = panel:FindFirstChild("MoveCDFill", true)
			if moveFill then
				local cdEnd = selectedTowerModel:GetAttribute("MoveCooldownEnd") or 0
				local cdMax = selectedTowerModel:GetAttribute("MoveCooldownMax") or 1
				local remaining = math.max(0, cdEnd - tick())
				local fraction  = cdMax > 0 and math.clamp(remaining / cdMax, 0, 1) or 0
				moveFill.Size = UDim2.new(fraction, 0, 1, 0)
				local moveLabel = panel:FindFirstChild("MoveCDLabel", true)
				if moveLabel then
					moveLabel.Text = "Move CD: " .. tostring(math.ceil(remaining))
				end
			end
		end
	elseif selectedTowerModel and not selectedTowerModel.Parent then
		deselectTower()
	end
end)

-- ============================================================
-- STRIKE SKILL AIMING (Dynamite)
-- ============================================================

local function stopStrikeAiming()
	if strikeGhost       and strikeGhost.Parent       then strikeGhost:Destroy()       end
	if strikeRangeCircle and strikeRangeCircle.Parent then strikeRangeCircle:Destroy() end
	strikeGhost        = nil
	strikeRangeCircle  = nil
	strikeAiming       = false
	strikeTowerModel   = nil
	strikeCanPlace     = false
	if updateConnection then updateConnection:Disconnect(); updateConnection = nil end
end

local function startStrikeAiming(towerModel: Model)
	if placing then stopPlacing() end
	stopStrikeAiming()
	strikeAiming     = true
	strikeTowerModel = towerModel

	-- Resolve range: half the tower's RNG attribute
	local towerRng  = towerModel:GetAttribute("RNG") or TOWER_RANGE_STUDS.Deadeye or 30
	dynamiteRange   = towerRng * 0.5

	-- ── Ghost indicator: a small box (no rotation tricks = no camera drift) ──
	local g          = Instance.new("Part")
	g.Name           = "DynamiteGhost"
	g.Shape          = Enum.PartType.Block      -- plain box, no rotation needed
	g.Size           = Vector3.new(1.2, 0.6, 0.6)
	g.Color          = Color3.fromRGB(255, 140, 20)
	g.Transparency   = 0.35
	g.Material       = Enum.Material.Neon
	g.Anchored       = true
	g.CanCollide     = false
	g.CastShadow     = false
	g.CFrame         = CFrame.new(0, -1000, 0)
	g.Parent         = Workspace
	strikeGhost      = g

	-- ── Range indicator: flat cylinder lying on the ground ──
	local rc         = Instance.new("Part")
	rc.Name          = "DynamiteRangeCircle"
	rc.Shape         = Enum.PartType.Cylinder
	rc.Size          = Vector3.new(0.12, dynamiteRange * 2, dynamiteRange * 2)
	rc.Color         = Color3.fromRGB(255, 180, 50)
	rc.Transparency  = 0.65
	rc.Material      = Enum.Material.Neon
	rc.Anchored      = true
	rc.CanCollide    = false
	rc.CastShadow    = false
	rc.CFrame        = CFrame.new(0, -1000, 0)
	rc.Parent        = Workspace
	strikeRangeCircle = rc

	-- Position the range circle at the tower immediately
	if towerModel.PrimaryPart then
		local tp = towerModel.PrimaryPart.Position
		strikeRangeCircle.CFrame = CFrame.new(tp.X, tp.Y - 2.4, tp.Z)
			* CFrame.Angles(0, 0, math.rad(90))
	end

	updateConnection = RunService.RenderStepped:Connect(function()
		if not strikeAiming then return end
		if not strikeTowerModel or not strikeTowerModel.PrimaryPart then return end

		local tPos = strikeTowerModel.PrimaryPart.Position

		-- Keep range circle pinned to the tower (it never moves)
		strikeRangeCircle.CFrame = CFrame.new(tPos.X, tPos.Y - 2.4, tPos.Z)
			* CFrame.Angles(0, 0, math.rad(90))

		local groundPos = raycastGround()
		if not groundPos then
			strikeCanPlace = false
			strikeGhost.CFrame = CFrame.new(0, -1000, 0)  -- hide off-screen
			return
		end

		local flatDist = Vector3.new(groundPos.X - tPos.X, 0, groundPos.Z - tPos.Z).Magnitude
		strikeCanPlace = (flatDist <= dynamiteRange)

		-- Place ghost flat on the ground (just Y-lift of 0.3, no cylinder rotation)
		strikeGhost.CFrame = CFrame.new(groundPos.X, groundPos.Y + 0.3, groundPos.Z)
		strikeGhost.Color  = strikeCanPlace
			and Color3.fromRGB(255, 140, 20)
			or  Color3.fromRGB(255,  60, 60)
	end)
end

-- ============================================================
-- STRIKE SKILL AIMING (Vitalist Nano Blast)
-- ============================================================

local VITALIST_PIERCE_RADIUS = 4.5

local function stopVitalistAiming()
	if vitalistAimRect and vitalistAimRect.Parent then vitalistAimRect:Destroy() end
	vitalistAimRect  = nil
	vitalistAiming   = false
	vitalistAimTower = nil
	if vitalistAimConnection then vitalistAimConnection:Disconnect(); vitalistAimConnection = nil end
end

local function startVitalistAiming(towerModel: Model)
	if placing then stopPlacing() end
	stopStrikeAiming()
	stopVitalistAiming()

	vitalistAiming   = true
	vitalistAimTower = towerModel

	local rect         = Instance.new("Part")
	rect.Name          = "VitalistAimRect"
	rect.Size          = Vector3.new(VITALIST_PIERCE_RADIUS * 2, 0.15, TOWER_RANGE_STUDS.Vitalist)
	rect.Color         = Color3.fromRGB(50, 150, 255)
	rect.Transparency  = 0.45
	rect.Material      = Enum.Material.Neon
	rect.Anchored      = true
	rect.CanCollide    = false
	rect.CastShadow    = false
	rect.CFrame        = CFrame.new(0, -1000, 0)
	rect.Parent        = Workspace
	vitalistAimRect    = rect

	vitalistAimConnection = RunService.RenderStepped:Connect(function()
		if not vitalistAiming then return end
		if not vitalistAimTower or not vitalistAimTower.PrimaryPart then return end

		local towerRng = vitalistAimTower:GetAttribute("RNG") or TOWER_RANGE_STUDS.Vitalist or 20
		local aimRange = towerRng * 2

		local protocol = vitalistAimTower:GetAttribute("Protocol") or "ATK"
		rect.Color = (protocol == "SUPP")
			and Color3.fromRGB(50, 220, 80)
			or  Color3.fromRGB(50, 150, 255)

		local groundPos = raycastGround()
		local tPos      = vitalistAimTower.PrimaryPart.Position

		local aimDir: Vector3
		if groundPos then
			local flat = Vector3.new(groundPos.X - tPos.X, 0, groundPos.Z - tPos.Z)
			aimDir = flat.Magnitude > 0.5 and flat.Unit or Vector3.new(0, 0, 1)
		else
			aimDir = Vector3.new(0, 0, 1)
		end

		rect.Size = Vector3.new(VITALIST_PIERCE_RADIUS * 2, 0.15, aimRange)
		local centerPos = Vector3.new(
			tPos.X + aimDir.X * (aimRange / 2),
			tPos.Y - 2.3,
			tPos.Z + aimDir.Z * (aimRange / 2)
		)
		rect.CFrame = CFrame.new(centerPos, centerPos + aimDir)
	end)
end

-- ============================================================
-- STRIKE SKILL AIMING (Pathfinder Soulbind)
-- ============================================================

local function stopPathfinderAiming()
	if pathfinderAimGhost   and pathfinderAimGhost.Parent   then pathfinderAimGhost:Destroy()   end
	if pathfinderRangeCircle and pathfinderRangeCircle.Parent then pathfinderRangeCircle:Destroy() end
	pathfinderAimGhost   = nil
	pathfinderRangeCircle = nil
	pathfinderAiming     = false
	pathfinderAimTower   = nil
	pathfinderCanPlace   = false
	if pathfinderAimConnection then pathfinderAimConnection:Disconnect(); pathfinderAimConnection = nil end
end

local function startPathfinderAiming(towerModel: Model)
	if placing then stopPlacing() end
	stopStrikeAiming()
	stopVitalistAiming()
	stopPathfinderAiming()

	pathfinderAiming   = true
	pathfinderAimTower = towerModel

	local towerRng = towerModel:GetAttribute("RNG") or TOWER_RANGE_STUDS.Pathfinder or 20

	-- Ghost indicator (spectral orb)
	local g          = Instance.new("Part")
	g.Name           = "SoulbindGhost"
	g.Shape          = Enum.PartType.Ball
	g.Size           = Vector3.new(0.8, 0.8, 0.8)
	g.Color          = Color3.fromRGB(140, 220, 255)
	g.Transparency   = 0.3
	g.Material       = Enum.Material.Neon
	g.Anchored       = true
	g.CanCollide     = false
	g.CastShadow     = false
	g.CFrame         = CFrame.new(0, -1000, 0)
	g.Parent         = Workspace
	pathfinderAimGhost = g

	-- Range circle
	local rc         = Instance.new("Part")
	rc.Name          = "SoulbindRangeCircle"
	rc.Shape         = Enum.PartType.Cylinder
	rc.Size          = Vector3.new(0.12, towerRng * 2, towerRng * 2)
	rc.Color         = Color3.fromRGB(100, 180, 255)
	rc.Transparency  = 0.65
	rc.Material      = Enum.Material.Neon
	rc.Anchored      = true
	rc.CanCollide    = false
	rc.CastShadow    = false
	rc.CFrame        = CFrame.new(0, -1000, 0)
	rc.Parent        = Workspace
	pathfinderRangeCircle = rc

	if towerModel.PrimaryPart then
		local tp = towerModel.PrimaryPart.Position
		rc.CFrame = CFrame.new(tp.X, tp.Y - 2.4, tp.Z) * CFrame.Angles(0, 0, math.rad(90))
	end

	pathfinderAimConnection = RunService.RenderStepped:Connect(function()
		if not pathfinderAiming then return end
		if not pathfinderAimTower or not pathfinderAimTower.PrimaryPart then return end

		local tPos = pathfinderAimTower.PrimaryPart.Position
		pathfinderRangeCircle.CFrame = CFrame.new(tPos.X, tPos.Y - 2.4, tPos.Z)
			* CFrame.Angles(0, 0, math.rad(90))

		local groundPos = raycastGround()
		if not groundPos then
			pathfinderCanPlace = false
			pathfinderAimGhost.CFrame = CFrame.new(0, -1000, 0)
			return
		end

		local flatDist = Vector3.new(groundPos.X - tPos.X, 0, groundPos.Z - tPos.Z).Magnitude
		pathfinderCanPlace = (flatDist <= towerRng)

		pathfinderAimGhost.CFrame = CFrame.new(groundPos.X, groundPos.Y + 0.6, groundPos.Z)
		pathfinderAimGhost.Color  = pathfinderCanPlace
			and Color3.fromRGB(140, 220, 255)
			or  Color3.fromRGB(255,  60, 60)
	end)
end

-- ============================================================
-- INPUT
-- ============================================================

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	local keySlot = table.find(HOTBAR_KEYS, input.KeyCode)
	if keySlot and loadoutTowers[keySlot] then
		selectedLoadoutSlot = keySlot
		startPlacing(loadoutTowers[keySlot])
		updateHotbarSelectionVisuals()
	elseif input.KeyCode == STRIKE_SKILL_KEY then
		if strikeAiming     then stopStrikeAiming();     return end
		if vitalistAiming   then stopVitalistAiming();    return end
		if pathfinderAiming then stopPathfinderAiming();  return end
		if not selectedTowerModel or not selectedTowerModel.Parent then return end
		local towerType = selectedTowerModel:GetAttribute("TowerType")
		local panelData = TOWER_PANEL_DATA[towerType]
		if not panelData or not panelData.strikeSkill then return end

		if towerType == "Deadeye" then
			startStrikeAiming(selectedTowerModel)
		elseif towerType == "Vitalist" then
			startVitalistAiming(selectedTowerModel)
		elseif towerType == "Wanderer" then
			-- Reconnaissance: fire-and-forget, no aiming needed
			strikeSkillRemote:FireServer(selectedTowerModel, "Reconnaissance", Vector3.zero)
		elseif towerType == "Pathfinder" then
			startPathfinderAiming(selectedTowerModel)
		end
	end
end)

mouse.Button1Down:Connect(function()
	if pathfinderAiming then
		if pathfinderCanPlace then
			local groundPos = raycastGround()
			if groundPos and pathfinderAimTower and pathfinderAimTower.PrimaryPart then
				strikeSkillRemote:FireServer(pathfinderAimTower, "Soulbind", groundPos)
			end
		end
		stopPathfinderAiming()
		return
	end

	if vitalistAiming then
		local groundPos = raycastGround()
		if groundPos and vitalistAimTower and vitalistAimTower.PrimaryPart then
			local tPos   = vitalistAimTower.PrimaryPart.Position
			local flatDir = Vector3.new(groundPos.X - tPos.X, 0, groundPos.Z - tPos.Z)
			if flatDir.Magnitude > 0.5 then
				strikeSkillRemote:FireServer(vitalistAimTower, "NanoBlast", flatDir.Unit)
			end
		end
		stopVitalistAiming()
		return
	end

	if strikeAiming then
		if strikeCanPlace then
			local groundPos = raycastGround()
			if groundPos and strikeTowerModel and strikeTowerModel.PrimaryPart then
				strikeSkillRemote:FireServer(strikeTowerModel, "Dynamite", groundPos)
			end
		end
		stopStrikeAiming()
		return
	end

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
	if vitalistAiming then stopVitalistAiming(); return end
	if strikeAiming   then stopStrikeAiming();   return end
	if placing        then stopPlacing();         return end
	if selectedTowerModel and selectedTowerModel.Parent then
		local state = selectedTowerModel:GetAttribute("State") or "Idle"
		if state == "Moving" or state == "Leaping" then return end
		local groundPos = raycastGround()
		if groundPos then
			moveRemote:FireServer(selectedTowerModel, groundPos + Vector3.new(0, 3.5, 0))
		end
	end
end)

loadoutUpdatedRemote.OnClientEvent:Connect(function(snapshot: table)
	syncLoadoutFromSnapshot(snapshot)
end)

local function updateHotbarForState(state: string)
	hotbarGui.Enabled = (state == "InRound")
end

gameStateChanged.OnClientEvent:Connect(function(newState: string)
	updateHotbarForState(newState)
end)

if gameStateValue then
	updateHotbarForState(gameStateValue.Value)
end

requestLoadoutSnapshot()
if selectedTower then
	updateHotbarSelectionVisuals()
end

print("[TowerPlacement] Ready!")
