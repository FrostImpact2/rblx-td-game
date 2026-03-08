--[[
	Warrior (ModuleScript)
	Place in ServerScriptService/Towers/

	Contains all Warrior-specific tower logic:
	  - Model creation (procedural body + sword)
	  - Abilities: Cleave (basic attack), Leaping Slash (AOE), Relentless Advance (leap-move)
	  - Passive: Survivor (out-of-combat burst healing)
	  - Animations: walk, attack (Cleave), leap
	  - VFX: hit particles, slash, heal, leap trail
]]

local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local Warrior = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

Warrior.LEAP_SLASH_COOLDOWN        = 5
Warrior.LEAP_SLASH_DAMAGE          = 0.8     -- 80% ATK
Warrior.LEAP_SLASH_CONE_ANGLE      = math.rad(60)
Warrior.LEAP_SLASH_CONE_RANGE_MULT = 1.5
Warrior.LEAP_RANGE_MULT            = 3
Warrior.LEAP_DURATION              = 1
Warrior.LEAP_HEIGHT                = 4

Warrior.SURVIVOR_OOC_TIME      = 3
Warrior.SURVIVOR_HEAL_INTERVAL = 3
Warrior.SURVIVOR_HEAL_PERCENT  = 0.02

-- ============================================================
-- INTERNAL PART / MOTOR HELPERS
-- ============================================================

local function makePart(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name           = name
	p.Size           = size
	p.Color          = color
	p.Anchored       = false
	p.CanCollide     = false
	p.Material       = Enum.Material.SmoothPlastic
	p.TopSurface     = Enum.SurfaceType.Smooth
	p.BottomSurface  = Enum.SurfaceType.Smooth
	p.Parent         = parent
	return p
end

local function makeMotor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame?): Motor6D
	local m = Instance.new("Motor6D")
	m.Name  = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0    = c0
	m.C1    = c1 or CFrame.new()
	m.Parent = part0
	return m
end

-- ============================================================
-- VFX
-- ============================================================

function Warrior.SpawnHitParticles(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name         = "ParticleAnchor"
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Position     = position
	anchor.Parent       = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color        = ColorSequence.new(color)
	emitter.Size         = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime     = NumberRange.new(0.2, 0.4)
	emitter.Speed        = NumberRange.new(4, 8)
	emitter.SpreadAngle  = Vector2.new(180, 180)
	emitter.Rate         = 0
	emitter.Parent       = att
	emitter:Emit(8)

	task.delay(0.5, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

function Warrior.SpawnSlashParticles(position: Vector3, direction: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name         = "SlashVFXAnchor"
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CFrame       = CFrame.new(position, position + direction)
	anchor.Parent       = Workspace

	-- Main slash burst
	local att1 = Instance.new("Attachment")
	att1.Parent = anchor

	local slash = Instance.new("ParticleEmitter")
	slash.Color       = ColorSequence.new(Color3.fromRGB(255, 220, 60), Color3.fromRGB(255, 100, 20))
	slash.Size        = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.0), NumberSequenceKeypoint.new(0.3, 1.2), NumberSequenceKeypoint.new(1, 0) })
	slash.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.0), NumberSequenceKeypoint.new(0.4, 0.3), NumberSequenceKeypoint.new(1, 1) })
	slash.Lifetime    = NumberRange.new(0.15, 0.35)
	slash.Speed       = NumberRange.new(12, 22)
	slash.SpreadAngle = Vector2.new(35, 8)
	slash.Rate        = 0
	slash.Acceleration = Vector3.new(0, -10, 0)
	slash.RotSpeed    = NumberRange.new(-200, 200)
	slash.Rotation    = NumberRange.new(0, 360)
	slash.Parent      = att1
	slash:Emit(20)

	-- Sparks
	local att2 = Instance.new("Attachment")
	att2.Parent = anchor

	local sparks = Instance.new("ParticleEmitter")
	sparks.Color        = ColorSequence.new(Color3.fromRGB(255, 255, 200))
	sparks.Size         = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 1) })
	sparks.Lifetime     = NumberRange.new(0.1, 0.25)
	sparks.Speed        = NumberRange.new(15, 30)
	sparks.SpreadAngle  = Vector2.new(50, 20)
	sparks.Rate         = 0
	sparks.Acceleration = Vector3.new(0, -20, 0)
	sparks.Parent       = att2
	sparks:Emit(12)

	-- Impact ring expansion
	local ring = Instance.new("Part")
	ring.Name         = "ImpactRing"
	ring.Shape        = Enum.PartType.Cylinder
	ring.Size         = Vector3.new(0.1, 0.1, 0.1)
	ring.Color        = Color3.fromRGB(255, 180, 50)
	ring.Material     = Enum.Material.Neon
	ring.Transparency = 0.2
	ring.Anchored     = true
	ring.CanCollide   = false
	ring.CFrame       = CFrame.new(position.X, position.Y - 2, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent       = Workspace

	local wave = Instance.new("Part")
	wave.Name         = "ImpactWave"
	wave.Shape        = Enum.PartType.Cylinder
	wave.Size         = Vector3.new(0.05, 0.1, 0.1)
	wave.Color        = Color3.fromRGB(255, 240, 180)
	wave.Material     = Enum.Material.Neon
	wave.Transparency = 0.4
	wave.Anchored     = true
	wave.CanCollide   = false
	wave.CFrame       = CFrame.new(position.X, position.Y - 1.8, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	wave.Parent       = Workspace

	task.spawn(function()
		local elapsed   = 0
		local expandTime = 0.3
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			local a      = math.clamp(elapsed / expandTime, 0, 1)
			local smooth = a * a * (3 - 2 * a)

			local sz1 = 10 * smooth
			ring.Size         = Vector3.new(0.1, sz1, sz1)
			ring.Transparency = 0.2 + 0.8 * smooth

			local sz2 = 6 * smooth
			wave.Size         = Vector3.new(0.05, sz2, sz2)
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

function Warrior.SpawnHealParticles(towerModel: Model)
	local torso = towerModel.PrimaryPart
	if not torso then return end

	local anchor = Instance.new("Part")
	anchor.Name         = "HealVFXAnchor"
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Position     = torso.Position
	anchor.Parent       = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color        = ColorSequence.new(Color3.fromRGB(80, 255, 80))
	emitter.Size         = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(0.5, 0.6), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime     = NumberRange.new(0.5, 0.8)
	emitter.Speed        = NumberRange.new(2, 5)
	emitter.SpreadAngle  = Vector2.new(360, 30)
	emitter.Rate         = 0
	emitter.Acceleration = Vector3.new(0, 6, 0)
	emitter.Parent       = att
	emitter:Emit(12)

	task.delay(1, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

function Warrior.SpawnLeapTrailParticles(towerModel: Model): () -> ()
	local torso = towerModel.PrimaryPart
	if not torso then return function() end end

	local att1 = Instance.new("Attachment")
	att1.Name   = "LeapTrailAtt"
	att1.Parent = torso

	local trail = Instance.new("ParticleEmitter")
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 240, 140)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 180, 60)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(255, 100, 20)),
	})
	trail.Size         = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.0), NumberSequenceKeypoint.new(0.3, 0.6), NumberSequenceKeypoint.new(1, 0) })
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.5, 0.4), NumberSequenceKeypoint.new(1, 1) })
	trail.Lifetime     = NumberRange.new(0.2, 0.4)
	trail.Speed        = NumberRange.new(0, 2)
	trail.Rate         = 80
	trail.Acceleration = Vector3.new(0, -8, 0)
	trail.RotSpeed     = NumberRange.new(-100, 100)
	trail.Parent       = att1

	local att2 = Instance.new("Attachment")
	att2.Name     = "LeapWindAtt"
	att2.Position = Vector3.new(0, -1.5, 0)
	att2.Parent   = torso

	local wind = Instance.new("ParticleEmitter")
	wind.Color        = ColorSequence.new(Color3.fromRGB(200, 220, 255))
	wind.Size         = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.5, 0.4), NumberSequenceKeypoint.new(1, 0) })
	wind.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	wind.Lifetime     = NumberRange.new(0.1, 0.2)
	wind.Speed        = NumberRange.new(2, 6)
	wind.SpreadAngle  = Vector2.new(180, 180)
	wind.Rate         = 40
	wind.Parent       = att2

	-- Returns a stop function
	return function()
		trail.Rate = 0
		wind.Rate  = 0
		task.delay(0.5, function()
			if att1 and att1.Parent then att1:Destroy() end
			if att2 and att2.Parent then att2:Destroy() end
		end)
	end
end

-- ============================================================
-- MODEL CREATION
-- ============================================================

function Warrior.CreateModel(position: Vector3, TowerStats: any, leapRangeMult: number, leapSlashCooldown: number): Model?
	local template = TowerStats.Templates["Warrior"]
	if not template then return nil end

	local model = Instance.new("Model")
	model.Name  = "Warrior"

	-- Body
	local torso = makePart("HumanoidRootPart", Vector3.new(2, 2.4, 1.2), Color3.fromRGB(60, 90, 150), model)
	torso.Anchored  = true
	model.PrimaryPart = torso

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

	-- Legs
	local lLeg = makePart("LeftLeg", Vector3.new(0.9, 2.4, 1), Color3.fromRGB(50, 70, 120), model)
	makeMotor("LeftHip", torso, lLeg, CFrame.new(-0.5, -1.2, 0), CFrame.new(0, 1.2, 0))

	local rLeg = makePart("RightLeg", Vector3.new(0.9, 2.4, 1), Color3.fromRGB(50, 70, 120), model)
	makeMotor("RightHip", torso, rLeg, CFrame.new(0.5, -1.2, 0), CFrame.new(0, 1.2, 0))

	-- Range indicators
	local rangeStuds = template.RNG

	local circle = Instance.new("Part")
	circle.Name         = "RangeCircle"
	circle.Shape        = Enum.PartType.Cylinder
	circle.Size         = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored     = true
	circle.CanCollide   = false
	circle.Color        = Color3.fromRGB(30, 100, 200)
	circle.Transparency = 1
	circle.Material     = Enum.Material.SmoothPlastic
	circle.Parent       = model

	local leapRange = rangeStuds * leapRangeMult
	local leapCircle = Instance.new("Part")
	leapCircle.Name         = "LeapRangeCircle"
	leapCircle.Shape        = Enum.PartType.Cylinder
	leapCircle.Size         = Vector3.new(0.1, leapRange * 2, leapRange * 2)
	leapCircle.Anchored     = true
	leapCircle.CanCollide   = false
	leapCircle.Color        = Color3.fromRGB(30, 100, 200)
	leapCircle.Transparency = 1
	leapCircle.Material     = Enum.Material.Neon
	leapCircle.Parent       = model

	-- Attributes
	model:SetAttribute("ATK",               template.ATK)
	model:SetAttribute("ATK_SPD",           template.ATK_SPD)
	model:SetAttribute("RNG",               rangeStuds)
	model:SetAttribute("HP",                template.HP)
	model:SetAttribute("MaxHP",             template.HP)
	model:SetAttribute("MOVE_SPD",          template.MOVE_SPD)
	model:SetAttribute("DamageMulti",       template.DamageMulti)
	model:SetAttribute("AttackType",        template.AttackType)
	model:SetAttribute("State",             "Idle")
	model:SetAttribute("Owner",             "")
	model:SetAttribute("LastCombatTime",    tick())
	model:SetAttribute("LastHealTick",      tick())
	model:SetAttribute("LeapSlashCooldown", 0)
	model:SetAttribute("LeapSlashMaxCD",    leapSlashCooldown)

	model:PivotTo(CFrame.new(position))
	circle.CFrame     = CFrame.new(position.X, position.Y - 2.5, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	leapCircle.CFrame = CFrame.new(position.X, position.Y - 2.6, position.Z) * CFrame.Angles(0, 0, math.rad(90))

	return model
end

-- ============================================================
-- LEAPING SLASH  (cone AOE, 80% ATK)
-- ============================================================

local function createConeIndicator(position: Vector3, direction: Vector3, coneRange: number, coneAngle: number)
	local anchor   = Instance.new("Folder")
	anchor.Name    = "ConeFlash"
	local groundY  = position.Y - 2
	local segments = 16
	local segAngle = (coneAngle * 2) / segments
	local yaw      = math.atan2(direction.X, direction.Z)

	for i = 0, segments - 1 do
		local a1   = -coneAngle + segAngle * i
		local a2   = -coneAngle + segAngle * (i + 1)
		local dir1 = Vector3.new(math.sin(yaw + a1), 0, math.cos(yaw + a1))
		local dir2 = Vector3.new(math.sin(yaw + a2), 0, math.cos(yaw + a2))
		local p1   = Vector3.new(position.X, groundY, position.Z) + dir1 * coneRange
		local p2   = Vector3.new(position.X, groundY, position.Z) + dir2 * coneRange
		local center = Vector3.new(position.X, groundY, position.Z)
		local mid  = (center + p1 + p2) / 3
		local span = math.max((p1 - p2).Magnitude, 0.1)

		local seg = Instance.new("Part")
		seg.Size        = Vector3.new(span, 0.08, coneRange)
		seg.Color       = Color3.fromRGB(255, 200, 60)
		seg.Material    = Enum.Material.Neon
		seg.Transparency = 0.3
		seg.Anchored    = true
		seg.CanCollide  = false
		seg.CFrame      = CFrame.new(mid, mid + Vector3.new(direction.X, 0, direction.Z))
		seg.Parent      = anchor
	end

	anchor.Parent = Workspace

	task.spawn(function()
		task.wait(0.1)
		local fadeTime = 0.35
		local elapsed  = 0
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			local a      = math.clamp(elapsed / fadeTime, 0, 1)
			local smooth = a * a * (3 - 2 * a)
			for _, part in ipairs(anchor:GetChildren()) do
				if part:IsA("Part") then
					part.Transparency = 0.3 + 0.7 * smooth
				end
			end
			if a >= 1 then
				conn:Disconnect()
				anchor:Destroy()
			end
		end)
	end)
end

function Warrior.IsLeapSlashReady(tower: Model): boolean
	return tick() >= (tower:GetAttribute("LeapSlashCooldown") or 0)
end

function Warrior.StartLeapSlashCooldown(tower: Model)
	tower:SetAttribute("LeapSlashCooldown", tick() + Warrior.LEAP_SLASH_COOLDOWN)
end

function Warrior.PerformLeapingSlash(
	tower: Model,
	targetPos: Vector3,
	enemiesFolder: Folder,
	startCooldownFn: ((Model) -> ())?
)
	local torso = tower.PrimaryPart
	if not torso then return end

	local atk    = tower:GetAttribute("ATK") or 10
	local multi  = tower:GetAttribute("DamageMulti") or 1.0
	local damage = atk * Warrior.LEAP_SLASH_DAMAGE * multi
	local range  = tower:GetAttribute("RNG") or 8

	local slashPos = torso.Position
	local dir = Vector3.new(targetPos.X - slashPos.X, 0, targetPos.Z - slashPos.Z)
	if dir.Magnitude > 0.1 then
		dir = dir.Unit
		torso.CFrame = CFrame.new(slashPos, slashPos + dir)
	else
		dir = torso.CFrame.LookVector
	end

	local CONE_RANGE = range * Warrior.LEAP_SLASH_CONE_RANGE_MULT

	createConeIndicator(slashPos, dir, CONE_RANGE, Warrior.LEAP_SLASH_CONE_ANGLE)
	Warrior.SpawnSlashParticles(slashPos, dir)

	-- Damage all enemies in the cone
	for _, enemy in ipairs(enemiesFolder:GetChildren()) do
		if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
			local toEnemy = enemy.PrimaryPart.Position - slashPos
			toEnemy = Vector3.new(toEnemy.X, 0, toEnemy.Z)
			local dist = toEnemy.Magnitude

			if dist <= CONE_RANGE and dist > 0.1 then
				local angle = math.acos(math.clamp(dir:Dot(toEnemy.Unit), -1, 1))
				if angle <= Warrior.LEAP_SLASH_CONE_ANGLE then
					local hp = enemy:GetAttribute("HP") or 0
					enemy:SetAttribute("HP", hp - damage)
					Warrior.SpawnHitParticles(enemy.PrimaryPart.Position, Color3.fromRGB(255, 150, 50))
					if (hp - damage) <= 0 then enemy:Destroy() end
				end
			end
		end
	end

	tower:SetAttribute("LastCombatTime", tick())
	if startCooldownFn then
		startCooldownFn(tower)
	end
end

-- ============================================================
-- LEAP ANIMATION  (Relentless Advance)
-- ============================================================

function Warrior.PlayLeapAnimation(
	tower: Model,
	dest: Vector3,
	onComplete: (() -> ())?,
	findNearestEnemyFn: ((Vector3, number, Folder) -> Model?)?,
	enemiesFolder: Folder?
)
	local torso = tower.PrimaryPart
	if not torso then
		if onComplete then onComplete() end
		return
	end

	local startPos = torso.Position
	local dir = Vector3.new(dest.X - startPos.X, 0, dest.Z - startPos.Z)
	if dir.Magnitude > 0.1 then
		dir = dir.Unit
	else
		dir = torso.CFrame.LookVector
	end

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

	local WINDUP_TIME    = 0.4
	local windupElapsed  = 0

	torso.CFrame = CFrame.new(startPos, startPos + dir)

	local circle     = tower:FindFirstChild("RangeCircle")
	local leapCircle = tower:FindFirstChild("LeapRangeCircle")

	local function updateCircles(pos: Vector3)
		if circle and circle.Parent then
			circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
		if leapCircle and leapCircle.Parent then
			leapCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end

	-- WINDUP PHASE
	local windupConn
	windupConn = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then
			windupConn:Disconnect()
			if onComplete then onComplete() end
			return
		end

		windupElapsed = windupElapsed + dt
		local t      = math.clamp(windupElapsed / WINDUP_TIME, 0, 1)
		local smooth = t * t * (3 - 2 * t)

		if rs and rsBase then rs.C0 = rsBase * CFrame.Angles(-2.8 * smooth, 0,          0.3 * smooth)  end
		if ls and lsBase then ls.C0 = lsBase * CFrame.Angles(-0.3 * smooth, 0,         -0.15 * smooth) end
		if lh and lhBase then lh.C0 = lhBase * CFrame.Angles( 0.3 * smooth, 0, 0) * CFrame.new(0, -0.15 * smooth, 0) end
		if rh and rhBase then rh.C0 = rhBase * CFrame.Angles( 0.3 * smooth, 0, 0) * CFrame.new(0, -0.15 * smooth, 0) end
		if nk and nkBase then nk.C0 = nkBase * CFrame.Angles( 0.15 * smooth, 0, 0) end

		if t >= 1 then
			windupConn:Disconnect()

			local stopTrail     = Warrior.SpawnLeapTrailParticles(tower)
			local launchPos     = torso.Position
			local FLIGHT_TIME   = Warrior.LEAP_DURATION - WINDUP_TIME - 0.12
			local SLOWDOWN_START = 0.75
			local flightElapsed = 0

			-- FLIGHT PHASE
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

				local alpha
				if rawAlpha < SLOWDOWN_START then
					alpha = (rawAlpha / SLOWDOWN_START) * SLOWDOWN_START
				else
					local slowT    = (rawAlpha - SLOWDOWN_START) / (1 - SLOWDOWN_START)
					local easedSlow = 1 - (1 - slowT) * (1 - slowT)
					alpha = SLOWDOWN_START + easedSlow * (1 - SLOWDOWN_START)
				end

				local smooth2      = alpha * alpha * (3 - 2 * alpha)
				local flatPos      = launchPos:Lerp(dest, smooth2)
				local heightOffset = Warrior.LEAP_HEIGHT * 4 * alpha * (1 - alpha)
				local newPos       = Vector3.new(flatPos.X, launchPos.Y + heightOffset, flatPos.Z)

				torso.CFrame = CFrame.new(newPos, newPos + dir)
				updateCircles(newPos)

				if alpha < 0.5 then
					local rise = alpha * 2
					local rs2  = rise * rise * (3 - 2 * rise)
					if lh and lhBase then lh.C0 = lhBase * CFrame.Angles(0.3 + 0.3 * rs2, 0, 0) * CFrame.new(0, -0.15, 0) end
					if rh and rhBase then rh.C0 = rhBase * CFrame.Angles(0.3 + 0.3 * rs2, 0, 0) * CFrame.new(0, -0.15, 0) end
				else
					local fall       = (alpha - 0.5) * 2
					local fs         = fall * fall * (3 - 2 * fall)
					local swordAngle = -2.8 + (2.8 + 0.8) * fs
					local legTuck    = 0.6 * (1 - fs)
					if rs and rsBase then rs.C0 = rsBase * CFrame.Angles(swordAngle,          -0.5 * fs,        0.3 - 0.7 * fs)  end
					if ls and lsBase then ls.C0 = lsBase * CFrame.Angles(-0.3 + 0.1 * fs,  0, -0.15 + 0.35 * fs) end
					if lh and lhBase then lh.C0 = lhBase * CFrame.Angles(legTuck, 0, 0) end
					if rh and rhBase then rh.C0 = rhBase * CFrame.Angles(legTuck, 0, 0) end
					if nk and nkBase then nk.C0 = nkBase * CFrame.Angles(0.15 - 0.3 * fs, 0, 0) end
				end

				if rawAlpha >= 1 then
					flightConn:Disconnect()
					if stopTrail then stopTrail() end

					if lh and lh.Parent and lhBase then lh.C0 = lhBase end
					if rh and rh.Parent and rhBase then rh.C0 = rhBase end

					-- Perform Leaping Slash on nearest enemy at landing site
					local slashTarget
					if findNearestEnemyFn and enemiesFolder then
						local nearest = findNearestEnemyFn(torso.Position, tower:GetAttribute("RNG") or 8, enemiesFolder)
						if nearest and nearest.PrimaryPart then
							slashTarget = nearest.PrimaryPart.Position
						end
					end
					slashTarget = slashTarget or (torso.Position + dir * 5)

					Warrior.PerformLeapingSlash(tower, slashTarget, enemiesFolder, Warrior.StartLeapSlashCooldown)

					-- Recovery animation
					task.spawn(function()
						local recFrames = 8
						local recTime   = 0.25
						local recDt     = recTime / recFrames
						local rsStart   = rs and rs.C0
						local lsStart   = ls and ls.C0
						local nkStart   = nk and nk.C0
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
-- ATTACK ANIMATION  (Cleave – basic melee swing)
-- ============================================================

local attackAnimData = {}   -- tower -> { rsC0, lsC0, nkC0, animating }

function Warrior.PlayAttackAnimation(tower: Model, target: Model)
	local torso = tower.PrimaryPart
	if not torso then return end

	local rs = torso:FindFirstChild("RightShoulder")
	local ls = torso:FindFirstChild("LeftShoulder")
	local nk = torso:FindFirstChild("Neck")
	if not rs then return end

	if not attackAnimData[tower] then
		attackAnimData[tower] = { rsC0 = rs.C0, lsC0 = ls and ls.C0, nkC0 = nk and nk.C0, animating = false }
	end
	local d = attackAnimData[tower]
	if d.animating then return end
	d.animating = true

	-- Face the target
	local tp = target.PrimaryPart and target.PrimaryPart.Position
	if tp then
		local faceDir = Vector3.new(tp.X - torso.Position.X, 0, tp.Z - torso.Position.Z)
		if faceDir.Magnitude > 0.1 then
			torso.CFrame = CFrame.new(torso.Position, torso.Position + faceDir.Unit)
		end
	end

	task.spawn(function()
		local STEPS     = 6
		local totalTime = 0.35
		local stepTime  = totalTime / STEPS

		local keyframes = {
			{ CFrame.Angles(-2.2, 0.5, 0.4),   CFrame.Angles(0.4, 0.1, -0.3),   CFrame.Angles(0.1, -0.15, 0)  },
			{ CFrame.Angles(-1.0, 0.2, 0.1),   CFrame.Angles(0.1, 0.05, -0.1),  CFrame.Angles(0.05, -0.05, 0) },
			{ CFrame.Angles(0.4, -0.5, -0.6),  CFrame.Angles(-0.3, -0.1, 0.2),  CFrame.Angles(-0.1, 0.1, 0)   },
			{ CFrame.Angles(0.8, -0.7, -0.8),  CFrame.Angles(-0.4, -0.15, 0.3), CFrame.Angles(-0.15, 0.12, 0) },
			{ CFrame.Angles(-0.2, 0.1, 0.1),   CFrame.Angles(-0.05, 0, 0.05),   CFrame.Angles(0, 0, 0)        },
			{ CFrame.Angles(0, 0, 0),           CFrame.Angles(0, 0, 0),           CFrame.Angles(0, 0, 0)        },
		}

		for i = 1, STEPS do
			if not rs or not rs.Parent then d.animating = false return end

			local kf     = keyframes[i]
			local frames = 4
			local frameDt = stepTime / frames

			local rsCur = rs.C0 * d.rsC0:Inverse()
			local lsCur = (ls and ls.Parent and d.lsC0) and (ls.C0 * d.lsC0:Inverse()) or CFrame.new()
			local nkCur = (nk and nk.Parent and d.nkC0) and (nk.C0 * d.nkC0:Inverse()) or CFrame.new()

			for f = 1, frames do
				if not rs or not rs.Parent then d.animating = false return end
				local t = f / frames
				t = t * t * (3 - 2 * t)

				rs.C0 = d.rsC0 * rsCur:Lerp(kf[1], t)
				if ls and ls.Parent and d.lsC0 then ls.C0 = d.lsC0 * lsCur:Lerp(kf[2], t) end
				if nk and nk.Parent and d.nkC0 then nk.C0 = d.nkC0 * nkCur:Lerp(kf[3], t) end

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
-- WALK ANIMATION
-- ============================================================

local walkConnections = {}   -- model -> RBXScriptConnection
local baseC0s         = {}   -- model -> { motorName -> C0 }

function Warrior.StoreBaseC0s(model: Model)
	if baseC0s[model] then return end
	local torso = model.PrimaryPart
	if not torso then return end
	local stored = {}
	for _, n in ipairs({"Neck", "LeftShoulder", "RightShoulder", "LeftHip", "RightHip"}) do
		local motor = torso:FindFirstChild(n)
		if motor then stored[n] = motor.C0 end
	end
	baseC0s[model] = stored
end

function Warrior.RestoreBaseC0s(model: Model)
	local stored = baseC0s[model]
	if not stored then return end
	local torso = model.PrimaryPart
	if not torso then return end
	for n, c0 in pairs(stored) do
		local motor = torso:FindFirstChild(n)
		if motor then motor.C0 = c0 end
	end
end

function Warrior.StartWalk(model: Model)
	if walkConnections[model] then return end
	local torso = model.PrimaryPart
	if not torso then return end

	Warrior.StoreBaseC0s(model)
	local s   = baseC0s[model]
	local lsC0 = s["LeftShoulder"]
	local rsC0 = s["RightShoulder"]
	local lhC0 = s["LeftHip"]
	local rhC0 = s["RightHip"]
	local nkC0 = s["Neck"]

	local lS = torso:FindFirstChild("LeftShoulder")
	local rS = torso:FindFirstChild("RightShoulder")
	local lH = torso:FindFirstChild("LeftHip")
	local rH = torso:FindFirstChild("RightHip")
	local nk = torso:FindFirstChild("Neck")

	local elapsed = 0

	walkConnections[model] = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then return end
		elapsed = elapsed + dt * 5.5

		local sin     = math.sin(elapsed)
		local cos     = math.cos(elapsed)
		local abs_sin = math.abs(sin)

		local bob     = math.abs(math.sin(elapsed * 2)) * 0.15
		local lean    = math.sin(elapsed * 2) * 0.04
		local sway    = sin * 0.02
		local breathe = math.sin(elapsed * 0.7) * 0.01

		-- Left leg
		local lY, lZ, lA
		if sin > 0 then
			local smoothT = sin * sin * (3 - 2 * sin)
			lY = smoothT * 0.3; lZ = -sin * 0.6; lA = -cos * 0.08
		else
			local p = -sin; local smoothP = p * p * (3 - 2 * p)
			lY = (1 - smoothP) * smoothP * 0.3; lZ = -sin * 0.6; lA = sin * 0.5
		end

		-- Right leg
		local rY, rZ, rA
		if sin < 0 then
			local t = -sin; local smoothT = t * t * (3 - 2 * t)
			rY = smoothT * 0.3; rZ = sin * 0.6; rA = cos * 0.08
		else
			local p = sin; local smoothP = p * p * (3 - 2 * p)
			rY = (1 - smoothP) * smoothP * 0.3; rZ = sin * 0.6; rA = -sin * 0.5
		end

		if lH and lhC0 then lH.C0 = lhC0 * CFrame.new(0, -bob + lY, lZ) * CFrame.Angles(lA, 0, 0) end
		if rH and rhC0 then rH.C0 = rhC0 * CFrame.new(0, -bob + rY, rZ) * CFrame.Angles(rA, 0, 0) end

		local lArmSwing = -sin * 0.4
		local rArmSwing =  sin * 0.4
		local elbowBend = abs_sin * 0.2

		if lS and lsC0 then lS.C0 = lsC0 * CFrame.Angles(lArmSwing + lean + breathe, 0,  elbowBend + sway) end
		if rS and rsC0 then rS.C0 = rsC0 * CFrame.Angles(rArmSwing + lean + breathe, 0, -elbowBend + sway) end
		if nk and nkC0 then nk.C0 = nkC0 * CFrame.new(0, bob, 0) * CFrame.Angles(-sin * 0.05 - lean, sin * 0.015, -sway) end
	end)
end

function Warrior.StopWalk(model: Model)
	local c = walkConnections[model]
	if c then
		c:Disconnect()
		walkConnections[model] = nil
	end
	Warrior.RestoreBaseC0s(model)
end

-- ============================================================
-- CLEANUP: call when tower is removed
-- ============================================================

function Warrior.CleanupTower(tower: Model)
	attackAnimData[tower] = nil
	baseC0s[tower]        = nil
	local c = walkConnections[tower]
	if c then
		c:Disconnect()
		walkConnections[tower] = nil
	end
end

return Warrior
