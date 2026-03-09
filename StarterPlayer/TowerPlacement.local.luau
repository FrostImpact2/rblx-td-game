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
local selectedTower = "Deadeye"
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

local function createInfoGui(towerModel: Model)
	if infoGui then infoGui:Destroy() end

	local atk     = towerModel:GetAttribute("ATK") or 0
	local atkSpd  = towerModel:GetAttribute("ATK_SPD") or 0
	local rng     = towerModel:GetAttribute("RNG") or 0
	local hp      = towerModel:GetAttribute("HP") or 0
	local maxHp   = towerModel:GetAttribute("MaxHP") or 0
	local moveSpd = towerModel:GetAttribute("MOVE_SPD") or 0
	local state   = towerModel:GetAttribute("State") or "Idle"

	local gui = Instance.new("ScreenGui")
	gui.Name = "TowerInfoGUI"; gui.ResetOnSpawn = false; gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 250, 0, 400)
	panel.Position = UDim2.new(1, -270, 0.5, -200)
	panel.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0; panel.Parent = gui

	Instance.new("UIStroke", panel).Color = Color3.fromRGB(60, 60, 70)

	-- Helper: divider
	local function div(y)
		local d = Instance.new("Frame")
		d.Size = UDim2.new(1, -20, 0, 1)
		d.Position = UDim2.new(0, 10, 0, y)
		d.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
		d.BorderSizePixel = 0; d.Parent = panel
	end

	-- Helper: label
	local function lbl(text, pos, size, color, font, xAlign)
		local t = Instance.new("TextLabel")
		t.Size = size; t.Position = pos
		t.BackgroundTransparency = 1; t.Text = text
		t.TextColor3 = color; t.TextScaled = true
		t.TextWrapped = true
		t.TextXAlignment = xAlign or Enum.TextXAlignment.Left
		t.Font = font or Enum.Font.Gotham; t.Parent = panel
		return t
	end

	-- Tower name + State
	lbl(towerModel.Name, UDim2.new(0,10,0,6), UDim2.new(0.55,0,0,28),
		Color3.fromRGB(255,255,255), Enum.Font.GothamBold)

	local stateLabel = lbl(state, UDim2.new(0.55,0,0,9), UDim2.new(0.45,-10,0,22),
		Color3.fromRGB(100,200,255), Enum.Font.Gotham, Enum.TextXAlignment.Right)
	stateLabel.Name = "StateLabel"

	div(38)

	-- Stat pills
	local statDefs = {
		{ "ATK", tostring(atk).." ATK",                    Color3.fromRGB(220,60,60),  Color3.fromRGB(40,15,15) },
		{ "HP",  tostring(hp).."/"..tostring(maxHp).." HP", Color3.fromRGB(60,200,60),  Color3.fromRGB(15,40,15) },
		{ "RNG", tostring(rng).." RNG",                    Color3.fromRGB(60,140,220), Color3.fromRGB(15,25,40) },
	}
	for i, s in ipairs(statDefs) do
		local pill = Instance.new("Frame")
		pill.Name = s[1].."Pill"
		pill.Size = UDim2.new(0, 70, 0, 22)
		pill.Position = UDim2.new(0, 6 + (i-1)*76, 0, 48)
		pill.BackgroundColor3 = s[4]; pill.BorderSizePixel = 0; pill.Parent = panel
		Instance.new("UIStroke", pill).Color = s[3]
		local t = Instance.new("TextLabel")
		t.Name = "Value"; t.Size = UDim2.new(1,0,1,0)
		t.BackgroundTransparency = 1; t.Text = s[2]
		t.TextColor3 = s[3]; t.TextScaled = true
		t.Font = Enum.Font.GothamBold; t.Parent = pill
	end

	-- Secondary stats
	local secondaryDefs = {
		{ "ATK SPD",  string.format("%.1f/s", atkSpd), Color3.fromRGB(255,200,100) },
		{ "MOVE SPD", tostring(moveSpd),                Color3.fromRGB(200,160,255) },
	}
	for i, s in ipairs(secondaryDefs) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1,-20,0,18); row.Position = UDim2.new(0,10,0,76+(i-1)*20)
		row.BackgroundTransparency = 1; row.Parent = panel
		lbl(s[1], UDim2.new(0,0,0,0), UDim2.new(0.5,0,1,0),
			Color3.fromRGB(140,140,150), Enum.Font.Gotham).Parent = row
		local v = lbl(s[2], UDim2.new(0.5,0,0,0), UDim2.new(0.5,0,1,0),
			s[3], Enum.Font.Gotham, Enum.TextXAlignment.Right)
		v.Parent = row
	end

	div(120)

	-- === [Cleave] ===
	lbl("[Cleave] - Basic Attack", UDim2.new(0,10,0,126), UDim2.new(1,-20,0,16),
		Color3.fromRGB(255,220,100), Enum.Font.GothamBold)
	lbl("Slash at the enemy, dealing 100% ATK.", UDim2.new(0,10,0,143), UDim2.new(1,-20,0,20),
		Color3.fromRGB(180,180,190))

	div(168)

	-- === [Leaping Slash] with cooldown bar ===
	lbl("[Leaping Slash] - Special", UDim2.new(0,10,0,174), UDim2.new(1,-20,0,16),
		Color3.fromRGB(255,150,50), Enum.Font.GothamBold)
	lbl("80% ATK frontal cone AOE. Triggers on PLACE and on MOVE (within leap range).",
		UDim2.new(0,10,0,191), UDim2.new(1,-20,0,28),
		Color3.fromRGB(180,180,190))

	-- Cooldown bar
	local cdFrame = Instance.new("Frame")
	cdFrame.Name = "LeapCDFrame"
	cdFrame.Size = UDim2.new(1, -20, 0, 14)
	cdFrame.Position = UDim2.new(0, 10, 0, 222)
	cdFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	cdFrame.BorderSizePixel = 0; cdFrame.Parent = panel
	Instance.new("UIStroke", cdFrame).Color = Color3.fromRGB(80, 60, 20)

	local cdFill = Instance.new("Frame")
	cdFill.Name = "CDFill"
	cdFill.Size = UDim2.new(1, 0, 1, 0)
	cdFill.BackgroundColor3 = Color3.fromRGB(255, 160, 40)
	cdFill.BorderSizePixel = 0; cdFill.Parent = cdFrame

	local cdText = Instance.new("TextLabel")
	cdText.Name = "CDText"
	cdText.Size = UDim2.new(1, 0, 1, 0)
	cdText.BackgroundTransparency = 1
	cdText.Text = "READY"
	cdText.TextColor3 = Color3.fromRGB(255, 255, 255)
	cdText.TextScaled = true
	cdText.Font = Enum.Font.GothamBold
	cdText.TextStrokeTransparency = 0.5; cdText.Parent = cdFrame

	div(242)

	-- === Move hint ===
	local moveBtn = Instance.new("Frame")
	moveBtn.Size = UDim2.new(1,-20,0,28); moveBtn.Position = UDim2.new(0,10,0,250)
	moveBtn.BackgroundColor3 = Color3.fromRGB(50,90,160); moveBtn.BorderSizePixel = 0
	moveBtn.Parent = panel
	Instance.new("UIStroke", moveBtn).Color = Color3.fromRGB(80,130,200)
	local mt = Instance.new("TextLabel")
	mt.Size = UDim2.new(1,0,1,0); mt.BackgroundTransparency = 1
	mt.Text = "Right-click to MOVE"
	mt.TextColor3 = Color3.fromRGB(150,200,255); mt.TextScaled = true
	mt.Font = Enum.Font.GothamBold; mt.Parent = moveBtn

	-- === Relentless Advance ===
	lbl("[Relentless Advance] - Move Skill", UDim2.new(0,10,0,286), UDim2.new(1,-20,0,16),
		Color3.fromRGB(100,200,255), Enum.Font.GothamBold)
	lbl("If dest within leap range & off CD: leap + Leaping Slash.",
		UDim2.new(0,10,0,303), UDim2.new(1,-20,0,24),
		Color3.fromRGB(180,180,190))

	div(332)

	-- === Passive: Survivor ===
	lbl("Passive: SURVIVOR", UDim2.new(0,10,0,338), UDim2.new(1,-20,0,16),
		Color3.fromRGB(100,220,150), Enum.Font.GothamBold)
	lbl("Out of combat 3s → heal 2% max HP every 3s.",
		UDim2.new(0,10,0,355), UDim2.new(1,-20,0,24),
		Color3.fromRGB(150,150,160))

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
			-- State label
			local sl = panel:FindFirstChild("StateLabel")
			if sl then
				local state = selectedTowerModel:GetAttribute("State") or "Idle"
				sl.Text = state
				sl.TextColor3 = state == "Moving" and Color3.fromRGB(255,200,100)
					or state == "Attacking" and Color3.fromRGB(255,100,100)
					or state == "Leaping" and Color3.fromRGB(255,150,50)
					or Color3.fromRGB(100,200,255)
			end

			-- HP pill
			local hpPill = panel:FindFirstChild("HPPill")
			if hpPill then
				local v = hpPill:FindFirstChild("Value")
				if v then
					local hp = selectedTowerModel:GetAttribute("HP") or 0
					local mhp = selectedTowerModel:GetAttribute("MaxHP") or 0
					local newText = math.floor(hp).."/"..mhp.." HP"
					if v.Text ~= newText then v.Text = newText end
				end
			end

			-- Cooldown bar for Leaping Slash
			local cdFrame = panel:FindFirstChild("LeapCDFrame")
			if cdFrame then
				local cdFill = cdFrame:FindFirstChild("CDFill")
				local cdText = cdFrame:FindFirstChild("CDText")

				local cdEnd = selectedTowerModel:GetAttribute("LeapSlashCooldown") or 0
				local maxCD = selectedTowerModel:GetAttribute("LeapSlashMaxCD") or 5
				local now = tick()
				local remaining = cdEnd - now

				if remaining <= 0 then
					-- Ready
					if cdFill then
						cdFill.Size = UDim2.new(1, 0, 1, 0)
						cdFill.BackgroundColor3 = Color3.fromRGB(80, 200, 80)
					end
					if cdText then cdText.Text = "READY" end
				else
					-- On cooldown
					local ratio = math.clamp(1 - (remaining / maxCD), 0, 1)
					if cdFill then
						cdFill.Size = UDim2.new(ratio, 0, 1, 0)
						cdFill.BackgroundColor3 = Color3.fromRGB(255, 160, 40)
					end
					if cdText then
						cdText.Text = string.format("%.1fs", remaining)
					end
				end
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
	end
end)

mouse.Button1Down:Connect(function()
	if placing then
		if not canPlace then return end
		local groundPos = raycastGround()
		if groundPos then
			placeRemote:FireServer(selectedTower, groundPos + Vector3.new(0, 3.5, 0))
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