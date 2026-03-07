--[[
	TowerManager (Server Script)
	Full Warrior kit: Cleave, Leaping Slash, Relentless Advance, Survivor
	With cooldowns, VFX, burst healing
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local TowerStats = require(ReplicatedStorage:WaitForChild("TowerStats", 10))
local EnemyStats = nil
pcall(function() EnemyStats = require(ReplicatedStorage:WaitForChild("EnemyStats", 5)) end)

if not TowerStats then error("[TowerManager] Could not find TowerStats!") end

local towersFolder = Workspace:FindFirstChild("Towers")
if not towersFolder then
	towersFolder = Instance.new("Folder"); towersFolder.Name = "Towers"; towersFolder.Parent = Workspace
end

local enemiesFolder = Workspace:WaitForChild("Enemies", 15)

local placeRemote = Instance.new("RemoteEvent"); placeRemote.Name = "PlaceTower"; placeRemote.Parent = ReplicatedStorage
local moveRemote  = Instance.new("RemoteEvent"); moveRemote.Name = "MoveTower"; moveRemote.Parent = ReplicatedStorage

-- ============================================================
-- CONFIG
-- ============================================================

local LEAP_SLASH_COOLDOWN   = 5      -- seconds
local LEAP_SLASH_DAMAGE     = 0.8    -- 80% ATK
local LEAP_SLASH_CONE_ANGLE = math.rad(60)
local LEAP_SLASH_CONE_RANGE_MULT = 1.5
local LEAP_RANGE_MULT       = 3     -- within 10x RNG to trigger leap
local LEAP_DURATION          = 1
local LEAP_HEIGHT            = 4

local SURVIVOR_OOC_TIME     = 3      -- seconds out of combat before healing
local SURVIVOR_HEAL_INTERVAL = 3     -- heal every 3 seconds
local SURVIVOR_HEAL_PERCENT = 0.02   -- 2% max HP per tick

-- ============================================================
-- HELPERS
-- ============================================================

local function makePart(name, size, color, parent)
	local p = Instance.new("Part")
	p.Name = name; p.Size = size; p.Color = color
	p.Anchored = false; p.CanCollide = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function makeMotor(name, part0, part1, c0, c1)
	local m = Instance.new("Motor6D")
	m.Name = name; m.Part0 = part0; m.Part1 = part1
	m.C0 = c0; m.C1 = c1 or CFrame.new()
	m.Parent = part0
	return m
end

-- ============================================================
-- PARTICLE HELPERS
-- ============================================================

local function spawnHitParticles(position: Vector3, color: Color3)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.2, 0.4)
	emitter.Speed = NumberRange.new(4, 8)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = attachment

	-- Temporary anchor part
	local anchor = Instance.new("Part")
	anchor.Name = "ParticleAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Position = position
	anchor.Parent = Workspace
	attachment.Parent = anchor

	emitter:Emit(8)

	task.delay(0.5, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

local function spawnSlashParticles(position: Vector3, direction: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name = "SlashVFXAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1; anchor.Anchored = true; anchor.CanCollide = false
	anchor.CFrame = CFrame.new(position, position + direction)
	anchor.Parent = Workspace

	-- Main directional slash particles
	local att1 = Instance.new("Attachment"); att1.Parent = anchor
	local slash = Instance.new("ParticleEmitter")
	slash.Color = ColorSequence.new(Color3.fromRGB(255, 220, 60), Color3.fromRGB(255, 100, 20))
	slash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.0),
		NumberSequenceKeypoint.new(0.3, 1.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	slash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.0),
		NumberSequenceKeypoint.new(0.4, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	slash.Lifetime = NumberRange.new(0.15, 0.35)
	slash.Speed = NumberRange.new(12, 22)
	slash.SpreadAngle = Vector2.new(35, 8)
	slash.Rate = 0
	slash.Acceleration = Vector3.new(0, -10, 0)
	slash.RotSpeed = NumberRange.new(-200, 200)
	slash.Rotation = NumberRange.new(0, 360)
	slash.Parent = att1
	slash:Emit(20)

	-- Spark particles (smaller, faster, wider spread)
	local att2 = Instance.new("Attachment"); att2.Parent = anchor
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 255, 200))
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.Lifetime = NumberRange.new(0.1, 0.25)
	sparks.Speed = NumberRange.new(15, 30)
	sparks.SpreadAngle = Vector2.new(50, 20)
	sparks.Rate = 0
	sparks.Acceleration = Vector3.new(0, -20, 0)
	sparks.Parent = att2
	sparks:Emit(12)

	-- Ground impact ring (expanding)
	local ring = Instance.new("Part")
	ring.Name = "ImpactRing"; ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.1, 0.1, 0.1)
	ring.Color = Color3.fromRGB(255, 180, 50)
	ring.Material = Enum.Material.Neon; ring.Transparency = 0.2
	ring.Anchored = true; ring.CanCollide = false
	ring.CFrame = CFrame.new(position.X, position.Y - 2, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace

	-- Shockwave ring
	local wave = Instance.new("Part")
	wave.Name = "ImpactRing"; wave.Shape = Enum.PartType.Cylinder
	wave.Size = Vector3.new(0.05, 0.1, 0.1)
	wave.Color = Color3.fromRGB(255, 240, 180)
	wave.Material = Enum.Material.Neon; wave.Transparency = 0.4
	wave.Anchored = true; wave.CanCollide = false
	wave.CFrame = CFrame.new(position.X, position.Y - 1.8, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	wave.Parent = Workspace

	task.spawn(function()
		local elapsed = 0
		local expandTime = 0.3
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			local a = math.clamp(elapsed / expandTime, 0, 1)
			local smooth = a * a * (3 - 2 * a)

			local sz1 = 10 * smooth
			ring.Size = Vector3.new(0.1, sz1, sz1)
			ring.Transparency = 0.2 + 0.8 * smooth

			local sz2 = 6 * smooth
			wave.Size = Vector3.new(0.05, sz2, sz2)
			wave.Transparency = 0.4 + 0.6 * smooth

			if a >= 1 then
				conn:Disconnect()
				ring:Destroy()
				wave:Destroy()
			end
		end)
	end)

	task.delay(0.6, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

local function spawnHealParticles(towerModel: Model)
	local torso = towerModel.PrimaryPart
	if not torso then return end

	local anchor = Instance.new("Part")
	anchor.Name = "HealVFXAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Position = torso.Position
	anchor.Parent = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(80, 255, 80))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.5, 0.8)
	emitter.Speed = NumberRange.new(2, 5)
	emitter.SpreadAngle = Vector2.new(360, 30)
	emitter.Rate = 0
	emitter.Acceleration = Vector3.new(0, 6, 0) -- float upward
	emitter.Parent = att

	emitter:Emit(12)

	task.delay(1, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

local function spawnLeapTrailParticles(towerModel: Model): () -> ()
	local torso = towerModel.PrimaryPart
	if not torso then return function() end end

	-- Main trail
	local att1 = Instance.new("Attachment"); att1.Name = "LeapTrailAtt"; att1.Parent = torso

	local trail = Instance.new("ParticleEmitter")
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 140)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 180, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 100, 20)),
	})
	trail.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),
		NumberSequenceKeypoint.new(0.3, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.5, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = NumberRange.new(0.2, 0.4)
	trail.Speed = NumberRange.new(0, 2)
	trail.Rate = 80
	trail.Acceleration = Vector3.new(0, -8, 0)
	trail.RotSpeed = NumberRange.new(-100, 100)
	trail.Parent = att1

	-- Wind streaks (from feet)
	local att2 = Instance.new("Attachment"); att2.Name = "LeapWindAtt"
	att2.Position = Vector3.new(0, -1.5, 0)
	att2.Parent = torso

	local wind = Instance.new("ParticleEmitter")
	wind.Color = ColorSequence.new(Color3.fromRGB(200, 220, 255))
	wind.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.5, 0.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	wind.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	wind.Lifetime = NumberRange.new(0.1, 0.2)
	wind.Speed = NumberRange.new(2, 6)
	wind.SpreadAngle = Vector2.new(180, 180)
	wind.Rate = 40
	wind.Parent = att2

	return function()
		trail.Rate = 0
		wind.Rate = 0
		task.delay(0.5, function()
			if att1 and att1.Parent then att1:Destroy() end
			if att2 and att2.Parent then att2:Destroy() end
		end)
	end
end

-- ============================================================
-- CREATE TOWER MODEL
-- ============================================================

local function createTowerModel(templateName: string, position: Vector3): Model
	local template = TowerStats.Templates[templateName]
	if not template then return nil end

	local model = Instance.new("Model"); model.Name = templateName
	local torso = makePart("HumanoidRootPart", Vector3.new(2, 2.4, 1.2), Color3.fromRGB(60, 90, 150), model)
	torso.Anchored = true; model.PrimaryPart = torso

	local head = makePart("Head", Vector3.new(1.4, 1.4, 1.4), Color3.fromRGB(90, 120, 180), model)
	makeMotor("Neck", torso, head, CFrame.new(0, 1.2, 0), CFrame.new(0, -0.7, 0))

	local lArm = makePart("LeftArm", Vector3.new(0.8, 2.4, 1), Color3.fromRGB(70, 100, 160), model)
	makeMotor("LeftShoulder", torso, lArm, CFrame.new(-1.4, 0.8, 0), CFrame.new(0, 1.0, 0))

	local rArm = makePart("RightArm", Vector3.new(0.8, 2.4, 1), Color3.fromRGB(70, 100, 160), model)
	makeMotor("RightShoulder", torso, rArm, CFrame.new(1.4, 0.8, 0), CFrame.new(0, 1.0, 0))

	-- Sword
	local handle = makePart("Handle", Vector3.new(0.18, 0.7, 0.18), Color3.fromRGB(60, 45, 30), model)
	makeMotor("HandleGrip", rArm, handle,
		CFrame.new(0, -1.2, 0) * CFrame.Angles(math.rad(-20), 0, 0),
		CFrame.new(0, 0.3, 0))

	local guard = makePart("Guard", Vector3.new(0.55, 0.1, 0.2), Color3.fromRGB(180, 160, 50), model)
	makeMotor("GuardJoint", handle, guard, CFrame.new(0, -0.35, 0), CFrame.new())

	local blade = makePart("Blade", Vector3.new(0.08, 2.4, 0.3), Color3.fromRGB(200, 200, 215), model)
	makeMotor("BladeJoint", guard, blade, CFrame.new(0, -0.06, 0), CFrame.new(0, 1.2, 0))

	local edgePart = makePart("BladeEdge", Vector3.new(0.02, 2.2, 0.08), Color3.fromRGB(240, 240, 255), model)
	edgePart.Material = Enum.Material.Neon
	makeMotor("EdgeJoint", blade, edgePart, CFrame.new(0, 0, -0.12), CFrame.new())

	local lLeg = makePart("LeftLeg", Vector3.new(0.9, 2.4, 1), Color3.fromRGB(50, 70, 120), model)
	makeMotor("LeftHip", torso, lLeg, CFrame.new(-0.5, -1.2, 0), CFrame.new(0, 1.2, 0))

	local rLeg = makePart("RightLeg", Vector3.new(0.9, 2.4, 1), Color3.fromRGB(50, 70, 120), model)
	makeMotor("RightHip", torso, rLeg, CFrame.new(0.5, -1.2, 0), CFrame.new(0, 1.2, 0))

	-- Range circle
	local rangeStuds = template.RNG
	local circle = Instance.new("Part")
	circle.Name = "RangeCircle"; circle.Shape = Enum.PartType.Cylinder
	circle.Size = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored = true; circle.CanCollide = false
	circle.Color = Color3.fromRGB(30, 100, 200); circle.Transparency = 1
	circle.Material = Enum.Material.SmoothPlastic; circle.Parent = model

	-- Leap range indicator (larger circle, different color, hidden by default)
	local leapRange = rangeStuds * LEAP_RANGE_MULT
	local leapCircle = Instance.new("Part")
	leapCircle.Name = "LeapRangeCircle"; leapCircle.Shape = Enum.PartType.Cylinder
	leapCircle.Size = Vector3.new(0.1, leapRange * 2, leapRange * 2)
	leapCircle.Anchored = true; leapCircle.CanCollide = false
	circle.Color = Color3.fromRGB(30, 100, 200); leapCircle.Transparency = 1.2
	leapCircle.Material = Enum.Material.Neon; leapCircle.Parent = model
	
	

	-- Attributes
	model:SetAttribute("ATK", template.ATK)
	model:SetAttribute("ATK_SPD", template.ATK_SPD)
	model:SetAttribute("RNG", rangeStuds)
	model:SetAttribute("HP", template.HP)
	model:SetAttribute("MaxHP", template.HP)
	model:SetAttribute("MOVE_SPD", template.MOVE_SPD)
	model:SetAttribute("DamageMulti", template.DamageMulti)
	model:SetAttribute("AttackType", template.AttackType)
	model:SetAttribute("State", "Idle")
	model:SetAttribute("Owner", "")
	model:SetAttribute("LastCombatTime", tick())
	model:SetAttribute("LastHealTick", tick())
	model:SetAttribute("LeapSlashCooldown", 0)       -- timestamp when cooldown ends
	model:SetAttribute("LeapSlashMaxCD", LEAP_SLASH_COOLDOWN)

	model:PivotTo(CFrame.new(position))
	model.Parent = towersFolder
	circle.CFrame = CFrame.new(position.X, position.Y - 2.5, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	leapCircle.CFrame = CFrame.new(position.X, position.Y - 2.6, position.Z) * CFrame.Angles(0, 0, math.rad(90))

	return model
end

-- ============================================================
-- TARGETING
-- ============================================================

local aggroMap = {}
local enemyAggroBy = {}

local function findTarget(tower: Model): Model?
	local torso = tower.PrimaryPart; if not torso then return nil end
	local range = tower:GetAttribute("RNG") or 8
	local pos = torso.Position

	local aggroed = aggroMap[tower]
	if aggroed and aggroed.Parent and aggroed.PrimaryPart then
		if (aggroed:GetAttribute("HP") or 0) > 0 then
			if (aggroed.PrimaryPart.Position - pos).Magnitude <= range then return aggroed end
		end
	end

	local best, bestDist = nil, math.huge
	for _, e in ipairs(enemiesFolder:GetChildren()) do
		if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
			local d = (e.PrimaryPart.Position - pos).Magnitude
			if d <= range and d < bestDist then bestDist = d; best = e end
		end
	end
	return best
end

local function findNearestEnemy(pos: Vector3, range: number): Model?
	local best, bestDist = nil, math.huge
	for _, e in ipairs(enemiesFolder:GetChildren()) do
		if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
			local d = (e.PrimaryPart.Position - pos).Magnitude
			if d <= range and d < bestDist then bestDist = d; best = e end
		end
	end
	return best
end

-- ============================================================
-- LEAPING SLASH (cone AOE, 80% ATK, with cooldown)
-- ============================================================

local function isLeapSlashReady(tower: Model): boolean
	local cdEnd = tower:GetAttribute("LeapSlashCooldown") or 0
	return tick() >= cdEnd
end

local function startLeapSlashCooldown(tower: Model)
	tower:SetAttribute("LeapSlashCooldown", tick() + LEAP_SLASH_COOLDOWN)
end

local function createConeIndicator(position: Vector3, direction: Vector3, coneRange: number, coneAngle: number)
	local anchor = Instance.new("Folder")
	anchor.Name = "ConeFlash"

	local groundY = position.Y - 2
	local segments = 16
	local segAngle = (coneAngle * 2) / segments
	local yaw = math.atan2(direction.X, direction.Z)

	-- Filled triangle segments
	for i = 0, segments - 1 do
		local a1 = -coneAngle + segAngle * i
		local a2 = -coneAngle + segAngle * (i + 1)

		local dir1 = Vector3.new(math.sin(yaw + a1), 0, math.cos(yaw + a1))
		local dir2 = Vector3.new(math.sin(yaw + a2), 0, math.cos(yaw + a2))

		local p1 = Vector3.new(position.X, groundY, position.Z) + dir1 * coneRange
		local p2 = Vector3.new(position.X, groundY, position.Z) + dir2 * coneRange
		local center = Vector3.new(position.X, groundY, position.Z)

		local mid = (center + p1 + p2) / 3
		local span = math.max((p1 - p2).Magnitude, 0.1)
		local depth = coneRange

		local seg = Instance.new("Part")
		seg.Size = Vector3.new(span, 0.08, depth)
		seg.Color = Color3.fromRGB(255, 200, 60)
		seg.Material = Enum.Material.Neon
		seg.Transparency = 0.3
		seg.Anchored = true; seg.CanCollide = false
		seg.CFrame = CFrame.new(mid, mid + Vector3.new(direction.X, 0, direction.Z))
		seg.Parent = anchor
	end

	anchor.Parent = Workspace

	task.spawn(function()
		task.wait(0.1)
		local fadeTime = 0.35
		local elapsed = 0
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			local a = math.clamp(elapsed / fadeTime, 0, 1)
			local smooth = a * a * (3 - 2 * a)
			for _, part in ipairs(anchor:GetChildren()) do
				if part:IsA("Part") then
					part.Transparency = 0.3 + 0.7 * smooth
				end
			end
			if a >= 1 then conn:Disconnect(); anchor:Destroy() end
		end)
	end)
end

local function performLeapingSlash(tower: Model, targetPos: Vector3)
	local torso = tower.PrimaryPart; if not torso then return end

	local atk = tower:GetAttribute("ATK") or 10
	local multi = tower:GetAttribute("DamageMulti") or 1.0
	local damage = atk * LEAP_SLASH_DAMAGE * multi
	local range = tower:GetAttribute("RNG") or 8

	local slashPos = torso.Position
	local dir = Vector3.new(targetPos.X - slashPos.X, 0, targetPos.Z - slashPos.Z)
	if dir.Magnitude > 0.1 then
		dir = dir.Unit
		torso.CFrame = CFrame.new(slashPos, slashPos + dir)
	else
		dir = torso.CFrame.LookVector
	end

	local CONE_RANGE = range * LEAP_SLASH_CONE_RANGE_MULT

	-- Show cone indicator
	createConeIndicator(slashPos, dir, CONE_RANGE, LEAP_SLASH_CONE_ANGLE)

	-- Slash particles
	spawnSlashParticles(slashPos, dir)

	for _, enemy in ipairs(enemiesFolder:GetChildren()) do
		if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
			local toEnemy = enemy.PrimaryPart.Position - slashPos
			toEnemy = Vector3.new(toEnemy.X, 0, toEnemy.Z)
			local dist = toEnemy.Magnitude

			if dist <= CONE_RANGE and dist > 0.1 then
				local angle = math.acos(math.clamp(dir:Dot(toEnemy.Unit), -1, 1))
				if angle <= LEAP_SLASH_CONE_ANGLE then
					local hp = enemy:GetAttribute("HP") or 0
					enemy:SetAttribute("HP", hp - damage)
					spawnHitParticles(enemy.PrimaryPart.Position, Color3.fromRGB(255, 150, 50))
					if (hp - damage) <= 0 then enemy:Destroy() end
				end
			end
		end
	end

	tower:SetAttribute("LastCombatTime", tick())
	startLeapSlashCooldown(tower)
end

local function playLeapAnimation(tower: Model, dest: Vector3, onComplete: () -> ())
	local torso = tower.PrimaryPart
	if not torso then if onComplete then onComplete() end return end

	local startPos = torso.Position
	local dir = Vector3.new(dest.X - startPos.X, 0, dest.Z - startPos.Z)
	if dir.Magnitude > 0.1 then dir = dir.Unit else dir = torso.CFrame.LookVector end

	local rs = torso:FindFirstChild("RightShoulder")
	local ls = torso:FindFirstChild("LeftShoulder")
	local lh = torso:FindFirstChild("LeftHip")
	local rh = torso:FindFirstChild("RightHip")
	local nk = torso:FindFirstChild("Neck")

	local rsBase = rs and rs.C0
	local lsBase = ls and ls.C0
	local lhBase = lh and lh.C0
	local rhBase = rh and rh.C0
	local nkBase = nk and nk.C0

	-- Phase 1: WINDUP (tower crouches and raises sword)
	local WINDUP_TIME = 0.4
	local windupElapsed = 0

	-- Face target during windup
	torso.CFrame = CFrame.new(startPos, startPos + dir)

	local stopTrail
	local circle = tower:FindFirstChild("RangeCircle")
	local leapCircle = tower:FindFirstChild("LeapRangeCircle")

	local function updateCircles(pos)
		if circle and circle.Parent then
			circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
		if leapCircle and leapCircle.Parent then
			leapCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end

	-- Windup phase
	local windupConn
	windupConn = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then
			windupConn:Disconnect()
			if onComplete then onComplete() end
			return
		end

		windupElapsed = windupElapsed + dt
		local t = math.clamp(windupElapsed / WINDUP_TIME, 0, 1)
		local smooth = t * t * (3 - 2 * t)

		-- Crouch + raise sword
		if rs and rsBase then rs.C0 = rsBase * CFrame.Angles(-2.8 * smooth, 0, 0.3 * smooth) end
		if ls and lsBase then ls.C0 = lsBase * CFrame.Angles(-0.3 * smooth, 0, -0.15 * smooth) end
		if lh and lhBase then lh.C0 = lhBase * CFrame.Angles(0.3 * smooth, 0, 0) * CFrame.new(0, -0.15 * smooth, 0) end
		if rh and rhBase then rh.C0 = rhBase * CFrame.Angles(0.3 * smooth, 0, 0) * CFrame.new(0, -0.15 * smooth, 0) end
		if nk and nkBase then nk.C0 = nkBase * CFrame.Angles(0.15 * smooth, 0, 0) end

		if t >= 1 then
			windupConn:Disconnect()

			-- Phase 2: AIRBORNE
			stopTrail = spawnLeapTrailParticles(tower)

			-- Recapture start pos (in case tower was still walking)
			local launchPos = torso.Position
			local FLIGHT_TIME = LEAP_DURATION - WINDUP_TIME - 0.12 -- reserve time for slowdown
			local SLOWDOWN_START = 0.75 -- start slowing at 75% of flight
			local flightElapsed = 0

			local flightConn
			flightConn = RunService.Heartbeat:Connect(function(dt2)
				if not torso or not torso.Parent then
					flightConn:Disconnect()
					if stopTrail then stopTrail() end
					if onComplete then onComplete() end
					return
				end

				flightElapsed = flightElapsed + dt2
				local rawAlpha = math.clamp(flightElapsed / FLIGHT_TIME, 0, 1)

				-- Slowdown curve: fast start, decelerate near end
				local alpha
				if rawAlpha < SLOWDOWN_START then
					-- Normal speed portion
					local normalT = rawAlpha / SLOWDOWN_START
					alpha = normalT * SLOWDOWN_START
				else
					-- Slowdown portion: ease out
					local slowT = (rawAlpha - SLOWDOWN_START) / (1 - SLOWDOWN_START)
					local easedSlow = 1 - (1 - slowT) * (1 - slowT) -- ease out quad
					alpha = SLOWDOWN_START + easedSlow * (1 - SLOWDOWN_START)
				end

				local smooth2 = alpha * alpha * (3 - 2 * alpha)

				-- Parabolic arc
				local flatPos = launchPos:Lerp(dest, smooth2)
				local heightOffset = LEAP_HEIGHT * 4 * alpha * (1 - alpha)
				local newPos = Vector3.new(flatPos.X, launchPos.Y + heightOffset, flatPos.Z)

				torso.CFrame = CFrame.new(newPos, newPos + dir)
				updateCircles(newPos)

				-- Body pose during flight
				if alpha < 0.5 then
					-- Rising
					local rise = alpha * 2
					local rs2 = rise * rise * (3 - 2 * rise)
					if lh and lhBase then lh.C0 = lhBase * CFrame.Angles(0.3 + 0.3 * rs2, 0, 0) * CFrame.new(0, -0.15, 0) end
					if rh and rhBase then rh.C0 = rhBase * CFrame.Angles(0.3 + 0.3 * rs2, 0, 0) * CFrame.new(0, -0.15, 0) end
				else
					-- Falling: sword comes down
					local fall = (alpha - 0.5) * 2
					local fs = fall * fall * (3 - 2 * fall)
					local swordAngle = -2.8 + (2.8 + 0.8) * fs
					local legTuck = 0.6 * (1 - fs)
					if rs and rsBase then rs.C0 = rsBase * CFrame.Angles(swordAngle, -0.5 * fs, 0.3 - 0.7 * fs) end
					if ls and lsBase then ls.C0 = lsBase * CFrame.Angles(-0.3 + 0.1 * fs, 0, -0.15 + 0.35 * fs) end
					if lh and lhBase then lh.C0 = lhBase * CFrame.Angles(legTuck, 0, 0) end
					if rh and rhBase then rh.C0 = rhBase * CFrame.Angles(legTuck, 0, 0) end
					if nk and nkBase then nk.C0 = nkBase * CFrame.Angles(0.15 - 0.3 * fs, 0, 0) end
				end

				if rawAlpha >= 1 then
					flightConn:Disconnect()
					if stopTrail then stopTrail() end

					-- Reset legs
					if lh and lh.Parent and lhBase then lh.C0 = lhBase end
					if rh and rh.Parent and rhBase then rh.C0 = rhBase end

					-- Find slash target
					local nearestEnemy = findNearestEnemy(torso.Position, tower:GetAttribute("RNG") or 8)
					local slashTarget
					if nearestEnemy and nearestEnemy.PrimaryPart then
						slashTarget = nearestEnemy.PrimaryPart.Position
					else
						slashTarget = torso.Position + dir * 5
					end

					performLeapingSlash(tower, slashTarget)

					-- Smooth recovery
					task.spawn(function()
						local recFrames = 8
						local recTime = 0.25
						local recDt = recTime / recFrames
						local rsStart = rs and rs.C0
						local lsStart = ls and ls.C0
						local nkStart = nk and nk.C0
						for f = 1, recFrames do
							local rt = f / recFrames
							rt = rt * rt * (3 - 2 * rt)
							if rs and rs.Parent and rsBase then rs.C0 = rsStart:Lerp(rsBase, rt) end
							if ls and ls.Parent and lsBase then ls.C0 = lsStart:Lerp(lsBase, rt) end
							if nk and nk.Parent and nkBase then nk.C0 = nkStart:Lerp(nkBase, rt) end
							task.wait(recDt)
						end
					end)

					if onComplete then onComplete() end
				end
			end)
		end
	end)
end
-- ============================================================
-- TOWER ATTACK ANIMATION (Cleave) + hit particles
-- ============================================================

local attackAnimData = {}

local function playAttackAnimation(tower: Model, target: Model)
	local torso = tower.PrimaryPart; if not torso then return end
	local rs = torso:FindFirstChild("RightShoulder")
	local ls = torso:FindFirstChild("LeftShoulder")
	local nk = torso:FindFirstChild("Neck")
	if not rs then return end

	if not attackAnimData[tower] then
		attackAnimData[tower] = {
			rsC0 = rs.C0, lsC0 = ls and ls.C0, nkC0 = nk and nk.C0, animating = false
		}
	end
	local d = attackAnimData[tower]
	if d.animating then return end
	d.animating = true

	local tp = target.PrimaryPart and target.PrimaryPart.Position
	if tp then
		local dir = Vector3.new(tp.X - torso.Position.X, 0, tp.Z - torso.Position.Z)
		if dir.Magnitude > 0.1 then torso.CFrame = CFrame.new(torso.Position, torso.Position + dir.Unit) end
	end

	task.spawn(function()
		local STEPS = 6
		local totalTime = 0.35
		local stepTime = totalTime / STEPS

		-- Keyframes: {alpha, rsAngles, lsAngles, nkAngles}
		local keyframes = {
			{ CFrame.Angles(-2.2, 0.5, 0.4),   CFrame.Angles(0.4, 0.1, -0.3),   CFrame.Angles(0.1, -0.15, 0) },   -- wind up
			{ CFrame.Angles(-1.0, 0.2, 0.1),   CFrame.Angles(0.1, 0.05, -0.1),  CFrame.Angles(0.05, -0.05, 0) },  -- mid wind
			{ CFrame.Angles(0.4, -0.5, -0.6),  CFrame.Angles(-0.3, -0.1, 0.2),  CFrame.Angles(-0.1, 0.1, 0) },    -- swing contact
			{ CFrame.Angles(0.8, -0.7, -0.8),  CFrame.Angles(-0.4, -0.15, 0.3), CFrame.Angles(-0.15, 0.12, 0) },  -- follow through
			{ CFrame.Angles(-0.2, 0.1, 0.1),   CFrame.Angles(-0.05, 0, 0.05),   CFrame.Angles(0, 0, 0) },         -- recovery
			{ CFrame.Angles(0, 0, 0),           CFrame.Angles(0, 0, 0),           CFrame.Angles(0, 0, 0) },         -- idle
		}

		for i = 1, STEPS do
			if not rs or not rs.Parent then d.animating = false return end

			local kf = keyframes[i]
			local frames = 4
			local frameDt = stepTime / frames

			-- Get current offsets
			local rsCur = rs.C0 * d.rsC0:Inverse()
			local lsCur = (ls and ls.Parent) and (ls.C0 * d.lsC0:Inverse()) or CFrame.new()
			local nkCur = (nk and nk.Parent) and (nk.C0 * d.nkC0:Inverse()) or CFrame.new()

			for f = 1, frames do
				if not rs or not rs.Parent then d.animating = false return end
				local alpha = f / frames
				-- Smooth step interpolation
				local t = alpha * alpha * (3 - 2 * alpha)

				rs.C0 = d.rsC0 * rsCur:Lerp(kf[1], t)
				if ls and ls.Parent and d.lsC0 then
					ls.C0 = d.lsC0 * lsCur:Lerp(kf[2], t)
				end
				if nk and nk.Parent and d.nkC0 then
					nk.C0 = d.nkC0 * nkCur:Lerp(kf[3], t)
				end

				task.wait(frameDt)
			end
		end

		if rs and rs.Parent then rs.C0 = d.rsC0 end
		if ls and ls.Parent then ls.C0 = d.lsC0 end
		if nk and nk.Parent then nk.C0 = d.nkC0 end
		d.animating = false
	end)
end

-- ============================================================
-- ENEMY PUNCH ANIMATION
-- ============================================================

local function playEnemyPunchAnimation(enemy: Model, tower: Model)
	local torso = enemy.PrimaryPart; if not torso then return end
	local ls = torso:FindFirstChild("LeftShoulder")
	local rs = torso:FindFirstChild("RightShoulder")
	local nk = torso:FindFirstChild("Neck")

	if not enemyAttackAnimData[enemy] then
		enemyAttackAnimData[enemy] = {
			lsC0 = ls and ls.C0, rsC0 = rs and rs.C0, nkC0 = nk and nk.C0,
			animating = false, lastHand = "right"
		}
	end
	local d = enemyAttackAnimData[enemy]
	if d.animating then return end
	d.animating = true

	local punchLeft = d.lastHand == "right"
	d.lastHand = punchLeft and "left" or "right"

	local tp = tower.PrimaryPart and tower.PrimaryPart.Position
	if tp then
		local dir = Vector3.new(tp.X - torso.Position.X, 0, tp.Z - torso.Position.Z)
		if dir.Magnitude > 0.1 then torso.CFrame = CFrame.new(torso.Position, torso.Position + dir.Unit) end
	end

	local pS = punchLeft and ls or rs
	local pB = punchLeft and d.lsC0 or d.rsC0
	local oS = punchLeft and rs or ls
	local oB = punchLeft and d.rsC0 or d.lsC0
	local hD = punchLeft and 1 or -1

	if not pS or not pB then d.animating = false return end

	-- Smooth interpolation helper
	local function tweenMotor(motor, base, targetOffset, duration, steps)
		if not motor or not motor.Parent or not base then return end
		steps = steps or 4
		local startOffset = motor.C0 * base:Inverse()
		for f = 1, steps do
			if not motor or not motor.Parent then return end
			local t = f / steps
			t = t * t * (3 - 2 * t) -- smoothstep
			motor.C0 = base * startOffset:Lerp(targetOffset, t)
			task.wait(duration / steps)
		end
	end

	task.spawn(function()
		-- Wind up (both arms + head)
		local windTarget = CFrame.Angles(-1.8, hD * 0.3, hD * 0.2)
		local offTarget  = CFrame.Angles(-0.5, 0, -hD * 0.3)
		local nkTarget   = CFrame.Angles(0.1, hD * 0.1, 0)

		-- Parallel tween all joints for wind-up
		local t1 = task.spawn(function() tweenMotor(pS, pB, windTarget, 0.1, 5) end)
		local t2 = task.spawn(function() tweenMotor(oS, oB, offTarget, 0.1, 5) end)
		if nk and nk.Parent and d.nkC0 then
			task.spawn(function() tweenMotor(nk, d.nkC0, nkTarget, 0.1, 5) end)
		end
		task.wait(0.1)

		-- Punch forward (fast)
		if not pS or not pS.Parent then d.animating = false return end
		local punchTarget = CFrame.Angles(-1.5, -hD * 0.15, -hD * 0.15)
		tweenMotor(pS, pB, punchTarget, 0.06, 3)

		-- Hold briefly
		task.wait(0.06)

		-- Retract smoothly
		if not pS or not pS.Parent then d.animating = false return end
		tweenMotor(pS, pB, CFrame.Angles(-0.3, 0, 0), 0.08, 4)
		if oS and oS.Parent and oB then tweenMotor(oS, oB, CFrame.new(), 0.06, 3) end
		if nk and nk.Parent and d.nkC0 then tweenMotor(nk, d.nkC0, CFrame.new(), 0.06, 3) end

		-- Return to idle
		task.wait(0.04)
		if pS and pS.Parent and pB then tweenMotor(pS, pB, CFrame.new(), 0.08, 4) end

		d.animating = false
	end)
end

-- ============================================================
-- TOWER WALK ANIMATION
-- ============================================================

local towerWalkConnections = {}
local towerBaseC0s = {}

local function storeBaseC0s(m: Model)
	if towerBaseC0s[m] then return end
	local torso = m.PrimaryPart; if not torso then return end
	local stored = {}
	for _, n in ipairs({"Neck", "LeftShoulder", "RightShoulder", "LeftHip", "RightHip"}) do
		local motor = torso:FindFirstChild(n)
		if motor then stored[n] = motor.C0 end
	end
	towerBaseC0s[m] = stored
end

local function restoreBaseC0s(m: Model)
	local stored = towerBaseC0s[m]; if not stored then return end
	local torso = m.PrimaryPart; if not torso then return end
	for n, c0 in pairs(stored) do
		local motor = torso:FindFirstChild(n)
		if motor then motor.C0 = c0 end
	end
end

local function startTowerWalk(m: Model)
	if towerWalkConnections[m] then return end
	local torso = m.PrimaryPart; if not torso then return end
	storeBaseC0s(m)
	local s = towerBaseC0s[m]
	local lsC0, rsC0 = s["LeftShoulder"], s["RightShoulder"]
	local lhC0, rhC0 = s["LeftHip"], s["RightHip"]
	local nkC0 = s["Neck"]
	local lS = torso:FindFirstChild("LeftShoulder")
	local rS = torso:FindFirstChild("RightShoulder")
	local lH = torso:FindFirstChild("LeftHip")
	local rH = torso:FindFirstChild("RightHip")
	local nk = torso:FindFirstChild("Neck")
	local elapsed = 0

	towerWalkConnections[m] = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then return end
		elapsed = elapsed + dt * 5.5
		local sin = math.sin(elapsed)
		local cos = math.cos(elapsed)
		local abs_sin = math.abs(sin)

		-- Smooth step curves for more natural motion
		local smoothSin = sin * abs_sin  -- soft at extremes
		local bob = math.abs(math.sin(elapsed * 2)) * 0.15
		local lean = math.sin(elapsed * 2) * 0.04
		local sway = sin * 0.02
		local breathe = math.sin(elapsed * 0.7) * 0.01 -- subtle idle breathe

		-- Legs with smooth lift curves
		local lY, lZ, lA
		if sin > 0 then
			local t = sin
			local smoothT = t * t * (3 - 2 * t)
			lY = smoothT * 0.3
			lZ = -sin * 0.6
			lA = -cos * 0.08  -- slight forward tilt during lift
		else
			local p = -sin
			local smoothP = p * p * (3 - 2 * p)
			lY = (1 - smoothP) * smoothP * 0.3
			lZ = -sin * 0.6
			lA = sin * 0.5
		end

		local rY, rZ, rA
		if sin < 0 then
			local t = -sin
			local smoothT = t * t * (3 - 2 * t)
			rY = smoothT * 0.3
			rZ = sin * 0.6
			rA = cos * 0.08
		else
			local p = sin
			local smoothP = p * p * (3 - 2 * p)
			rY = (1 - smoothP) * smoothP * 0.3
			rZ = sin * 0.6
			rA = -sin * 0.5
		end

		if lH and lhC0 then lH.C0 = lhC0 * CFrame.new(0, -bob + lY, lZ) * CFrame.Angles(lA, 0, 0) end
		if rH and rhC0 then rH.C0 = rhC0 * CFrame.new(0, -bob + rY, rZ) * CFrame.Angles(rA, 0, 0) end

		-- Arms with elbow bend
		local lArmSwing = -sin * 0.4
		local rArmSwing = sin * 0.4
		local elbowBend = abs_sin * 0.2

		if lS and lsC0 then
			lS.C0 = lsC0 * CFrame.Angles(lArmSwing + lean + breathe, 0, elbowBend + sway)
		end
		if rS and rsC0 then
			rS.C0 = rsC0 * CFrame.Angles(rArmSwing + lean + breathe, 0, -elbowBend + sway)
		end

		-- Head counter-bob with subtle look
		if nk and nkC0 then
			nk.C0 = nkC0 * CFrame.new(0, bob, 0) * CFrame.Angles(-sin * 0.05 - lean, sin * 0.015, -sway)
		end
	end)
end

local function stopTowerWalk(m: Model)
	local c = towerWalkConnections[m]
	if c then c:Disconnect(); towerWalkConnections[m] = nil end
	restoreBaseC0s(m)
end

-- ============================================================
-- AGGRO
-- ============================================================

local enemyWalkBaseC0s = {}

local function storeEnemyBaseC0s(e: Model)
	if enemyWalkBaseC0s[e] then return end
	local torso = e.PrimaryPart; if not torso then return end
	local stored = {}
	for _, n in ipairs({"Neck", "LeftShoulder", "RightShoulder", "LeftHip", "RightHip"}) do
		local motor = torso:FindFirstChild(n)
		if motor then stored[n] = motor.C0 end
	end
	enemyWalkBaseC0s[e] = stored
end

local function restoreEnemyBaseC0s(e: Model)
	local stored = enemyWalkBaseC0s[e]; if not stored then return end
	local torso = e.PrimaryPart; if not torso then return end
	for n, c0 in pairs(stored) do
		local motor = torso:FindFirstChild(n)
		if motor then motor.C0 = c0 end
	end
end

local function releaseAggro(tower: Model)
	local enemy = aggroMap[tower]; if not enemy then return end
	aggroMap[tower] = nil; enemyAggroBy[enemy] = nil
	if enemy and enemy.Parent then
		enemy:SetAttribute("Aggroed", false)
		enemy:SetAttribute("AggroTarget", "")
		enemy:SetAttribute("WalkStopped", false)
		restoreEnemyBaseC0s(enemy)
	end
end

local function setAggro(tower: Model, enemy: Model)
	releaseAggro(tower)
	if enemyAggroBy[enemy] then return end
	aggroMap[tower] = enemy; enemyAggroBy[enemy] = tower
	storeEnemyBaseC0s(enemy)
	enemy:SetAttribute("Aggroed", true)
	enemy:SetAttribute("AggroTarget", tower:GetFullName())
	enemy:SetAttribute("WalkStopped", true)
end

local function isEnemyInAggroRange(enemy: Model, tower: Model): boolean
	local er, tr = enemy.PrimaryPart, tower.PrimaryPart
	if not er or not tr then return false end
	local eRange = enemy:GetAttribute("RangeStuds") or enemy:GetAttribute("RNG") or 5
	return (tr.Position - er.Position).Magnitude <= eRange
end

local function isTowerInAttackRange(tower: Model, enemy: Model): boolean
	local torso = tower.PrimaryPart
	if not torso or not enemy.PrimaryPart then return false end
	return (enemy.PrimaryPart.Position - torso.Position).Magnitude <= (tower:GetAttribute("RNG") or 8)
end

local enemyAttackTimers = {}

local function enemyAttackTower(enemy: Model, tower: Model)
	local now = tick()
	local last = enemyAttackTimers[enemy] or 0
	local atkSpdRaw = enemy:GetAttribute("ATK_SPD") or 1
	local cooldown = type(atkSpdRaw) == "number" and 1 / math.max(atkSpdRaw, 0.1) or 1
	if now - last < cooldown then return end
	enemyAttackTimers[enemy] = now

	playEnemyPunchAnimation(enemy, tower)
	task.delay(0.14, function()
		if not enemy or not enemy.Parent or not tower or not tower.Parent then return end
		local atk = enemy:GetAttribute("ATK") or 1
		local hp = tower:GetAttribute("HP") or 0
		local newHP = hp - atk
		tower:SetAttribute("HP", newHP)
		tower:SetAttribute("LastCombatTime", tick())

		if tower.PrimaryPart then
			spawnHitParticles(tower.PrimaryPart.Position, Color3.fromRGB(255, 60, 60))
		end

		if newHP <= 0 then tower:Destroy() end
	end)
end

enemiesFolder.ChildRemoved:Connect(function(enemy)
	local tower = enemyAggroBy[enemy]
	if tower then aggroMap[tower] = nil; enemyAggroBy[enemy] = nil end
	enemyAttackTimers[enemy] = nil
	enemyAttackAnimData[enemy] = nil
	enemyWalkBaseC0s[enemy] = nil
end)

-- ============================================================
-- MOVEMENT + RELENTLESS ADVANCE
-- ============================================================

local activeMovements = {}
local moveIndicators = {}

local function createMoveIndicator(dest: Vector3): Part
	local ind = Instance.new("Part")
	ind.Name = "MoveIndicator"; ind.Shape = Enum.PartType.Cylinder
	ind.Size = Vector3.new(0.1, 3, 3); ind.Color = Color3.fromRGB(80, 180, 255)
	ind.Material = Enum.Material.Neon; ind.Transparency = 0.4
	ind.Anchored = true; ind.CanCollide = false
	ind.CFrame = CFrame.new(dest.X, dest.Y - 3.3, dest.Z) * CFrame.Angles(0, 0, math.rad(90))
	ind.Parent = Workspace
	return ind
end

local function destroyMoveIndicator(tower: Model)
	local ind = moveIndicators[tower]
	if ind and ind.Parent then ind:Destroy() end
	moveIndicators[tower] = nil
end

local function updateCirclePositions(tower: Model, pos: Vector3)
	local circle = tower:FindFirstChild("RangeCircle")
	if circle and circle.Parent then
		circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
	local leapCircle = tower:FindFirstChild("LeapRangeCircle")
	if leapCircle and leapCircle.Parent then
		leapCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
end
local function moveTower(tower: Model, dest: Vector3)
	local torso = tower.PrimaryPart; if not torso then return end

	-- Cancel any existing movement
	if activeMovements[tower] then
		activeMovements[tower]:Disconnect()
		activeMovements[tower] = nil
	end
	destroyMoveIndicator(tower)
	releaseAggro(tower)

	local startPos = torso.Position
	local flatDist = (Vector3.new(dest.X, 0, dest.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude
	local range = tower:GetAttribute("RNG") or 8

	-- RELENTLESS ADVANCE: if within leap range AND off cooldown, leap
	if flatDist <= range * LEAP_RANGE_MULT and isLeapSlashReady(tower) then
		-- Stop walk animation if currently walking
		stopTowerWalk(tower)
		tower:SetAttribute("State", "Leaping")

		playLeapAnimation(tower, dest, function()
			tower:SetAttribute("State", "Idle")
			if torso and torso.Parent then
				updateCirclePositions(tower, torso.Position)
			end
		end)
		return
	end

	-- Normal walk
	tower:SetAttribute("State", "Moving")
	startTowerWalk(tower)
	moveIndicators[tower] = createMoveIndicator(dest)

	local speed = tower:GetAttribute("MOVE_SPD") or 16

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then
			conn:Disconnect()
			activeMovements[tower] = nil
			destroyMoveIndicator(tower)
			return
		end

		local cur = torso.Position
		local flat = Vector3.new(dest.X - cur.X, 0, dest.Z - cur.Z)
		local dist = flat.Magnitude

		if dist < 0.5 then
			conn:Disconnect()
			activeMovements[tower] = nil
			tower:SetAttribute("State", "Idle")
			stopTowerWalk(tower)
			destroyMoveIndicator(tower)
			updateCirclePositions(tower, cur)
			return
		end

		local dir = flat.Unit
		local step = dir * speed * dt
		if step.Magnitude > dist then step = dir * dist end
		local newPos = cur + step

		local tCF = CFrame.new(newPos, newPos + dir)
		local curRot = torso.CFrame - torso.CFrame.Position
		local tRot = tCF - tCF.Position
		torso.CFrame = curRot:Lerp(tRot, math.clamp(dt * 8, 0, 1)) + newPos

		updateCirclePositions(tower, newPos)
	end)

	activeMovements[tower] = conn
end

-- ============================================================
-- TOWER AI + SURVIVOR PASSIVE (burst heal)
-- ============================================================

local activeTowers = {}

local function registerTower(towerModel: Model)
	storeBaseC0s(towerModel)
	activeTowers[towerModel] = { lastAttackTime = 0 }
end

RunService.Heartbeat:Connect(function(dt)
	local now = tick()

	for tower, data in pairs(activeTowers) do
		if not tower or not tower.Parent then
			activeTowers[tower] = nil
			releaseAggro(tower)
			continue
		end

		local state = tower:GetAttribute("State") or "Idle"

		-- === SURVIVOR PASSIVE (burst heal) ===
		local lastCombat = tower:GetAttribute("LastCombatTime") or now
		local hp = tower:GetAttribute("HP") or 0
		local maxHp = tower:GetAttribute("MaxHP") or 1
		local lastHealTick = tower:GetAttribute("LastHealTick") or 0

		if hp > 0 and hp < maxHp and (now - lastCombat) >= SURVIVOR_OOC_TIME then
			if (now - lastHealTick) >= SURVIVOR_HEAL_INTERVAL then
				local healAmount = math.ceil(maxHp * SURVIVOR_HEAL_PERCENT)
				local newHp = math.min(hp + healAmount, maxHp)
				tower:SetAttribute("HP", newHp)
				tower:SetAttribute("LastHealTick", now)
				spawnHealParticles(tower)
			end
		end

		if state == "Moving" or state == "Leaping" then continue end

		-- Validate current aggro
		local curAggro = aggroMap[tower]
		if curAggro then
			if not curAggro.Parent or (curAggro:GetAttribute("HP") or 0) <= 0 then
				releaseAggro(tower); curAggro = nil
			elseif not isTowerInAttackRange(tower, curAggro) then
				releaseAggro(tower); curAggro = nil
			end
		end

		-- Find target
		local target = findTarget(tower)
		if not target then
			tower:SetAttribute("State", "Idle")
			continue
		end

		-- Try to aggro: check if the TOWER is within the ENEMY's attack range
		-- This means the enemy can reach the tower to punch it
		if not curAggro then
			local torso = tower.PrimaryPart
			local enemyTorso = target.PrimaryPart
			if torso and enemyTorso then
				local dist = (torso.Position - enemyTorso.Position).Magnitude
				local enemyRange = target:GetAttribute("RangeStuds") or target:GetAttribute("RNG") or 5
				-- Aggro if the tower is close enough for the enemy to attack
				if dist <= enemyRange then
					setAggro(tower, target)
				end
			end
		end

		-- Attack cooldown
		local atkSpd = tower:GetAttribute("ATK_SPD") or 1
		local cooldown = 1 / atkSpd
		if now - data.lastAttackTime < cooldown then continue end

		tower:SetAttribute("State", "Attacking")
		tower:SetAttribute("LastCombatTime", now)
		data.lastAttackTime = now

		local atk = tower:GetAttribute("ATK") or 10
		local multi = tower:GetAttribute("DamageMulti") or 1.0
		local damage = atk * multi

		local enemyHP = target:GetAttribute("HP") or 0
		target:SetAttribute("HP", enemyHP - damage)
		playAttackAnimation(tower, target)

		if target.PrimaryPart then
			spawnHitParticles(target.PrimaryPart.Position, Color3.fromRGB(255, 80, 80))
		end

		if (enemyHP - damage) <= 0 then target:Destroy() end
	end

	-- === AGGROED ENEMIES ATTACK TOWERS ===
	-- Also check ALL enemies near towers for aggro (in case they walked into range)
	for tower, data in pairs(activeTowers) do
		if not tower or not tower.Parent then continue end
		local towerState = tower:GetAttribute("State") or "Idle"
		if towerState == "Moving" or towerState == "Leaping" then continue end

		local torso = tower.PrimaryPart
		if not torso then continue end

		-- If this tower doesn't have an aggro target, scan for nearby enemies
		if not aggroMap[tower] then
			for _, enemy in ipairs(enemiesFolder:GetChildren()) do
				if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
					if not enemyAggroBy[enemy] then -- not already aggroed by another tower
						local dist = (torso.Position - enemy.PrimaryPart.Position).Magnitude
						local enemyRange = enemy:GetAttribute("RangeStuds") or enemy:GetAttribute("RNG") or 5
						local towerRange = tower:GetAttribute("RNG") or 8
						-- Enemy must be in tower's attack range AND tower must be in enemy's attack range
						if dist <= towerRange and dist <= enemyRange then
							setAggro(tower, enemy)
							break
						end
					end
				end
			end
		end
	end

	-- Aggroed enemies perform their attacks
	for enemy, tower in pairs(enemyAggroBy) do
		if not enemy or not enemy.Parent then continue end
		if not tower or not tower.Parent then
			-- Tower died, release
			enemyAggroBy[enemy] = nil
			if enemy and enemy.Parent then
				enemy:SetAttribute("Aggroed", false)
				enemy:SetAttribute("AggroTarget", "")
				enemy:SetAttribute("WalkStopped", false)
			end
			continue
		end
		if (enemy:GetAttribute("HP") or 0) <= 0 then continue end

		-- Check if enemy is still in range to attack
		local enemyTorso = enemy.PrimaryPart
		local towerTorso = tower.PrimaryPart
		if enemyTorso and towerTorso then
			local dist = (towerTorso.Position - enemyTorso.Position).Magnitude
			local enemyRange = enemy:GetAttribute("RangeStuds") or enemy:GetAttribute("RNG") or 5

			if dist <= enemyRange then
				-- Face the tower
				local dir = Vector3.new(
					towerTorso.Position.X - enemyTorso.Position.X,
					0,
					towerTorso.Position.Z - enemyTorso.Position.Z
				)
				if dir.Magnitude > 0.1 then
					enemyTorso.CFrame = CFrame.new(enemyTorso.Position, enemyTorso.Position + dir.Unit)
				end

				enemyAttackTower(enemy, tower)
			else
				-- Out of range, release aggro
				releaseAggro(tower)
			end
		end
	end
end)
-- ============================================================
-- ON PLACEMENT: Leaping Slash toward nearest enemy
-- ============================================================

local function onTowerPlaced(tower: Model)
	local torso = tower.PrimaryPart; if not torso then return end
	local range = tower:GetAttribute("RNG") or 8
	local nearestEnemy = findNearestEnemy(torso.Position, range)

	if nearestEnemy and nearestEnemy.PrimaryPart then
		performLeapingSlash(tower, nearestEnemy.PrimaryPart.Position)
	end
end

-- ============================================================
-- REMOTES
-- ============================================================

placeRemote.OnServerEvent:Connect(function(player, templateName, position)
	if typeof(position) ~= "Vector3" then return end
	if type(templateName) ~= "string" then return end
	if not TowerStats.Templates[templateName] then return end

	local towerModel = createTowerModel(templateName, position)
	if towerModel then
		towerModel:SetAttribute("Owner", player.Name)
		registerTower(towerModel)
		onTowerPlaced(towerModel)
	end
end)

moveRemote.OnServerEvent:Connect(function(player, tower, dest)
	if typeof(dest) ~= "Vector3" then return end
	if not tower or not tower:IsA("Model") then return end
	if tower.Parent ~= towersFolder then return end
	if (tower:GetAttribute("Owner") or "") ~= player.Name then return end

	local state = tower:GetAttribute("State") or "Idle"
	-- Allow move command while Moving (to redirect or leap mid-walk)
	-- Block only during Leaping (already in a leap)
	if state == "Leaping" then return end

	moveTower(tower, dest)
end)

towersFolder.ChildRemoved:Connect(function(child)
	activeTowers[child] = nil
	attackAnimData[child] = nil
	towerBaseC0s[child] = nil
	releaseAggro(child)
	if activeMovements[child] then
		activeMovements[child]:Disconnect()
		activeMovements[child] = nil
	end
	destroyMoveIndicator(child)
	stopTowerWalk(child)
end)

print("[TowerManager] Ready!")