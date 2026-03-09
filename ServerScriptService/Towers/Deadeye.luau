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

	Animation state machine
	  idle  →  raising  →  shoot_hold  →  (lowering after 3 s no shot)  →  idle
	  Any state  →  walking  (on player-initiated move)
	  walking  →  idle  (on arrival)

	Animations
	  Idle      : 130403916615858  (looped)
	  Walk      : rbxassetid://73323871613223   (same asset as Warrior, looped)
	  Gun Raise : 75900515991486   (one-shot, Action priority)
	  Shoot     : 108396781520756  (frozen at frame 0; advanced on each shot)
	  Gun Lower : 107226036750887  (one-shot, Action priority)
]]

local TweenService  = game:GetService("TweenService")
local Workspace     = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")

local Deadeye = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

Deadeye.ENHANCE_AFTER        = 2      -- basic attacks before enhanced fires
Deadeye.EXECUTE_HP_THRESHOLD = 0.25   -- execute if enemy HP < 25 % of MaxHP
Deadeye.EXECUTE_DMG_CAP_MULT = 2.0    -- execute only if enemy HP <= 2 × AP
Deadeye.GUN_RAISE_DELAY      = 0.15   -- seconds after raise finishes before first shot
Deadeye.GUN_LOWER_DELAY      = 3.0    -- seconds without a shot → lower gun
Deadeye.BULLET_SPEED         = 180    -- studs / second

-- ====== ANIMATION IDs ======
local IDLE_ANIM_ID  = "rbxassetid://130403916615858"
local WALK_ANIM_ID  = "rbxassetid://73323871613223"   -- shared with Warrior
local RAISE_ANIM_ID = "rbxassetid://75900515991486"
local SHOOT_ANIM_ID = "rbxassetid://108396781520756"
local LOWER_ANIM_ID = "rbxassetid://107226036750887"

-- ============================================================
-- INTERNAL STATE  (module-level tables, keyed by tower Model)
-- ============================================================

local animState  = {}  -- tower → animation-state record
local baseC0s    = {}  -- tower → stored Motor6D C0 values
local walkTracks = {}  -- tower → active walk AnimationTrack

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

-- Safe stop with optional blend
local function safeStop(track, blendTime: number?)
	if track then
		pcall(function()
			if track.IsPlaying then
				track:Stop(blendTime or 0.1)
			end
		end)
	end
end

-- Stop + destroy
local function safeDestroy(track)
	if track then
		pcall(function()
			if track.IsPlaying then track:Stop(0) end
			track:Destroy()
		end)
	end
end

-- Load, configure, and immediately play an animation track.
-- Returns the track, or nil on failure.
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

-- Return (or lazily create) the per-tower animation state record.
local function getAnimState(tower: Model)
	if not animState[tower] then
		animState[tower] = {
			-- Current animation phase:
			--   "idle" | "raising" | "raised" | "shoot_hold" | "lowering" | "walking"
			gunState     = "idle",

			-- Active track references
			idleTrack    = nil,
			raiseTrack   = nil,
			shootTrack   = nil,
			lowerTrack   = nil,

			-- Timing
			lastShotTime      = -math.huge,  -- never fired → always "long ago"
			readyToFireTime   = 0,           -- tick() after which shooting is allowed
		}
	end
	return animState[tower]
end

-- ============================================================
-- VFX – BULLET WITH TRAIL
-- ============================================================

--[[
	Spawns a bullet Part that travels from `fromPos` to `toPos`.
	A Trail is attached for a glowing smoke-trace effect.
	`isEnhanced` → gold colour for Headhunter shots.
]]
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

	-- Trail needs two Attachments on the bullet
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

	-- Smooth tween to destination so the trail renders cleanly
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

	-- Bright flash
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

	-- Impact splatter
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
-- MOTOR6D BASE STORAGE  (needed to restore pose after walk)
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
-- WALK ANIMATION  (public – called by TowerManager movement)
-- ============================================================

function Deadeye.StartWalk(model: Model)
	if walkTracks[model] then return end   -- already walking

	-- Stop all gun animations so walk can blend in cleanly
	local st = getAnimState(model)
	safeStop(st.idleTrack,  0.15)
	safeStop(st.raiseTrack, 0.1)
	safeStop(st.shootTrack, 0.1)
	safeStop(st.lowerTrack, 0.15)
	st.gunState = "walking"

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

	-- Return animation state to idle so the AI loop can trigger gun raise
	local st = animState[model]
	if st then
		st.gunState = "idle"
	end
end

-- ============================================================
-- INTERNAL ANIMATION STATE MACHINE
-- ============================================================

-- Play (or restart) the looped idle animation.
local function playIdle(tower: Model, st)
	local animator = getOrCreateAnimator(tower)
	if not animator then return end

	safeDestroy(st.idleTrack)
	local track = loadAndPlay(animator, IDLE_ANIM_ID, true, Enum.AnimationPriority.Idle, 0.2)
	st.idleTrack = track
end

-- Transition: idle → raising → (after anim) raised → (after delay) shoot_hold
local function triggerGunRaise(tower: Model, st)
	if st.gunState == "raising"    or
	   st.gunState == "raised"     or
	   st.gunState == "shoot_hold" then
		return   -- already mid-raise or raised
	end

	st.gunState = "raising"

	-- Fade out idle / lower tracks
	safeStop(st.idleTrack, 0.12)
	safeStop(st.lowerTrack, 0.1)

	local animator = getOrCreateAnimator(tower)
	if not animator then
		-- No animator: skip straight to shoot_hold
		st.gunState      = "shoot_hold"
		st.readyToFireTime = tick() + Deadeye.GUN_RAISE_DELAY
		st.lastShotTime    = tick()
		return
	end

	-- Destroy stale raise track, start fresh
	safeDestroy(st.raiseTrack)
	local raiseTrack = loadAndPlay(animator, RAISE_ANIM_ID, false, Enum.AnimationPriority.Action, 0.12)
	if not raiseTrack then
		st.gunState        = "shoot_hold"
		st.readyToFireTime = tick() + Deadeye.GUN_RAISE_DELAY
		st.lastShotTime    = tick()
		return
	end
	st.raiseTrack = raiseTrack

	-- Pre-load the shoot track now (frozen at frame 0) so it is instantly
	-- available when the raise animation finishes.
	safeDestroy(st.shootTrack)
	st.shootTrack = nil
	local ok, shootTrack = pcall(function()
		local obj = Instance.new("Animation")
		obj.AnimationId = SHOOT_ANIM_ID
		local t = animator:LoadAnimation(obj)
		obj:Destroy()
		t.Looped   = false
		t.Priority = Enum.AnimationPriority.Action
		return t
	end)
	if ok and shootTrack then
		st.shootTrack = shootTrack
	end

	-- Wait for raise to finish, then enter shoot_hold
	task.spawn(function()
		raiseTrack.Stopped:Wait()

		if not tower or not tower.Parent then return end
		if st.gunState ~= "raising" then return end   -- was interrupted (walk etc.)

		st.gunState        = "raised"
		st.readyToFireTime = tick() + Deadeye.GUN_RAISE_DELAY

		-- 0.15 s lock-on pause before entering shoot_hold
		task.wait(Deadeye.GUN_RAISE_DELAY)

		if not tower or not tower.Parent then return end
		if st.gunState ~= "raised" then return end

		st.gunState     = "shoot_hold"
		st.lastShotTime = tick()   -- start gun-lower countdown from now

		-- Freeze the shoot track at its first frame (the "aimed" pose)
		if st.shootTrack then
			pcall(function()
				st.shootTrack:Play(0.08)
				st.shootTrack:AdjustSpeed(0)
				st.shootTrack.TimePosition = 0
			end)
		end
	end)
end

-- Transition: shoot_hold → lowering → (after anim) idle
local function triggerGunLower(tower: Model, st)
	if st.gunState == "lowering" or
	   st.gunState == "idle"     or
	   st.gunState == "walking"  then
		return
	end

	st.gunState = "lowering"

	-- Fade out shoot track
	safeStop(st.shootTrack, 0.12)

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

-- Brief shoot animation on each fired shot: advance the frozen track for a
-- fraction of a second so the recoil is visible, then re-freeze at frame 0.
local function playShootBrief(tower: Model, st)
	if st.shootTrack then
		pcall(function()
			st.shootTrack.TimePosition = 0
			st.shootTrack:AdjustSpeed(1)
		end)
		task.delay(0.09, function()
			if st.shootTrack and tower and tower.Parent then
				pcall(function()
					st.shootTrack:AdjustSpeed(0)
					st.shootTrack.TimePosition = 0
				end)
			end
		end)
	else
		-- Fallback: play a fresh track for a single burst
		local animator = getOrCreateAnimator(tower)
		if not animator then return end
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
			task.delay(0.09, function()
				if track and tower and tower.Parent then
					pcall(function()
						track:AdjustSpeed(0)
						track.TimePosition = 0
					end)
				end
			end)
		end
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

-- Must be called once after placing a Deadeye tower.
function Deadeye.InitTower(tower: Model)
	local st = getAnimState(tower)
	playIdle(tower, st)
end

-- Returns true when the gun is raised, the 0.15 s delay has elapsed, and the
-- tower is ready to fire a shot.
function Deadeye.IsReadyToFire(tower: Model): boolean
	local st = animState[tower]
	if not st then return false end
	return st.gunState == "shoot_hold" and tick() >= st.readyToFireTime
end

-- Called every AI heartbeat.  Drives gun-raise / gun-lower transitions and
-- keeps the tower facing its current target.
function Deadeye.UpdateCombatState(tower: Model, hasTarget: boolean, target: Model?)
	local st = getAnimState(tower)
	if not st then return end

	-- ── Gun-lower timer: fires regardless of whether there is a target ──
	if (st.gunState == "shoot_hold" or st.gunState == "raised") and
	   (tick() - st.lastShotTime) >= Deadeye.GUN_LOWER_DELAY
	then
		triggerGunLower(tower, st)
		return
	end

	if hasTarget and target then
		-- Trigger gun raise when idle (after lower or on fresh acquisition)
		if st.gunState == "idle" then
			triggerGunRaise(tower, st)
		end

		-- While raised / shoot_hold: keep facing the target
		if st.gunState == "raised" or st.gunState == "shoot_hold" then
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
		-- No target → ensure idle animation is actually playing
		if st.gunState == "idle" then
			if not (st.idleTrack and st.idleTrack.IsPlaying) then
				playIdle(tower, st)
			end
		end
	end
end

-- ============================================================
-- PUBLIC – ATTACK
-- ============================================================

--[[
	Execute one attack cycle.  Handles:
	  - Basic  (Revolver): 1× ATK damage to `target`.
	  - Enhanced (Headhunter): 1× AP to the highest-MaxHP enemy in range;
	    execute-threshold check.

	Returns true if an attack actually happened.
]]
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

	-- ── Damage ──
	if isEnhanced then
		-- Headhunter
		tower:SetAttribute("BasicAttackCount", 0)
		local damage = ap * multi
		local hp     = actualTarget:GetAttribute("HP")    or 0
		local maxHP  = actualTarget:GetAttribute("MaxHP") or hp
		local newHP  = hp - damage

		-- Execute check
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
		-- Revolver
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
	if actualTarget.PrimaryPart and actualTarget.Parent then
		local hitColor = isEnhanced
			and Color3.fromRGB(255, 200, 50)    -- gold – Headhunter
			or  Color3.fromRGB(210, 210, 255)   -- pale-blue – Revolver
		Deadeye.SpawnHitParticles(actualTarget.PrimaryPart.Position, hitColor)
	end

	-- Bullet: fired from gun barrel (or torso) toward the impact point
	if torso then
		local barrel  = tower:FindFirstChild("GunBarrel", true)
		local fromPos = barrel and barrel.WorldPosition or torso.Position
		local toPos   = (actualTarget.PrimaryPart and actualTarget.PrimaryPart.Position)
		                or (torso.Position + torso.CFrame.LookVector * 5)
		Deadeye.SpawnBullet(fromPos, toPos, isEnhanced)
	end

	-- ── Update animation & timer ──
	playShootBrief(tower, st)
	st.lastShotTime = tick()

	return true
end

-- ============================================================
-- CLEANUP  (call when the tower is removed)
-- ============================================================

function Deadeye.CleanupTower(tower: Model)
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
