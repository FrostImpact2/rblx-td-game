--[[
	Warrior (ModuleScript)
	Place in ServerScriptService/Towers/

	Contains all Warrior-specific tower logic:
	  - Model creation (cloned from ServerStorage.TowerModels.Warrior)
	  - Abilities: Cleave (basic attack), Leaping Slash (AOE), Relentless Advance (leap-move)
	  - Passive: Survivor (out-of-combat burst healing)
	  - Animations: walk (Animation-based), attack (Animation-based), leap (Animation+Motor6D-based)
	  - VFX: hit particles, slash, heal, leap trail
]]

local RunService    = game:GetService("RunService")
local Workspace     = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")

local Warrior = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

Warrior.LEAP_SLASH_COOLDOWN        = 5
Warrior.LEAP_SLASH_DAMAGE          = 0.8     -- 80% ATK
Warrior.LEAP_SLASH_CONE_ANGLE      = math.rad(60)
Warrior.LEAP_SLASH_CONE_RANGE_MULT = 1.5
Warrior.LEAP_RANGE_MULT            = 3
Warrior.LEAP_DURATION              = 1.6     -- ↑ increased from 1.0 for more airtime
Warrior.LEAP_HEIGHT                = 7       -- ↑ increased from 4 for a higher arc

Warrior.SURVIVOR_OOC_TIME      = 3
Warrior.SURVIVOR_HEAL_INTERVAL = 3
Warrior.SURVIVOR_HEAL_PERCENT  = 0.02

-- ====== ANIMATION CONSTANTS ======
local WALK_ANIM_ID  = "rbxassetid://73323871613223"
local SWING_ANIM_ID = "rbxassetid://100041859398995"
local LEAP_ANIM_ID  = "rbxassetid://138956726369213"

-- Leap animation: 85 total frames at 30 FPS
--   Frames  1-32 : windup + early jump  (played during windup + first ~20% of flight)
--   Frame   33   : held for the bulk of airtime (~20%-75% of flight)
--   Frames 34-85 : late airtime + landing + return to idle (~75%-100% of flight + post-landing)
local LEAP_ANIM_FPS            = 30
local LEAP_ANIM_TOTAL_FRAMES   = 85

local LEAP_HOLD_FRAME          = 33
local LEAP_LANDING_START_FRAME = 34

-- Time positions (seconds) derived from frame indices (frame 1 = time 0)
local LEAP_HOLD_TIME           = (LEAP_HOLD_FRAME - 1) / LEAP_ANIM_FPS
local LEAP_LANDING_START_TIME  = (LEAP_LANDING_START_FRAME - 1) / LEAP_ANIM_FPS
local LEAP_ANIM_END_TIME       = (LEAP_ANIM_TOTAL_FRAMES - 1) / LEAP_ANIM_FPS

-- Flight-arc alpha thresholds
local LEAP_FREEZE_ALPHA   = 0.20   -- freeze on frame 33 at 20% of flight
local LEAP_UNFREEZE_ALPHA = 0.75   -- resume frames 34-85 at 75% of flight

-- Post-landing: how long (seconds) to let the landing animation play before calling onComplete
local LEAP_LANDING_LINGER = 0.8    -- ↑ increased for a longer "landing pose" hold

-- ============================================================
-- INTERNAL ANIMATION HELPERS
-- ============================================================

local function getOrCreateAnimator(towerModel: Model): Animator?
	local humanoid = towerModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		return animator
	end
	local animController = towerModel:FindFirstChildOfClass("AnimationController")
	if animController then
		local animator = animController:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = animController
		end
		return animator
	end
	warn("[Warrior] No Humanoid or AnimationController found in model, can't animate")
	return nil
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

	local towerModels = ServerStorage:FindFirstChild("TowerModels")
	local templateModel = towerModels and towerModels:FindFirstChild("Warrior")
	if not templateModel then
		warn("[Warrior] ServerStorage.TowerModels.Warrior not found")
		return nil
	end

	local model = templateModel:Clone()
	model.Name = "Warrior"

	if model.PrimaryPart then
		model.PrimaryPart.Anchored = true
	end

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
	leapCircle.Color        = Color3.fromRGB(255, 200, 50)
	leapCircle.Transparency = 1
	leapCircle.Material     = Enum.Material.Neon
	leapCircle.Parent       = model

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

	-- Sit the model exactly on the ground by measuring the lowest non-decorative part
	local lowestY = math.huge
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart")
			and part.Name ~= "RangeCircle"
			and part.Name ~= "LeapRangeCircle"
		then
			lowestY = math.min(lowestY, part.Position.Y - part.Size.Y / 2)
		end
	end
	if lowestY < math.huge then
		local lift = position.Y - lowestY
		model:PivotTo(CFrame.new(Vector3.new(position.X, position.Y + lift, position.Z)))
	end

	local finalPos = model.PrimaryPart and model.PrimaryPart.Position or position
	circle.CFrame     = CFrame.new(finalPos.X, finalPos.Y - 2.5, finalPos.Z) * CFrame.Angles(0, 0, math.rad(90))
	leapCircle.CFrame = CFrame.new(finalPos.X, finalPos.Y - 2.6, finalPos.Z) * CFrame.Angles(0, 0, math.rad(90))

	return model
end

-- ============================================================
-- LEAPING SLASH  (cone AOE, 80% ATK)
-- ============================================================

local function createConeIndicator(position: Vector3, direction: Vector3, coneRange: number, coneAngle: number)
	local groundY = position.Y - 2
	local yaw     = math.atan2(direction.X, direction.Z)

	local ring = Instance.new("Part")
	ring.Name         = "ShockwaveRing"
	ring.Shape        = Enum.PartType.Cylinder
	ring.Size         = Vector3.new(0.12, 0.5, 0.5)
	ring.Color        = Color3.fromRGB(255, 140, 20)
	ring.Material     = Enum.Material.Neon
	ring.Transparency = 0.1
	ring.Anchored     = true
	ring.CanCollide   = false
	ring.CFrame       = CFrame.new(position.X, groundY, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent       = Workspace

	local scorch = Instance.new("Part")
	scorch.Name         = "Scorch"
	scorch.Shape        = Enum.PartType.Cylinder
	scorch.Size         = Vector3.new(0.1, coneRange * 1.5, coneRange * 1.5)
	scorch.Color        = Color3.fromRGB(220, 80, 20)
	scorch.Material     = Enum.Material.Neon
	scorch.Transparency = 0.3
	scorch.Anchored     = true
	scorch.CanCollide   = false
	scorch.CFrame       = CFrame.new(position.X, groundY - 0.05, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	scorch.Parent       = Workspace

	local NUM_LINES = 7
	local lines     = {}
	for i = 1, NUM_LINES do
		local t        = (i - 1) / (NUM_LINES - 1)
		local angle    = -coneAngle + t * (coneAngle * 2)
		local lineDir  = Vector3.new(math.sin(yaw + angle), 0, math.cos(yaw + angle))
		local midPos   = Vector3.new(position.X, groundY, position.Z) + lineDir * (coneRange * 0.5)

		local line = Instance.new("Part")
		line.Name         = "SlashLine"
		line.Size         = Vector3.new(0.1, 0.08, coneRange)
		line.Color        = Color3.fromRGB(255, 200, 60)
		line.Material     = Enum.Material.Neon
		line.Transparency = 0.0
		line.Anchored     = true
		line.CanCollide   = false
		line.CFrame       = CFrame.new(midPos, midPos + lineDir)
		line.Parent       = Workspace
		table.insert(lines, line)
	end

	task.spawn(function()
		local elapsed   = 0
		local totalTime = 0.4
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			local a      = math.clamp(elapsed / totalTime, 0, 1)
			local smooth = a * a * (3 - 2 * a)

			local ringDiam = coneRange * 2 * smooth
			ring.Size         = Vector3.new(0.12, math.max(ringDiam, 0.5), math.max(ringDiam, 0.5))
			ring.Transparency = 0.1 + 0.9 * smooth

			scorch.Transparency = 0.3 + 0.7 * smooth

			for _, ln in ipairs(lines) do
				if ln and ln.Parent then
					ln.Transparency = smooth
				end
			end

			if a >= 1 then
				conn:Disconnect()
				ring:Destroy()
				scorch:Destroy()
				for _, ln in ipairs(lines) do
					if ln and ln.Parent then ln:Destroy() end
				end
			end
		end)
	end)
end

function Warrior.IsLeapSlashReady(tower: Model): boolean
	return tick() >= (tower:GetAttribute("LeapSlashCooldown") or 0)
end

function Warrior.StartLeapSlashCooldown(tower: Model)
	tower:SetAttribute("LeapSlashCooldown", tick() + Warrior.LEAP_SLASH_COOLDOWN)
	tower:SetAttribute("MoveCooldownEnd",   tick() + Warrior.LEAP_SLASH_COOLDOWN)
	tower:SetAttribute("MoveCooldownMax",   Warrior.LEAP_SLASH_COOLDOWN)
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

--[[
	Animation phase plan (85 frames @ 30 FPS):

	WINDUP PHASE (before flight):
	  - Start the leap AnimationTrack at a calculated speed so that frames 1-32
	    finish exactly when the windup phase ends + the first 20% of flight elapses.

	FLIGHT PHASE:
	  - At 20% flight alpha → freeze on frame 33 (the airborne pose).
	  - Frame 33 is held for the bulk of airtime (20% → 75%).
	  - At 75% flight alpha → unfreeze and play frames 34-85 slowly; these cover
	    the final descent + the landing impact + return to idle.

	POST-FLIGHT (landing linger):
	  - After the flight arc completes, we do NOT immediately call onComplete.
	  - Instead we wait LEAP_LANDING_LINGER seconds (or until the anim track finishes,
	    whichever is longer) so the landing/recovery frames play out fully.
	  - Then we restore motor6D bases and call onComplete → state goes back to "Idle".

	SAFETY:
	  - onComplete is wrapped so it can only fire once (no double-idle).
	  - Every early-return path (tower destroyed mid-leap, etc.) calls onComplete.
]]

function Warrior.PlayLeapAnimation(
	tower: Model,
	dest: Vector3,
	onComplete: (() -> ())?,
	findNearestEnemyFn: ((Vector3, number, Folder) -> Model?)?,
	enemiesFolder: Folder?
)
	-- ── SAFETY WRAPPER: guarantee onComplete fires exactly once ──
	local completeFired = false
	local function safeComplete()
		if completeFired then return end
		completeFired = true
		if onComplete then onComplete() end
	end

	local torso = tower.PrimaryPart
	if not torso then
		safeComplete()
		return
	end

	local animator = getOrCreateAnimator(tower)

	local startPos = torso.Position
	local dir = Vector3.new(dest.X - startPos.X, 0, dest.Z - startPos.Z)
	if dir.Magnitude > 0.1 then
		dir = dir.Unit
	else
		dir = torso.CFrame.LookVector
	end

	-- Motor6D references
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

	local WINDUP_TIME   = 0.5   -- ↑ slightly longer windup for smoother start
	local windupElapsed = 0

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

	-- Helper to restore all motor6D bases
	local function restoreAllMotors()
		if rs and rs.Parent and rsBase then rs.C0 = rsBase end
		if ls and ls.Parent and lsBase then ls.C0 = lsBase end
		if nk and nk.Parent and nkBase then nk.C0 = nkBase end
		if lh and lh.Parent and lhBase then lh.C0 = lhBase end
		if rh and rh.Parent and rhBase then rh.C0 = rhBase end
	end

	-- ── Load the leap animation track ──
	local leapTrack = nil
	if animator and LEAP_ANIM_ID then
		local ok, track = pcall(function()
			local animInstance = Instance.new("Animation")
			animInstance.AnimationId = LEAP_ANIM_ID
			local t = animator:LoadAnimation(animInstance)
			animInstance:Destroy()
			return t
		end)
		if ok and track then
			leapTrack = track
			leapTrack.Looped   = false
			leapTrack.Priority = Enum.AnimationPriority.Action
		end
	end

	-- Calculate timing
	local FLIGHT_TIME        = Warrior.LEAP_DURATION - WINDUP_TIME - 0.15
	local windupAnimDuration = LEAP_HOLD_TIME  -- seconds of anim for frames 1-32
	local realWindupSpan     = WINDUP_TIME + (LEAP_FREEZE_ALPHA * FLIGHT_TIME)
	local windupSpeed        = windupAnimDuration / realWindupSpan

	-- Start the track so frames 1-32 play during windup
	if leapTrack then
		leapTrack:Play(0)
		leapTrack:AdjustSpeed(windupSpeed)
	end

	local frozen   = false
	local unfrozen = false

	-- ── WINDUP PHASE ──
	local windupConn
	windupConn = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then
			windupConn:Disconnect()
			if leapTrack then pcall(function() leapTrack:Stop() leapTrack:Destroy() end) end
			restoreAllMotors()
			safeComplete()
			return
		end

		windupElapsed = windupElapsed + dt
		local t      = math.clamp(windupElapsed / WINDUP_TIME, 0, 1)
		local smooth = t * t * (3 - 2 * t)

		-- Motor6D windup overlay
		if rs and rsBase then rs.C0 = rsBase * CFrame.Angles(-2.8 * smooth, 0,          0.3 * smooth)  end
		if ls and lsBase then ls.C0 = lsBase * CFrame.Angles(-0.3 * smooth, 0,         -0.15 * smooth) end
		if lh and lhBase then lh.C0 = lhBase * CFrame.Angles( 0.3 * smooth, 0, 0) * CFrame.new(0, -0.15 * smooth, 0) end
		if rh and rhBase then rh.C0 = rhBase * CFrame.Angles( 0.3 * smooth, 0, 0) * CFrame.new(0, -0.15 * smooth, 0) end
		if nk and nkBase then nk.C0 = nkBase * CFrame.Angles( 0.15 * smooth, 0, 0) end

		if t >= 1 then
			windupConn:Disconnect()

			-- ── FLIGHT PHASE ──
			local stopTrail      = Warrior.SpawnLeapTrailParticles(tower)
			local launchPos      = torso.Position
			local SLOWDOWN_START = 0.75
			local flightElapsed  = 0

			local flightConn
			flightConn = RunService.Heartbeat:Connect(function(dt2)
				if not torso or not torso.Parent then
					flightConn:Disconnect()
					if stopTrail then stopTrail() end
					if leapTrack then pcall(function() leapTrack:Stop() leapTrack:Destroy() end) end
					restoreAllMotors()
					safeComplete()
					return
				end

				flightElapsed = flightElapsed + dt2
				local rawAlpha = math.clamp(flightElapsed / FLIGHT_TIME, 0, 1)

				-- Eased alpha for movement arc
				local alpha
				if rawAlpha < SLOWDOWN_START then
					alpha = (rawAlpha / SLOWDOWN_START) * SLOWDOWN_START
				else
					local slowT     = (rawAlpha - SLOWDOWN_START) / (1 - SLOWDOWN_START)
					local easedSlow = 1 - (1 - slowT) * (1 - slowT)
					alpha = SLOWDOWN_START + easedSlow * (1 - SLOWDOWN_START)
				end

				local smooth2      = alpha * alpha * (3 - 2 * alpha)
				local flatPos      = launchPos:Lerp(dest, smooth2)
				local heightOffset = Warrior.LEAP_HEIGHT * 4 * alpha * (1 - alpha)
				local newPos       = Vector3.new(flatPos.X, launchPos.Y + heightOffset, flatPos.Z)

				torso.CFrame = CFrame.new(newPos, newPos + dir)
				updateCircles(newPos)

				-- ── Animation freeze/unfreeze ──

				-- FREEZE at 20% flight: hold frame 33
				if leapTrack and not frozen and rawAlpha >= LEAP_FREEZE_ALPHA then
					leapTrack.TimePosition = LEAP_HOLD_TIME
					leapTrack:AdjustSpeed(0)
					frozen = true
				end

				-- UNFREEZE at 75% flight: play frames 34-85 for descent + landing
				if leapTrack and frozen and not unfrozen and rawAlpha >= LEAP_UNFREEZE_ALPHA then
					local remainingFlightTime = FLIGHT_TIME * (1 - LEAP_UNFREEZE_ALPHA)
					local landingAnimDuration = LEAP_ANIM_END_TIME - LEAP_LANDING_START_TIME
					-- Speed calculated so frames 34-85 fill the remaining flight + linger
					local landingRealTime = remainingFlightTime + LEAP_LANDING_LINGER
					local landingSpeed    = landingAnimDuration / landingRealTime

					leapTrack.TimePosition = LEAP_LANDING_START_TIME
					leapTrack:AdjustSpeed(landingSpeed)
					unfrozen = true
				end

				-- Motor6D adjustments during flight
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

				-- ── LANDING ──
				if rawAlpha >= 1 then
					flightConn:Disconnect()
					if stopTrail then stopTrail() end

					-- Reset leg motors (animation handles upper body from here)
					if lh and lh.Parent and lhBase then lh.C0 = lhBase end
					if rh and rh.Parent and rhBase then rh.C0 = rhBase end

					-- Perform Leaping Slash at landing site
					local slashTarget
					if findNearestEnemyFn and enemiesFolder then
						local nearest = findNearestEnemyFn(torso.Position, tower:GetAttribute("RNG") or 8, enemiesFolder)
						if nearest and nearest.PrimaryPart then
							slashTarget = nearest.PrimaryPart.Position
						end
					end
					slashTarget = slashTarget or (torso.Position + dir * 5)

					Warrior.PerformLeapingSlash(tower, slashTarget, enemiesFolder, Warrior.StartLeapSlashCooldown)

					-- ── POST-LANDING: wait for animation to finish, then complete ──
					task.spawn(function()
						if leapTrack then
							-- Make sure the track is unfrozen
							if not unfrozen then
								leapTrack.TimePosition = LEAP_LANDING_START_TIME
								leapTrack:AdjustSpeed(1)
							end

							-- Wait for the landing animation to finish.
							-- Use a timeout so we never hang forever.
							local waitStart = tick()
							local MAX_WAIT  = LEAP_LANDING_LINGER + 2.0  -- generous timeout

							-- Wait for track to finish or timeout
							while leapTrack and leapTrack.IsPlaying and (tick() - waitStart) < MAX_WAIT do
								task.wait(0.05)
							end

							-- If the track is somehow still playing, force stop
							pcall(function()
								if leapTrack then
									leapTrack:Stop(0.15)
									leapTrack:Destroy()
								end
							end)
						else
							-- No animation track — just wait the linger time
							task.wait(LEAP_LANDING_LINGER)
						end

						-- Restore all motor6D bases
						restoreAllMotors()

						-- Fire completion → TowerManager sets state to "Idle"
						safeComplete()
					end)
				end
			end)
		end
	end)
end

-- ============================================================
-- ATTACK ANIMATION  (Cleave – basic melee swing)
-- ============================================================

local attackAnimData = {}

function Warrior.PlayAttackAnimation(tower: Model, target: Model)
	local torso = tower.PrimaryPart
	if not torso then return end

	if not attackAnimData[tower] then
		attackAnimData[tower] = { animating = false }
	end
	local d = attackAnimData[tower]
	if d.animating then return end
	d.animating = true

	local tp = target.PrimaryPart and target.PrimaryPart.Position
	if tp then
		local faceDir = Vector3.new(tp.X - torso.Position.X, 0, tp.Z - torso.Position.Z)
		if faceDir.Magnitude > 0.1 then
			torso.CFrame = CFrame.new(torso.Position, torso.Position + faceDir.Unit)
		end
	end

	task.spawn(function()
		local animator = getOrCreateAnimator(tower)
		if not animator then d.animating = false return end

		local animObj = Instance.new("Animation")
		animObj.AnimationId = SWING_ANIM_ID

		local track = animator:LoadAnimation(animObj)
		animObj:Destroy()

		track.Priority = Enum.AnimationPriority.Action
		track.Looped   = false
		track:Play()

		track.Stopped:Wait()
		d.animating = false
	end)
end

-- ============================================================
-- WALK ANIMATION
-- ============================================================

local walkTracks = {}
local baseC0s    = {}

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
	if walkTracks[model] then return end
	local animator = getOrCreateAnimator(model)
	if not animator then return end

	local walkAnimObj = model:FindFirstChild("WalkAnim")
	if not walkAnimObj then
		walkAnimObj = Instance.new("Animation")
		walkAnimObj.Name        = "WalkAnim"
		walkAnimObj.AnimationId = WALK_ANIM_ID
		walkAnimObj.Parent      = model
	end

	local track = animator:LoadAnimation(walkAnimObj)
	track.Looped   = true
	track.Priority = Enum.AnimationPriority.Movement
	track:Play()
	walkTracks[model] = track
end

function Warrior.StopWalk(model: Model)
	local track = walkTracks[model]
	if track then
		track:Stop()
		track:Destroy()
		walkTracks[model] = nil
	end
	Warrior.RestoreBaseC0s(model)
end

-- sigma call when tower is removed

function Warrior.CleanupTower(tower: Model)
	attackAnimData[tower] = nil
	baseC0s[tower]        = nil
	local track = walkTracks[tower]
	if track then
		track:Stop()
		track:Destroy()
		walkTracks[tower] = nil
	end
end

return Warrior