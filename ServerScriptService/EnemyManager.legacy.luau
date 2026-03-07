--[[
	EnemyManager (Server Script)
	
	Simple blocky enemy: head, torso, 2 arms, 2 legs.
	6 parts total. Procedural walk animation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")

local EnemyStats        = require(ReplicatedStorage:WaitForChild("EnemyStats", 10))
local PathfindingModule = require(ReplicatedStorage:WaitForChild("PathfindingModule", 10))

if not EnemyStats then
	error("[EnemyManager] Could not find EnemyStats in ReplicatedStorage!")
end
if not PathfindingModule then
	error("[EnemyManager] Could not find PathfindingModule in ReplicatedStorage!")
end

print("[EnemyManager] Modules loaded!")

local pathFolder    = Workspace:WaitForChild("Path", 10)
local enemiesFolder = Workspace:WaitForChild("Enemies", 10)
local spawnPart     = Workspace:WaitForChild("EnemySpawn", 10)
local basePart      = Workspace:WaitForChild("Base", 10)

if not pathFolder then error("[EnemyManager] Missing 'Path' folder in Workspace!") end
if not enemiesFolder then error("[EnemyManager] Missing 'Enemies' folder in Workspace!") end
if not spawnPart then error("[EnemyManager] Missing 'EnemySpawn' part in Workspace!") end
if not basePart then error("[EnemyManager] Missing 'Base' part in Workspace!") end

local waypoints = PathfindingModule.BuildWaypoints(pathFolder)
print("[EnemyManager] Found " .. #waypoints .. " waypoints.")

if #waypoints == 0 then
	error("[EnemyManager] No waypoints found!")
end

-- ============================================================
-- HELPER
-- ============================================================

local function makePart(name, size, color, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Anchored = false
	part.CanCollide = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function makeMotor(name, part0, part1, c0, c1)
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1 or CFrame.new()
	motor.Parent = part0
	return motor
end

-- ============================================================
-- CREATE ENEMY MODEL
-- 6 parts: Torso, Head, LeftArm, RightArm, LeftLeg, RightLeg
-- ============================================================

local function createEnemyModel(templateName: string): Model
	local template = EnemyStats.Templates[templateName]
	if not template then
		warn("[EnemyManager] Unknown template: " .. templateName)
		return nil
	end

	local model = Instance.new("Model")
	model.Name = templateName

	-- Torso (root)
	local torso = makePart("HumanoidRootPart", Vector3.new(2, 2.4, 1.2), Color3.fromRGB(150, 150, 150), model)
	model.PrimaryPart = torso

	-- Head
	local head = makePart("Head", Vector3.new(1.4, 1.4, 1.4), Color3.fromRGB(200, 200, 200), model)
	makeMotor("Neck", torso, head,
		CFrame.new(0, 1.2, 0),
		CFrame.new(0, -0.7, 0)
	)

	-- Left Arm
	local leftArm = makePart("LeftArm", Vector3.new(0.8, 2.4, 1), Color3.fromRGB(170, 170, 170), model)
	makeMotor("LeftShoulder", torso, leftArm,
		CFrame.new(-1.4, 0.8, 0),
		CFrame.new(0, 1.0, 0)
	)

	-- Right Arm
	local rightArm = makePart("RightArm", Vector3.new(0.8, 2.4, 1), Color3.fromRGB(170, 170, 170), model)
	makeMotor("RightShoulder", torso, rightArm,
		CFrame.new(1.4, 0.8, 0),
		CFrame.new(0, 1.0, 0)
	)

	-- Left Leg
	local leftLeg = makePart("LeftLeg", Vector3.new(0.9, 2.4, 1), Color3.fromRGB(140, 140, 140), model)
	makeMotor("LeftHip", torso, leftLeg,
		CFrame.new(-0.5, -1.2, 0),
		CFrame.new(0, 1.2, 0)
	)

	-- Right Leg
	local rightLeg = makePart("RightLeg", Vector3.new(0.9, 2.4, 1), Color3.fromRGB(140, 140, 140), model)
	makeMotor("RightHip", torso, rightLeg,
		CFrame.new(0.5, -1.2, 0),
		CFrame.new(0, 1.2, 0)
	)

	-- Stats
	model:SetAttribute("ATK", template.ATK)
	model:SetAttribute("ATK_SPD", template.ATK_SPD)
	model:SetAttribute("MOVE_SPD", template.MOVE_SPD)
	model:SetAttribute("HP", template.HP)
	model:SetAttribute("MaxHP", template.HP)
	model:SetAttribute("RNG", template.RNG)
	model:SetAttribute("TARGETING", template.TARGETING)

	local rangeStuds = EnemyStats.ResolveRng(template.RNG)
	model:SetAttribute("RangeStuds", rangeStuds)

	-- Range circle
	local circle = Instance.new("Part")
	circle.Name = "RangeCircle"
	circle.Shape = Enum.PartType.Cylinder
	circle.Size = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored = true
	circle.CanCollide = false
	circle.Color = Color3.fromRGB(30, 100, 200)
	circle.Material = Enum.Material.SmoothPlastic
	circle.Transparency = 1
	circle.Parent = model

	return model
end

-- ============================================================
-- WALK ANIMATION
-- ============================================================

local walkConnections = {}

-- Find the startWalkAnimation function and replace it with this version
-- that checks for the WalkStopped attribute:

local function startWalkAnimation(enemyModel: Model)
	local torso = enemyModel.PrimaryPart
	if not torso then return end

	local neck          = torso:FindFirstChild("Neck")
	local leftShoulder  = torso:FindFirstChild("LeftShoulder")
	local rightShoulder = torso:FindFirstChild("RightShoulder")
	local leftHip       = torso:FindFirstChild("LeftHip")
	local rightHip      = torso:FindFirstChild("RightHip")

	local nkC0 = neck and neck.C0
	local lsC0 = leftShoulder and leftShoulder.C0
	local rsC0 = rightShoulder and rightShoulder.C0
	local lhC0 = leftHip and leftHip.C0
	local rhC0 = rightHip and rightHip.C0

	local elapsed = math.random() * math.pi * 2
	local wasWalking = true

	local CYCLE_SPEED  = 5.5
	local LEG_STRIDE   = 0.6
	local STEP_HEIGHT  = 0.3
	local PUSH_TILT    = 0.5
	local ARM_SWING    = 0.4
	local ARM_BEND     = 0.2
	local BODY_BOB     = 0.15
	local HEAD_COUNTER = 0.05

	local connection = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then return end

		local stopped = enemyModel:GetAttribute("WalkStopped")
		if stopped then
			if wasWalking then
				wasWalking = false
				if leftHip and lhC0 then leftHip.C0 = lhC0 end
				if rightHip and rhC0 then rightHip.C0 = rhC0 end
				if leftShoulder and lsC0 then leftShoulder.C0 = lsC0 end
				if rightShoulder and rsC0 then rightShoulder.C0 = rsC0 end
				if neck and nkC0 then neck.C0 = nkC0 end
			end
			return
		end

		wasWalking = true
		elapsed = elapsed + dt * CYCLE_SPEED
		local sin = math.sin(elapsed)
		local cos = math.cos(elapsed)
		local abs_sin = math.abs(sin)

		local smoothSin = sin * abs_sin
		local torsoBob = math.abs(math.sin(elapsed * 2)) * BODY_BOB
		local torsoLean = math.sin(elapsed * 2) * 0.04
		local torsoSway = sin * 0.02
		local breathe = math.sin(elapsed * 0.6) * 0.008

		-- Left leg with smooth lift
		local leftY, leftZ, leftAngle
		if sin > 0 then
			local t = sin
			local st = t * t * (3 - 2 * t)
			leftY = st * STEP_HEIGHT
			leftZ = -sin * LEG_STRIDE
			leftAngle = -cos * 0.06
		else
			local pushProgress = -sin
			local sp = pushProgress * pushProgress * (3 - 2 * pushProgress)
			local endLift = (1 - sp) * sp * STEP_HEIGHT
			leftY = endLift
			leftZ = -sin * LEG_STRIDE
			leftAngle = sin * PUSH_TILT
		end

		-- Right leg with smooth lift
		local rightY, rightZ, rightAngle
		if sin < 0 then
			local t = -sin
			local st = t * t * (3 - 2 * t)
			rightY = st * STEP_HEIGHT
			rightZ = sin * LEG_STRIDE
			rightAngle = cos * 0.06
		else
			local pushProgress = sin
			local sp = pushProgress * pushProgress * (3 - 2 * pushProgress)
			local endLift = (1 - sp) * sp * STEP_HEIGHT
			rightY = endLift
			rightZ = sin * LEG_STRIDE
			rightAngle = -sin * PUSH_TILT
		end

		if leftHip and lhC0 then
			leftHip.C0 = lhC0
				* CFrame.new(0, -torsoBob + leftY, leftZ)
				* CFrame.Angles(leftAngle, 0, 0)
		end
		if rightHip and rhC0 then
			rightHip.C0 = rhC0
				* CFrame.new(0, -torsoBob + rightY, rightZ)
				* CFrame.Angles(rightAngle, 0, 0)
		end

		local leftArmSwing  = -sin * ARM_SWING
		local rightArmSwing = sin * ARM_SWING
		local armBendAmount = abs_sin * ARM_BEND

		if leftShoulder and lsC0 then
			leftShoulder.C0 = lsC0
				* CFrame.Angles(leftArmSwing + torsoLean + breathe, 0, armBendAmount + torsoSway)
		end
		if rightShoulder and rsC0 then
			rightShoulder.C0 = rsC0
				* CFrame.Angles(rightArmSwing + torsoLean + breathe, 0, -armBendAmount + torsoSway)
		end

		if neck and nkC0 then
			neck.C0 = nkC0
				* CFrame.new(0, torsoBob, 0)
				* CFrame.Angles(-sin * HEAD_COUNTER - torsoLean, sin * 0.015, -torsoSway)
		end
	end)

	walkConnections[enemyModel] = connection
end

local function stopWalkAnimation(enemyModel: Model)
	local conn = walkConnections[enemyModel]
	if conn then
		conn:Disconnect()
		walkConnections[enemyModel] = nil
	end
end

-- ============================================================
-- SPAWN ENEMY
-- ============================================================

local activeEnemies = {}

local function spawnEnemy(templateName: string)
	local model = createEnemyModel(templateName)
	if not model then return end

	local torso = model.PrimaryPart
	local spawnPos = spawnPart.Position + Vector3.new(0, 4, 0)

	torso.Anchored = true
	model:PivotTo(CFrame.new(spawnPos))
	model.Parent = enemiesFolder

	local circle = model:FindFirstChild("RangeCircle")
	torso:GetPropertyChangedSignal("CFrame"):Connect(function()
		if circle and circle.Parent then
			local pos = torso.Position
			circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end)

	startWalkAnimation(model)

	local moveTier = model:GetAttribute("MOVE_SPD")
	local moveSpeed = EnemyStats.ResolveMoveSpd(moveTier)

	print("[EnemyManager] Spawned " .. templateName .. " | Speed: " .. moveSpeed)

	local stopFunc = PathfindingModule.StartMoving(
		model,
		waypoints,
		moveSpeed,
		function()
			stopWalkAnimation(model)
			local baseHP = basePart:GetAttribute("HP") or 100
			local atk = model:GetAttribute("ATK") or 1
			basePart:SetAttribute("HP", baseHP - atk)
			print("[EnemyManager] Enemy reached base! Base HP: " .. basePart:GetAttribute("HP"))
			model:Destroy()
		end
	)

	table.insert(activeEnemies, { Model = model, Stop = stopFunc })
end

local function spawnWave(templateName: string, count: number, delayBetween: number)
	task.spawn(function()
		for i = 1, count do
			print("[EnemyManager] Spawning enemy " .. i .. "/" .. count)
			spawnEnemy(templateName)
			if i < count then
				task.wait(delayBetween)
			end
		end
	end)
end

print("[EnemyManager] Starting in 3 seconds...")
task.wait(3)
print("[EnemyManager] SPAWNING WAVE!")
spawnWave("BasicZombie", 5, 2)