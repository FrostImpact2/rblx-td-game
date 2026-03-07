--[[
	EnemyViewingClient (LocalScript)
	
	Place this in StarterPlayer → StarterPlayerScripts
	
	HP bar shows at ALL times (scales with distance).
	HOVER over an enemy  → reveals name, damage, and range circle
	CLICK on an enemy    → pins the display until clicked again or enemy dies
	Only 1 pinned enemy at a time.
	
	HP bar is anchored via an Attachment at the bounding box
	center-top so it stays centered from every camera angle.
]]

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local mouse  = player:GetMouse()
local camera = Workspace.CurrentCamera

local enemiesFolder = Workspace:WaitForChild("Enemies", 15)

-- === STATE ===
local hoveredEnemy: Model?  = nil
local pinnedEnemy: Model?   = nil
local hoverGuis = {}
local hpGuis = {}
local activeTweens = {}
local barAttachments = {} -- model → Attachment

-- === CONFIG ===
local EXPAND_TIME = 0.15
local SHRINK_TIME = 0.1
local TWEEN_STYLE = Enum.EasingStyle.Quad
local HP_BAR_GAP  = 1.5

-- ============================================================
-- HELPER: create/update a centered attachment above the model
-- ============================================================

local function getCenterAttachment(enemyModel: Model): Attachment
	if barAttachments[enemyModel] then
		return barAttachments[enemyModel]
	end

	local root = enemyModel.PrimaryPart
	if not root then return nil end

	local attachment = Instance.new("Attachment")
	attachment.Name = "BarAnchor"
	attachment.Parent = root

	barAttachments[enemyModel] = attachment
	return attachment
end

local function updateAttachmentPosition(enemyModel: Model)
	local attachment = barAttachments[enemyModel]
	if not attachment then return end

	local root = enemyModel.PrimaryPart
	if not root then return end

	local cframe, size = enemyModel:GetBoundingBox()
	local centerTopWorld = cframe.Position + Vector3.new(0, size.Y / 2 + HP_BAR_GAP, 0)

	-- Convert world position to local offset relative to root
	local localOffset = root.CFrame:PointToObjectSpace(centerTopWorld)
	attachment.Position = localOffset
end

-- ============================================================
-- HP BAR CREATION (always visible, scales with distance)
-- ============================================================

local function createHPBar(enemyModel: Model): BillboardGui
	local root = enemyModel.PrimaryPart
	if not root then return nil end

	local hp    = enemyModel:GetAttribute("HP") or 0
	local maxHp = enemyModel:GetAttribute("MaxHP") or 1

	local attachment = getCenterAttachment(enemyModel)
	if not attachment then return nil end
	updateAttachmentPosition(enemyModel)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EnemyHPBar"
	billboard.Adornee = attachment
	billboard.Size = UDim2.new(4, 0, 0.4, 0)
	billboard.StudsOffset = Vector3.new(0, 0, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = enemyModel

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = billboard

	local outline = Instance.new("Frame")
	outline.Name = "Outline"
	outline.Size = UDim2.new(1, 0, 1, 0)
	outline.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	outline.BorderSizePixel = 0
	outline.Parent = container

	local hpBg = Instance.new("Frame")
	hpBg.Name = "HPBarBg"
	hpBg.Size = UDim2.new(1, -2, 1, -2)
	hpBg.Position = UDim2.new(0, 1, 0, 1)
	hpBg.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	hpBg.BorderSizePixel = 0
	hpBg.Parent = outline

	local hpFill = Instance.new("Frame")
	hpFill.Name = "HPBarFill"
	local ratio = math.clamp(hp / maxHp, 0, 1)
	hpFill.Size = UDim2.new(ratio, 0, 1, 0)
	hpFill.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBg

	local hpText = Instance.new("TextLabel")
	hpText.Name = "HPText"
	hpText.Size = UDim2.new(1, 0, 1, 0)
	hpText.BackgroundTransparency = 1
	hpText.Text = tostring(hp) .. "/" .. tostring(maxHp)
	hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
	hpText.TextScaled = true
	hpText.TextXAlignment = Enum.TextXAlignment.Center
	hpText.Font = Enum.Font.SourceSans
	hpText.TextStrokeTransparency = 0.5
	hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	hpText.Parent = hpBg

	return billboard
end

-- ============================================================
-- HOVER GUI CREATION (name above, damage below)
-- ============================================================

local function createHoverGui(enemyModel: Model): BillboardGui
	local root = enemyModel.PrimaryPart
	if not root then return nil end

	local atk = enemyModel:GetAttribute("ATK") or 0

	local attachment = getCenterAttachment(enemyModel)
	if not attachment then return nil end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EnemyHoverInfo"
	billboard.Adornee = attachment
	billboard.Size = UDim2.new(5, 0, 1.5, 0)
	billboard.StudsOffset = Vector3.new(0, 0, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = enemyModel

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = billboard

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Size = UDim2.new(1, 0, 0.45, 0)
	nameLabel.Position = UDim2.new(0, 0, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = enemyModel.Name
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextScaled = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.Font = Enum.Font.SourceSans
	nameLabel.TextStrokeTransparency = 0.5
	nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	nameLabel.Parent = container

	local atkLabel = Instance.new("TextLabel")
	atkLabel.Name = "AtkLabel"
	atkLabel.Size = UDim2.new(1, 0, 0.45, 0)
	atkLabel.Position = UDim2.new(0, 0, 0.55, 0)
	atkLabel.BackgroundTransparency = 1
	atkLabel.Text = tostring(atk) .. " DMG"
	atkLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
	atkLabel.TextScaled = true
	atkLabel.TextXAlignment = Enum.TextXAlignment.Center
	atkLabel.Font = Enum.Font.SourceSans
	atkLabel.TextStrokeTransparency = 0.5
	atkLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	atkLabel.Parent = container

	return billboard
end

-- ============================================================
-- RANGE CIRCLE TWEEN HELPERS
-- ============================================================

local function cancelTween(enemyModel: Model)
	local tween = activeTweens[enemyModel]
	if tween then
		if type(tween) == "table" then
			for _, t in ipairs(tween) do t:Cancel() end
		else
			tween:Cancel()
		end
		activeTweens[enemyModel] = nil
	end
end

local function expandCircle(enemyModel: Model)
	local circle = enemyModel:FindFirstChild("RangeCircle")
	if not circle then return end

	cancelTween(enemyModel)

	if not circle:GetAttribute("FullSize") then
		circle:SetAttribute("FullSize", circle.Size)
	end

	local fullSize = circle:GetAttribute("FullSize")
	local smallSize = Vector3.new(fullSize.X, 0.1, 0.1)

	circle.Size = smallSize
	circle.Transparency = 0.6

	local tweenInfo = TweenInfo.new(EXPAND_TIME, TWEEN_STYLE, Enum.EasingDirection.Out)
	local tween = TweenService:Create(circle, tweenInfo, { Size = fullSize })
	activeTweens[enemyModel] = tween
	tween:Play()
end

local function shrinkCircle(enemyModel: Model)
	local circle = enemyModel:FindFirstChild("RangeCircle")
	if not circle then return end

	cancelTween(enemyModel)

	local fullSize = circle:GetAttribute("FullSize") or circle.Size
	local smallSize = Vector3.new(fullSize.X, 0.1, 0.1)

	local tweenInfo = TweenInfo.new(SHRINK_TIME, TWEEN_STYLE, Enum.EasingDirection.In)
	local tween = TweenService:Create(circle, tweenInfo, { Size = smallSize })
	activeTweens[enemyModel] = tween

	tween.Completed:Connect(function()
		if activeTweens[enemyModel] == tween then
			circle.Transparency = 1
			activeTweens[enemyModel] = nil
		end
	end)

	tween:Play()
end

-- ============================================================
-- SHOW / HIDE
-- ============================================================

local function showHoverDisplay(enemyModel: Model)
	if not enemyModel or not enemyModel.Parent then return end
	if hoverGuis[enemyModel] then return end

	local gui = createHoverGui(enemyModel)
	if gui then
		hoverGuis[enemyModel] = gui
	end

	expandCircle(enemyModel)
end

local function hideHoverDisplay(enemyModel: Model)
	if not enemyModel then return end

	local gui = hoverGuis[enemyModel]
	if gui and gui.Parent then
		gui:Destroy()
	end
	hoverGuis[enemyModel] = nil

	shrinkCircle(enemyModel)
end

-- ============================================================
-- AUTO-ATTACH HP BARS
-- ============================================================

local function attachHPBar(enemyModel: Model)
	if hpGuis[enemyModel] then return end
	if not enemyModel.PrimaryPart then
		task.wait(0.1)
		if not enemyModel.PrimaryPart then return end
	end
	local gui = createHPBar(enemyModel)
	if gui then
		hpGuis[enemyModel] = gui
	end
end

for _, child in ipairs(enemiesFolder:GetChildren()) do
	if child:IsA("Model") then
		attachHPBar(child)
	end
end

enemiesFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		attachHPBar(child)
	end
end)

-- ============================================================
-- GET ENEMY MODEL FROM PART
-- ============================================================

local function getEnemyFromPart(part: Instance): Model?
	if not part then return nil end

	local current = part
	while current and current ~= Workspace do
		if current.Parent == enemiesFolder then
			return current :: Model
		end
		current = current.Parent
	end
	return nil
end

-- ============================================================
-- HOVER + HP UPDATE
-- ============================================================

RunService.RenderStepped:Connect(function()
	local target = mouse.Target
	local enemyModel = getEnemyFromPart(target)

	if enemyModel ~= hoveredEnemy then
		if hoveredEnemy and hoveredEnemy ~= pinnedEnemy then
			hideHoverDisplay(hoveredEnemy)
		end

		hoveredEnemy = enemyModel

		if hoveredEnemy and hoveredEnemy ~= pinnedEnemy then
			showHoverDisplay(hoveredEnemy)
		end
	end

	-- Update HP bars + attachment positions every frame
	for model, gui in pairs(hpGuis) do
		if model and model.Parent then
			-- Keep attachment centered
			updateAttachmentPosition(model)

			local hp    = model:GetAttribute("HP") or 0
			local maxHp = model:GetAttribute("MaxHP") or 1
			local ratio = math.clamp(hp / maxHp, 0, 1)

			local container = gui:FindFirstChild("Container")
			if not container then continue end

			local outline = container:FindFirstChild("Outline")
			if not outline then continue end

			local hpBg = outline:FindFirstChild("HPBarBg")
			if hpBg then
				local fill = hpBg:FindFirstChild("HPBarFill")
				if fill then
					fill.Size = UDim2.new(ratio, 0, 1, 0)
				end

				local hpText = hpBg:FindFirstChild("HPText")
				if hpText then
					hpText.Text = tostring(hp) .. "/" .. tostring(maxHp)
				end
			end
		else
			if gui and gui.Parent then
				gui:Destroy()
			end
			hpGuis[model] = nil
		end
	end
end)

-- ============================================================
-- CLICK DETECTION
-- ============================================================

mouse.Button1Down:Connect(function()
	local target = mouse.Target
	local enemyModel = getEnemyFromPart(target)

	if enemyModel then
		if pinnedEnemy == enemyModel then
			pinnedEnemy = nil
			if hoveredEnemy ~= enemyModel then
				hideHoverDisplay(enemyModel)
			end
		else
			if pinnedEnemy then
				local oldPinned = pinnedEnemy
				pinnedEnemy = nil
				if hoveredEnemy ~= oldPinned then
					hideHoverDisplay(oldPinned)
				end
			end

			pinnedEnemy = enemyModel
			showHoverDisplay(enemyModel)
		end
	end
end)

-- ============================================================
-- CLEANUP
-- ============================================================

enemiesFolder.ChildRemoved:Connect(function(child)
	cancelTween(child)

	if hoverGuis[child] then
		if hoverGuis[child].Parent then
			hoverGuis[child]:Destroy()
		end
		hoverGuis[child] = nil
	end

	if hpGuis[child] then
		if hpGuis[child].Parent then
			hpGuis[child]:Destroy()
		end
		hpGuis[child] = nil
	end

	if barAttachments[child] then
		if barAttachments[child].Parent then
			barAttachments[child]:Destroy()
		end
		barAttachments[child] = nil
	end

	if pinnedEnemy == child then
		pinnedEnemy = nil
	end
	if hoveredEnemy == child then
		hoveredEnemy = nil
	end
end)