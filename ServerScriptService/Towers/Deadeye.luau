--[[
	Deadeye (ModuleScript)
	Place in ServerScriptService/Towers/

	Ranged Eco tower | 4/7 Difficulty

	Abilities
	  - Basic Attack  – Revolver:     1× ATK to a single target.
	                                  Enhances after every 2 uses.
	  - Enhanced Attack – Headhunter: Locks onto the HIGHEST MAX HP enemy in range.
	                                  Fires a shot dealing 1× AP.
	                                  Executes enemies under 25 % MaxHP unless the
	                                  HP remaining exceeds 2× AP.
	                                  Has a longer aim delay before firing.

	Animation state machine
	  idle  →  raising  →  shoot_hold  →  (lowering after 3 s no shot)  →  idle
	  Any state  →  walking  (on player-initiated move)
	  walking  →  idle  (on arrival)

	Animations
	  Idle      : 130403916615858  (looped)
	  Walk      : rbxassetid://73323871613223   (same asset as Warrior, looped)
	  Gun Raise : 75900515991486   (one-shot, Action priority)
	  Shoot     : 108396781520756  (one-shot, restarted from frame 0 on every shot)
	  Gun Lower : 107226036750887  (one-shot, Action priority)
]]

local TweenService  = game:GetService("TweenService")
local RunService    = game:GetService("RunService")
local Workspace     = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")

local Deadeye = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

Deadeye.ENHANCE_AFTER          = 2      -- basic attacks before enhanced fires
Deadeye.EXECUTE_HP_THRESHOLD   = 0.25   -- execute if enemy HP < 25 % of MaxHP
Deadeye.EXECUTE_DMG_CAP_MULT   = 2.0    -- execute only if enemy HP <= 2 × AP
Deadeye.GUN_RAISE_DELAY        = 0.15   -- seconds after raise finishes before first shot
Deadeye.GUN_LOWER_DELAY        = 3.0    -- seconds without a shot → lower gun
Deadeye.BULLET_SPEED           = 180    -- studs / second
Deadeye.HEADHUNTER_AIM_DELAY   = 1.2    -- extra aim hold time before Headhunter fires

-- ====== ANIMATION IDs ======
local IDLE_ANIM_ID  = "rbxassetid://130403916615858"
local WALK_ANIM_ID  = "rbxassetid://73323871613223"
local RAISE_ANIM_ID = "rbxassetid://75900515991486"
local SHOOT_ANIM_ID = "rbxassetid://108396781520756"
local LOWER_ANIM_ID = "rbxassetid://107226036750887"

-- ============================================================
-- INTERNAL STATE
-- ============================================================

local animState  = {}  -- tower → animation-state record
local baseC0s    = {}  -- tower → stored Motor6D C0 values
local walkTracks = {}  -- tower → active walk AnimationTrack

-- Headhunter aim VFX state per tower
-- hhVFX[tower] = {
--   crosshairParts: { Part, Part, Part },   -- the 3 neon red + parts on the enemy
--   laserPart: Part,                         -- the beam from barrel to enemy
--   heartbeatConn: RBXScriptConnection,
--   aimStartTime: number,
--   target: Model,
-- }
local hhVFX = {}

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================

local function getOrCreateAnimator(towerModel: Model): Animator?
	local humanoid = towerModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local a = humanoid:FindFirstChildOfClass("Animator")
		if not a then
			a = Instance.new("Animator")
			a.Parent = humanoid
		end
		return a
	end
	local animCtrl = towerModel:FindFirstChildOfClass("AnimationController")
	if animCtrl then
		local a = animCtrl:FindFirstChildOfClass("Animator")
		if not a then
			a = Instance.new("Animator")
			a.Parent = animCtrl
		end
		return a
	end
	warn("[Deadeye] No Humanoid or AnimationController found – can't animate")
	return nil
end

local function safeStop(track, blendTime: number?)
	if track then
		pcall(function()
			if track.IsPlaying then
				track:Stop(blendTime or 0.1)
			end
		end)
	end
end

local function safeDestroy(track)
	if track then
		pcall(function()
			if track.IsPlaying then track:Stop(0) end
			track:Destroy()
		end)
	end
end

local function loadAndPlay(
	animator: Animator,
	animId: string,
	looped: boolean,
	priority: Enum.AnimationPriority,
	blendTime: number?
): AnimationTrack?
	local ok, result = pcall(function()
		local obj = Instance.new("Animation")
		obj.AnimationId = animId
		local t = animator:LoadAnimation(obj)
		obj:Destroy()
		t.Looped   = looped
		t.Priority = priority
		t:Play(blendTime or 0.1)
		return t
	end)
	if ok and result then return result end
	return nil
end

local function getAnimState(tower: Model)
	if not animState[tower] then
		animState[tower] = {
			gunState          = "idle",
			idleTrack         = nil,
			raiseTrack        = nil,
			shootTrack        = nil,
			lowerTrack        = nil,
			lastShotTime      = -math.huge,
			readyToFireTime   = 0,
		}
	end
	return animState[tower]
end

-- ============================================================
-- VFX – HEADHUNTER AIM (crosshair + laser line)
-- ============================================================

-- Destroys all Headhunter aim VFX for a tower.
local function clearHHVFX(tower: Model)
	local vfx = hhVFX[tower]
	if not vfx then return end

	if vfx.heartbeatConn then
		vfx.heartbeatConn:Disconnect()
	end
	if vfx.crosshairParts then
		for _, p in ipairs(vfx.crosshairParts) do
			if p and p.Parent then p:Destroy() end
		end
	end
	if vfx.laserPart and vfx.laserPart.Parent then
		vfx.laserPart:Destroy()
	end
	hhVFX[tower] = nil
end

--[[
	Creates a red crosshair ( + shape ) floating above the target's chest
	and a thin red laser beam from the gun barrel to the target.
	Both update every Heartbeat while the Headhunter is aiming.
	Returns the aimStartTime so the caller knows when the lock-on began.
]]
local function showHHVFX(tower: Model, target: Model): number
	clearHHVFX(tower)

	local RED        = Color3.fromRGB(255, 30, 30)
	local CROSS_SIZE = 0.55   -- length of each arm
	local CROSS_THICK = 0.07  -- thickness

	-- ── Crosshair: 3 flat neon parts forming a + ──
	local function makeCrossPart(size: Vector3): Part
		local p = Instance.new("Part")
		p.Size         = size
		p.Color        = RED
		p.Material     = Enum.Material.Neon
		p.Anchored     = true
		p.CanCollide   = false
		p.CastShadow   = false
		p.Transparency = 0
		p.Parent       = Workspace
		return p
	end

	-- Horizontal bar
	local hBar = makeCrossPart(Vector3.new(CROSS_SIZE, CROSS_THICK, CROSS_THICK))
	-- Vertical bar
	local vBar = makeCrossPart(Vector3.new(CROSS_THICK, CROSS_SIZE, CROSS_THICK))
	-- Center dot
	local dot  = makeCrossPart(Vector3.new(CROSS_THICK * 1.5, CROSS_THICK * 1.5, CROSS_THICK * 1.5))

	-- ── Laser beam (stretched part from barrel to target chest) ──
	local laser = Instance.new("Part")
	laser.Name         = "HHLaser"
	laser.Material     = Enum.Material.Neon
	laser.Color        = RED
	laser.Anchored     = true
	laser.CanCollide   = false
	laser.CastShadow   = false
	laser.Transparency = 0.35
	laser.Parent       = Workspace

	local aimStartTime = tick()

	hhVFX[tower] = {
		crosshairParts = { hBar, vBar, dot },
		laserPart      = laser,
		heartbeatConn  = nil,
		aimStartTime   = aimStartTime,
		target         = target,
	}

	-- ── Heartbeat: keep crosshair & laser tracking the target ──
	local conn
	conn = RunService.Heartbeat:Connect(function()
		-- If tower or target is gone, clean up
		if not tower or not tower.Parent
			or not target or not target.Parent
			or not hhVFX[tower]
		then
			if hhVFX[tower] then clearHHVFX(tower) end
			return
		end

		local vfx = hhVFX[tower]
		if not vfx then conn:Disconnect(); return end

		local targetPP = target.PrimaryPart
		if not targetPP then return end

		-- Chest = PrimaryPart position raised slightly
		local chestPos = targetPP.Position + Vector3.new(0, 0.6, 0)

		-- Position crosshair parts (face the camera via flat CFrames)
		hBar.CFrame = CFrame.new(chestPos)
		vBar.CFrame = CFrame.new(chestPos)
		dot.CFrame  = CFrame.new(chestPos)

		-- Pulse alpha to make it blink
		local elapsed = tick() - vfx.aimStartTime
		local blink   = 0.25 + 0.25 * math.abs(math.sin(elapsed * math.pi * 3))
		hBar.Transparency = blink
		vBar.Transparency = blink
		dot.Transparency  = blink

		-- Laser: stretch from barrel/torso to chest
		local barrel  = tower:FindFirstChild("GunBarrel", true)
		local torso   = tower.PrimaryPart
		local fromPos = (barrel and barrel.WorldPosition) or (torso and torso.Position) or chestPos

		local midPos  = (fromPos + chestPos) * 0.5
		local laserLen = (chestPos - fromPos).Magnitude
		if laserLen > 0.1 then
			laser.Size   = Vector3.new(0.04, 0.04, laserLen)
			laser.CFrame = CFrame.new(midPos, chestPos)
		end

		-- Pulse laser transparency similarly
		laser.Transparency = 0.2 + 0.4 * math.abs(math.sin(elapsed * math.pi * 3))
	end)

	hhVFX[tower].heartbeatConn = conn

	return aimStartTime
end

-- ============================================================
-- VFX – BULLET WITH TRAIL
-- ============================================================

function Deadeye.SpawnBullet(fromPos: Vector3, toPos: Vector3, isEnhanced: boolean?)
	local dir  = toPos - fromPos
	local dist = dir.Magnitude
	if dist < 0.1 then return end
	dir = dir.Unit

	local bullet = Instance.new("Part")
	bullet.Name        = "DeadeyeBullet"
	bullet.Size        = Vector3.new(0.1, 0.1, 0.55)
	bullet.Color       = isEnhanced
		and Color3.fromRGB(255, 210, 60)
		or  Color3.fromRGB(255, 245, 200)
	bullet.Material    = Enum.Material.Neon
	bullet.Anchored    = true
	bullet.CanCollide  = false
	bullet.CastShadow  = false
	bullet.CFrame      = CFrame.new(fromPos, toPos)
	bullet.Parent      = Workspace

	local attFront = Instance.new("Attachment")
	attFront.Position = Vector3.new(0, 0,  0.28)
	attFront.Parent   = bullet

	local attBack = Instance.new("Attachment")
	attBack.Position  = Vector3.new(0, 0, -0.28)
	attBack.Parent    = bullet

	local trail = Instance.new("Trail")
	trail.Attachment0 = attFront
	trail.Attachment1 = attBack
	trail.Lifetime    = 0.07
	trail.MinLength   = 0
	trail.FaceCamera  = true
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,
			isEnhanced and Color3.fromRGB(255, 225, 80) or Color3.fromRGB(255, 255, 220)),
		ColorSequenceKeypoint.new(0.45,
			isEnhanced and Color3.fromRGB(255, 140, 20) or Color3.fromRGB(180, 200, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 80, 80)),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.0),
		NumberSequenceKeypoint.new(0.6, 0.4),
		NumberSequenceKeypoint.new(1,   1.0),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   1),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1,   0),
	})
	trail.Parent = bullet

	local travelTime = dist / Deadeye.BULLET_SPEED
	local tween = TweenService:Create(
		bullet,
		TweenInfo.new(travelTime, Enum.EasingStyle.Linear),
		{ CFrame = CFrame.new(toPos, toPos + dir) }
	)
	tween:Play()
	tween.Completed:Connect(function()
		task.delay(0.12, function()
			if bullet and bullet.Parent then bullet:Destroy() end
		end)
	end)
end

-- ============================================================
-- VFX – HIT PARTICLES
-- ============================================================

function Deadeye.SpawnHitParticles(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name        = "HitVFXAnchor"
	anchor.Size        = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored    = true
	anchor.CanCollide  = false
	anchor.Position    = position
	anchor.Parent      = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	local flash = Instance.new("ParticleEmitter")
	flash.Color       = ColorSequence.new(Color3.fromRGB(255, 235, 130))
	flash.Size        = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.7),
		NumberSequenceKeypoint.new(0.3, 0.3),
		NumberSequenceKeypoint.new(1,   0),
	})
	flash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	flash.Lifetime    = NumberRange.new(0.04, 0.1)
	flash.Speed       = NumberRange.new(6, 20)
	flash.SpreadAngle = Vector2.new(180, 180)
	flash.Rate        = 0
	flash.Parent      = att
	flash:Emit(5)

	local splatter = Instance.new("ParticleEmitter")
	splatter.Color       = ColorSequence.new(color)
	splatter.Size        = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.35),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1,   0),
	})
	splatter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	splatter.Lifetime    = NumberRange.new(0.15, 0.3)
	splatter.Speed       = NumberRange.new(3, 10)
	splatter.SpreadAngle = Vector2.new(180, 90)
	splatter.Acceleration = Vector3.new(0, -15, 0)
	splatter.Rate        = 0
	splatter.Parent      = att
	splatter:Emit(8)

	task.delay(0.5, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- ============================================================
-- MODEL CREATION
-- ============================================================

function Deadeye.CreateModel(position: Vector3, TowerStats: any): Model?
	local template = TowerStats.Templates["Deadeye"]
	if not template then return nil end

	local towerModels = ServerStorage:FindFirstChild("TowerModels")
	local templateModel = towerModels and towerModels:FindFirstChild("Deadeye")
	if not templateModel then
		warn("[Deadeye] ServerStorage.TowerModels.Deadeye not found")
		return nil
	end

	local model = templateModel:Clone()
	model.Name = "Deadeye"

	if model.PrimaryPart then
		model.PrimaryPart.Anchored = true
	end

	local rangeStuds = template.RNG

	local circle = Instance.new("Part")
	circle.Name        = "RangeCircle"
	circle.Shape       = Enum.PartType.Cylinder
	circle.Size        = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored    = true
	circle.CanCollide  = false
	circle.Color       = Color3.fromRGB(30, 100, 200)
	circle.Transparency = 1
	circle.Material    = Enum.Material.SmoothPlastic
	circle.Parent      = model

	model:SetAttribute("ATK",              template.ATK)
	model:SetAttribute("AP",               template.AP)
	model:SetAttribute("ATK_SPD",          template.ATK_SPD)
	model:SetAttribute("RNG",              rangeStuds)
	model:SetAttribute("HP",               template.HP)
	model:SetAttribute("MaxHP",            template.HP)
	model:SetAttribute("MOVE_SPD",         template.MOVE_SPD)
	model:SetAttribute("DamageMulti",      template.DamageMulti or 1.0)
	model:SetAttribute("AttackType",       template.AttackType  or "Ranged")
	model:SetAttribute("State",            "Idle")
	model:SetAttribute("Owner",            "")
	model:SetAttribute("TowerType",        "Deadeye")
	model:SetAttribute("BasicAttackCount", 0)

	model:PivotTo(CFrame.new(position))
	circle.CFrame = CFrame.new(position.X, position.Y - 2.5, position.Z)
		* CFrame.Angles(0, 0, math.rad(90))

	return model
end

-- ============================================================
-- MOTOR6D BASE STORAGE
-- ============================================================

function Deadeye.StoreBaseC0s(model: Model)
	if baseC0s[model] then return end
	local torso = model.PrimaryPart
	if not torso then return end
	local stored = {}
	for _, n in ipairs({"Neck","LeftShoulder","RightShoulder","LeftHip","RightHip"}) do
		local motor = torso:FindFirstChild(n)
		if motor then stored[n] = motor.C0 end
	end
	baseC0s[model] = stored
end

function Deadeye.RestoreBaseC0s(model: Model)
	local stored = baseC0s[model]
	if not stored then return end
	local torso = model.PrimaryPart
	if not torso then return end
	for n, c0 in pairs(stored) do
		local motor = torso:FindFirstChild(n)
		if motor then motor.C0 = c0 end
	end
end

-- ============================================================
-- WALK ANIMATION
-- ============================================================

function Deadeye.StartWalk(model: Model)
	if walkTracks[model] then return end

	local st = getAnimState(model)
	safeStop(st.idleTrack,  0.15)
	safeStop(st.raiseTrack, 0.1)
	safeStop(st.shootTrack, 0.1)
	safeStop(st.lowerTrack, 0.15)
	st.gunState = "walking"

	-- Cancel any in-progress Headhunter aim when walking
	clearHHVFX(model)

	local animator = getOrCreateAnimator(model)
	if not animator then return end

	local track = loadAndPlay(animator, WALK_ANIM_ID, true, Enum.AnimationPriority.Movement, 0.2)
	if track then
		walkTracks[model] = track
	end
end

function Deadeye.StopWalk(model: Model)
	local track = walkTracks[model]
	if track then
		safeStop(track, 0.2)
		task.delay(0.25, function() safeDestroy(track) end)
		walkTracks[model] = nil
	end
	Deadeye.RestoreBaseC0s(model)

	local st = animState[model]
	if st then
		st.gunState = "idle"
	end
end

-- ============================================================
-- INTERNAL ANIMATION STATE MACHINE
-- ============================================================

local function playIdle(tower: Model, st)
	local animator = getOrCreateAnimator(tower)
	if not animator then return end
	safeDestroy(st.idleTrack)
	local track = loadAndPlay(animator, IDLE_ANIM_ID, true, Enum.AnimationPriority.Idle, 0.2)
	st.idleTrack = track
end

local function triggerGunRaise(tower: Model, st)
	if st.gunState == "raising"    or
	   st.gunState == "raised"     or
	   st.gunState == "shoot_hold" then
		return
	end

	st.gunState = "raising"

	safeStop(st.idleTrack, 0.12)
	safeStop(st.lowerTrack, 0.1)

	local animator = getOrCreateAnimator(tower)
	if not animator then
		st.gunState        = "shoot_hold"
		st.readyToFireTime = tick() + Deadeye.GUN_RAISE_DELAY
		st.lastShotTime    = tick()
		return
	end

	safeDestroy(st.raiseTrack)
	local raiseTrack = loadAndPlay(animator, RAISE_ANIM_ID, false, Enum.AnimationPriority.Action, 0.12)
	if not raiseTrack then
		st.gunState        = "shoot_hold"
		st.readyToFireTime = tick() + Deadeye.GUN_RAISE_DELAY
		st.lastShotTime    = tick()
		return
	end
	st.raiseTrack = raiseTrack

	task.spawn(function()
		raiseTrack.Stopped:Wait()

		if not tower or not tower.Parent then return end
		if st.gunState ~= "raising" then return end

		st.gunState        = "raised"
		st.readyToFireTime = tick() + Deadeye.GUN_RAISE_DELAY
		st.lastShotTime    = tick()

		task.wait(Deadeye.GUN_RAISE_DELAY)

		if not tower or not tower.Parent then return end
		if st.gunState ~= "raised" then return end

		st.gunState     = "shoot_hold"
		st.lastShotTime = tick()
	end)
end

local function triggerGunLower(tower: Model, st)
	if st.gunState == "lowering" or
	   st.gunState == "idle"     or
	   st.gunState == "walking"  then
		return
	end

	st.gunState = "lowering"
	clearHHVFX(tower)

	safeStop(st.shootTrack, 0.12)
	st.shootTrack = nil

	local animator = getOrCreateAnimator(tower)
	if not animator then
		st.gunState = "idle"
		playIdle(tower, st)
		return
	end

	safeDestroy(st.lowerTrack)
	local lowerTrack = loadAndPlay(animator, LOWER_ANIM_ID, false, Enum.AnimationPriority.Action, 0.12)
	if not lowerTrack then
		st.gunState = "idle"
		playIdle(tower, st)
		return
	end
	st.lowerTrack = lowerTrack

	task.spawn(function()
		lowerTrack.Stopped:Wait()
		if not tower or not tower.Parent then return end
		if st.gunState ~= "lowering" then return end
		st.gunState = "idle"
		playIdle(tower, st)
	end)
end

-- Play the shoot animation from frame 0 on every shot.
local function playShootBrief(tower: Model, st)
	local animator = getOrCreateAnimator(tower)
	if not animator then return end

	if st.shootTrack then
		safeStop(st.shootTrack, 0)
		safeDestroy(st.shootTrack)
		st.shootTrack = nil
	end

	local ok, track = pcall(function()
		local obj = Instance.new("Animation")
		obj.AnimationId = SHOOT_ANIM_ID
		local t = animator:LoadAnimation(obj)
		obj:Destroy()
		t.Looped   = false
		t.Priority = Enum.AnimationPriority.Action
		t:Play(0.05)
		return t
	end)

	if ok and track then
		st.shootTrack = track
	end
end

-- ============================================================
-- TARGETING HELPER
-- ============================================================

local function findHighestMaxHPEnemy(pos: Vector3, range: number, folder: Folder): Model?
	local best, bestMax = nil, -math.huge
	for _, e in ipairs(folder:GetChildren()) do
		if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
			local d = (e.PrimaryPart.Position - pos).Magnitude
			if d <= range then
				local mx = e:GetAttribute("MaxHP") or e:GetAttribute("HP") or 0
				if mx > bestMax then
					bestMax = mx
					best    = e
				end
			end
		end
	end
	return best
end

-- ============================================================
-- PUBLIC – ANIMATION INTERFACE
-- ============================================================

function Deadeye.InitTower(tower: Model)
	local st = getAnimState(tower)
	playIdle(tower, st)
end

function Deadeye.IsReadyToFire(tower: Model): boolean
	local st = animState[tower]
	if not st then return false end
	if st.gunState ~= "shoot_hold" then return false end
	if tick() < st.readyToFireTime then return false end
	return true
end

--[[
	IsReadyToFireEnhanced: same as IsReadyToFire but also checks that the
	Headhunter aim delay (HEADHUNTER_AIM_DELAY) has elapsed since the VFX
	was first shown.  Returns true only when both conditions are met.
]]
function Deadeye.IsReadyToFireEnhanced(tower: Model): boolean
	if not Deadeye.IsReadyToFire(tower) then return false end
	local vfx = hhVFX[tower]
	if not vfx then return false end
	return (tick() - vfx.aimStartTime) >= Deadeye.HEADHUNTER_AIM_DELAY
end

function Deadeye.UpdateCombatState(tower: Model, hasTarget: boolean, target: Model?)
	local st = getAnimState(tower)
	if not st then return end

	-- Gun-lower timer
	if (st.gunState == "shoot_hold" or st.gunState == "raised") and
	   (tick() - st.lastShotTime) >= Deadeye.GUN_LOWER_DELAY
	then
		triggerGunLower(tower, st)
		return
	end

	if hasTarget and target then
		if st.gunState == "idle" then
			triggerGunRaise(tower, st)
		end

		if st.gunState == "raising" or st.gunState == "raised" or st.gunState == "shoot_hold" then
			local torso       = tower.PrimaryPart
			local targetTorso = target.PrimaryPart
			if torso and targetTorso then
				local flatDir = Vector3.new(
					targetTorso.Position.X - torso.Position.X,
					0,
					targetTorso.Position.Z - torso.Position.Z
				)
				if flatDir.Magnitude > 0.1 then
					torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
				end
			end
		end
	else
		-- No target: clear any lingering Headhunter aim VFX
		clearHHVFX(tower)
		if st.gunState == "idle" then
			if not (st.idleTrack and st.idleTrack.IsPlaying) then
				playIdle(tower, st)
			end
		end
	end
end

-- ============================================================
-- PUBLIC – HEADHUNTER AIM VFX CONTROL
-- ============================================================

--[[
	Called by TowerManager every heartbeat when a Headhunter shot is pending
	(gun is shoot_hold, basic count is maxed, cooldown is satisfied).
	Shows/maintains the crosshair + laser VFX on the intended target.
	Returns true once the aim delay has elapsed and the shot can fire.
]]
function Deadeye.TickHeadhunterAim(tower: Model, target: Model): boolean
	local vfx = hhVFX[tower]

	-- If we have no VFX yet, or the target changed, restart the aim timer
	if not vfx or vfx.target ~= target then
		showHHVFX(tower, target)
		vfx = hhVFX[tower]
	end

	if not vfx then return false end
	return (tick() - vfx.aimStartTime) >= Deadeye.HEADHUNTER_AIM_DELAY
end

-- ============================================================
-- PUBLIC – ATTACK
-- ============================================================

function Deadeye.DoAttack(tower: Model, target: Model, enemiesFolder: Folder?): boolean
	local st = getAnimState(tower)

	local atk   = tower:GetAttribute("ATK")   or 12
	local ap    = tower:GetAttribute("AP")     or atk
	local multi = tower:GetAttribute("DamageMulti") or 1.0
	local count = tower:GetAttribute("BasicAttackCount") or 0

	local isEnhanced = (count >= Deadeye.ENHANCE_AFTER)

	-- Headhunter: retarget to highest-MaxHP enemy in range
	local actualTarget = target
	if isEnhanced and enemiesFolder then
		local torso = tower.PrimaryPart
		if torso then
			local range   = tower:GetAttribute("RNG") or 22
			local highest = findHighestMaxHPEnemy(torso.Position, range, enemiesFolder)
			if highest then actualTarget = highest end
		end
	end

	if not actualTarget or not actualTarget.Parent or not actualTarget.PrimaryPart then
		clearHHVFX(tower)
		return false
	end

	-- Face the actual target
	local torso = tower.PrimaryPart
	if torso and actualTarget.PrimaryPart then
		local flatDir = Vector3.new(
			actualTarget.PrimaryPart.Position.X - torso.Position.X,
			0,
			actualTarget.PrimaryPart.Position.Z - torso.Position.Z
		)
		if flatDir.Magnitude > 0.1 then
			torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
		end
	end

	-- Capture bullet position BEFORE damage (enemy may be destroyed below)
	local bulletToPos = actualTarget.PrimaryPart and actualTarget.PrimaryPart.Position
		or (torso and (torso.Position + torso.CFrame.LookVector * 5))

	-- ── Clear Headhunter aim VFX right as the shot fires ──
	if isEnhanced then
		clearHHVFX(tower)
	end

	-- ── Damage ──
	if isEnhanced then
		tower:SetAttribute("BasicAttackCount", 0)
		local damage = ap * multi
		local hp     = actualTarget:GetAttribute("HP")    or 0
		local maxHP  = actualTarget:GetAttribute("MaxHP") or hp
		local newHP  = hp - damage

		if hp < maxHP * Deadeye.EXECUTE_HP_THRESHOLD and
		   hp <= ap * Deadeye.EXECUTE_DMG_CAP_MULT
		then
			newHP = 0
		end

		actualTarget:SetAttribute("HP", newHP)
		if newHP <= 0 and actualTarget.Parent then
			actualTarget:Destroy()
		end
	else
		tower:SetAttribute("BasicAttackCount", count + 1)
		local damage = atk * multi
		local hp     = actualTarget:GetAttribute("HP") or 0
		local newHP  = hp - damage
		actualTarget:SetAttribute("HP", newHP)
		if newHP <= 0 and actualTarget.Parent then
			actualTarget:Destroy()
		end
	end

	-- ── VFX ──
	if bulletToPos then
		local hitColor = isEnhanced
			and Color3.fromRGB(255, 200, 50)
			or  Color3.fromRGB(210, 210, 255)
		Deadeye.SpawnHitParticles(bulletToPos, hitColor)
	end

	if torso and bulletToPos then
		local barrel  = tower:FindFirstChild("GunBarrel", true)
		local fromPos = barrel and barrel.WorldPosition or torso.Position
		Deadeye.SpawnBullet(fromPos, bulletToPos, isEnhanced)
	end

	-- ── Shoot animation & timer ──
	playShootBrief(tower, st)
	st.lastShotTime = tick()

	return true
end

-- ============================================================
-- CLEANUP
-- ============================================================

function Deadeye.CleanupTower(tower: Model)
	clearHHVFX(tower)

	local st = animState[tower]
	if st then
		safeDestroy(st.idleTrack)
		safeDestroy(st.raiseTrack)
		safeDestroy(st.shootTrack)
		safeDestroy(st.lowerTrack)
		animState[tower] = nil
	end

	baseC0s[tower] = nil

	local wt = walkTracks[tower]
	if wt then
		pcall(function() wt:Stop(0); wt:Destroy() end)
		walkTracks[tower] = nil
	end
end

return Deadeye