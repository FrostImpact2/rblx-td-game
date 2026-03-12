--[[
	Wanderer (ModuleScript)
	Place in ServerScriptService/Towers/

	Global Support | 3/7 Difficulty

	Passive: MQ-9 Combat Drone
	  On Placement, summon a Combat Drone at the tower's location.
	  While the Drone is active, Wanderer itself cannot move.
	  Any right-click move instead teleports/moves the Drone (clamped to
	  Wanderer's RNG). Drone retains Wanderer's base stats. Drone cannot be
	  targeted by enemies but still takes AoE damage. If destroyed, the Drone
	  auto-respawns after 30 s.

	Basic Attack: Heavy Rounds (Drone fires)
	  Bursts of 2 projectiles, each dealing 0.5× ATK (1.0× total per trigger).

	Enhanced Basic Attack: High Caliber (Wanderer fires, only during Reconnaissance)
	  Single high-calibre sniper shot dealing 1.5× ATK.

	Move Skill: Suppressing Fire
	  On Drone move, spray a 5 s damage field at the destination (0.6× ATK/s,
	  7-stud radius). 15 s cooldown.

	Strike Skill: Reconnaissance
	  Drone pulses green light for 6 s. During this window Wanderer targets
	  enemies in the Drone's range and fires High Caliber instead of Heavy Rounds.
	  20 s cooldown.

	Animations (Wanderer character):
	  Idle            : 85934873494293   (looped)
	  Walk (standard) : 73323871613223   (looped – shared with other towers)
	  Gun Raise       : 132977372237137  (one-shot, Action4)
	  Gun Lower       : 111705097856404  (one-shot, Action4)
	  Gun Shoot       : 71817725226674   (one-shot, Action4)
	  Gun Idle        : 83963194498841   (looped,  Action4 – raised aim pose)
	  Deploy          : 113959546287676  (one-shot, Action4 – on placement)
	  Command         : 84131929029062   (one-shot, Action2 – on drone move)
	  Summon Drone    : 134583641960643  (one-shot, Action3 – when drone spawns)

	────────────────────────────────────────────────────────────
	ROOT CAUSE ANALYSIS (3 bugs, all silent – no Output errors):

	BUG 1 – Gun raise hung forever → IsReadyToFire never true → no shooting.
	  On a server Script, AnimationTrack.Stopped may never fire if the asset
	  hasn't streamed in or the rig has no Humanoid.  triggerGunRaise was stuck
	  in task.spawn waiting for Stopped:Wait(), leaving gunState = "raising"
	  permanently.  Fix: a GUN_RAISE_MAX_WAIT task.delay fallback forces
	  gunState to "shoot_hold" so the attack loop is never permanently blocked.

	BUG 2 – Gun lowered mid-combat → re-blocked IsReadyToFire.
	  UpdateCombatState ran the GUN_LOWER_DELAY check unconditionally, so the
	  gun started lowering even while a live target was present and the raise/
	  lower cycle repeated without ever reaching DoAttack.
	  Fix: gun-lower only triggers when hasTarget = false.

	BUG 3 – Previous attempted fix made IsReadyToFire always return false.
	  That shifted all attack logic to an internal Heartbeat that guessed the
	  enemies folder name.  Wrong folder name = silent no-op.
	  Fix: revert to the TowerManager-driven path (already correct) and remove
	  the redundant internal attack Heartbeat entirely.
	────────────────────────────────────────────────────────────
]]

local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ServerStorage     = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local Wanderer = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

Wanderer.GUN_RAISE_DELAY     = 0.2   -- seconds after raise before first shot
Wanderer.GUN_LOWER_DELAY     = 3.0   -- seconds without a shot (no target) → lower gun
Wanderer.GUN_RAISE_MAX_WAIT  = 2.0   -- FIX BUG 1: max seconds to wait for raise Stopped

Wanderer.HEAVY_ROUNDS_MULTI  = 0.5   -- damage per shot (× 2 shots per attack)
Wanderer.HIGH_CALIBER_MULTI  = 1.5   -- damage for enhanced High Caliber shot

Wanderer.SUPPRESS_COOLDOWN   = 15    -- seconds between Suppressing Fire triggers
Wanderer.SUPPRESS_DURATION   = 5     -- seconds the AoE lasts
Wanderer.SUPPRESS_RADIUS     = 7     -- studs radius
Wanderer.SUPPRESS_DPS_MULTI  = 0.6   -- ATK multiplier per second

Wanderer.RECON_DURATION      = 6     -- seconds Reconnaissance lasts
Wanderer.RECON_COOLDOWN      = 20    -- seconds cooldown

Wanderer.DRONE_RESPAWN_TIME  = 30    -- seconds until drone respawns after destruction
Wanderer.DRONE_MOVE_SPEED    = 20    -- studs / second drone travel speed
Wanderer.BULLET_SPEED        = 200   -- studs / second bullet travel speed

-- ====== ANIMATION IDs ======
local IDLE_ANIM_ID     = "rbxassetid://85934873494293"
local WALK_ANIM_ID     = "rbxassetid://73323871613223"
local RAISE_ANIM_ID    = "rbxassetid://132977372237137"
local LOWER_ANIM_ID    = "rbxassetid://111705097856404"
local SHOOT_ANIM_ID    = "rbxassetid://71817725226674"
local GUN_IDLE_ANIM_ID = "rbxassetid://83963194498841"
local DEPLOY_ANIM_ID   = "rbxassetid://113959546287676"
local COMMAND_ANIM_ID  = "rbxassetid://84131929029062"
local SUMMON_ANIM_ID   = "rbxassetid://134583641960643"

-- ============================================================
-- INTERNAL STATE  (per-tower tables, keyed by tower Model)
-- ============================================================

local animState           = {}
local baseC0s             = {}
local walkTracks          = {}

local droneModels         = {}
local droneAlive          = {}
local droneRespawnAt      = {}
local activeDroneMovements= {}

local reconActive         = {}
local reconEndAt          = {}
local reconCooldownEnd    = {}

local suppressCooldownEnd = {}
local suppressData        = {}

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================

local function getOrCreateAnimator(towerModel: Model): Animator?
	local humanoid = towerModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local a = humanoid:FindFirstChildOfClass("Animator")
		if not a then a = Instance.new("Animator"); a.Parent = humanoid end
		return a
	end
	local animCtrl = towerModel:FindFirstChildOfClass("AnimationController")
	if animCtrl then
		local a = animCtrl:FindFirstChildOfClass("Animator")
		if not a then a = Instance.new("Animator"); a.Parent = animCtrl end
		return a
	end
	warn("[Wanderer] No Humanoid or AnimationController found – cannot animate")
	return nil
end

local function safeStop(track, blendTime: number?)
	if track then pcall(function() if track.IsPlaying then track:Stop(blendTime or 0.1) end end) end
end

local function safeDestroy(track)
	if track then pcall(function() if track.IsPlaying then track:Stop(0) end; track:Destroy() end) end
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
		t.Looped = looped; t.Priority = priority
		t:Play(blendTime or 0.1)
		return t
	end)
	if ok and result then return result end
	return nil
end

local function getAnimState(tower: Model)
	if not animState[tower] then
		animState[tower] = {
			gunState        = "idle",
			idleTrack       = nil,
			raiseTrack      = nil,
			gunIdleTrack    = nil,
			shootTrack      = nil,
			lowerTrack      = nil,
			commandTrack    = nil,
			reloading       = false,
			lastShotTime    = -math.huge,
			readyToFireTime = 0,
		}
	end
	return animState[tower]
end

-- ============================================================
-- DRONE CREATION HELPER
-- ============================================================

local function buildDroneModel(position: Vector3): Model
	local towerModels = ServerStorage:FindFirstChild("TowerModels")
	local template    = towerModels and towerModels:FindFirstChild("Drone")
	if template then
		local m = template:Clone()
		m.Name = "Drone"
		for _, desc in ipairs(m:GetDescendants()) do
			if desc:IsA("BasePart") then desc.Anchored = true; desc.CanCollide = false end
		end
		if not m.PrimaryPart then m.PrimaryPart = m:FindFirstChildOfClass("BasePart") end
		m:PivotTo(CFrame.new(position))
		return m
	end

	local model = Instance.new("Model"); model.Name = "Drone"
	local grey  = Color3.fromRGB(55, 58, 65)
	local dark  = Color3.fromRGB(35, 36, 42)

	local function part(name, size, color, cf, shape)
		local p = Instance.new("Part")
		p.Name = name; p.Size = size; p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true; p.CanCollide = false; p.CastShadow = false
		p.CFrame = cf; p.Parent = model
		if shape then p.Shape = shape end
		return p
	end

	local body = part("Body",   Vector3.new(0.8, 0.3, 2.2),  grey,  CFrame.new(position))
	model.PrimaryPart = body
	part("Wing",   Vector3.new(3.6, 0.12, 0.9), grey,  CFrame.new(position + Vector3.new(0,0,0.1)))
	part("Tail",   Vector3.new(0.12,0.6, 0.6),  dark,  CFrame.new(position + Vector3.new(0,0.25,-0.9)))
	part("Camera", Vector3.new(0.35,0.35,0.35), Color3.fromRGB(20,20,25), CFrame.new(position + Vector3.new(0,-0.28,0.4)),  Enum.PartType.Ball)
	local eng = part("Engine", Vector3.new(0.22,0.4,0.4), Color3.fromRGB(255,130,20),
		CFrame.new(position + Vector3.new(0,0,-1.15)) * CFrame.Angles(0,0,math.rad(90)), Enum.PartType.Cylinder)
	eng.Material = Enum.Material.Neon

	return model
end

-- ============================================================
-- DRONE MANAGEMENT
-- ============================================================

local function spawnDrone(tower: Model)
	local torso = tower.PrimaryPart
	if not torso then return end

	local existing = droneModels[tower]
	if existing and existing.Parent then existing:Destroy() end

	local drone = buildDroneModel(torso.Position + Vector3.new(0, 3, 2))
	drone.Parent = tower
	droneModels[tower] = drone
	droneAlive[tower]  = true

	local st = getAnimState(tower)
	local animator = getOrCreateAnimator(tower)
	if animator then
		local t = loadAndPlay(animator, SUMMON_ANIM_ID, false, Enum.AnimationPriority.Action3, 0.1)
		if t then
			task.spawn(function()
				t.Stopped:Wait()
				if tower and tower.Parent and st.gunState ~= "walking" then st.gunState = "idle" end
			end)
		end
	end

	local dp = drone.PrimaryPart
	if dp then
		local light = Instance.new("PointLight")
		light.Brightness = 2; light.Color = Color3.fromRGB(80,230,100); light.Range = 8
		light.Parent = dp
		TweenService:Create(light, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true), {Brightness=0.2}):Play()
		task.delay(1.5, function() if light and light.Parent then light:Destroy() end end)
	end
end

local function destroyDrone(tower: Model)
	local drone = droneModels[tower]
	if drone and drone.Parent then
		local dp = drone.PrimaryPart
		if dp then
			local anchor = Instance.new("Part")
			anchor.Size = Vector3.new(0.1,0.1,0.1); anchor.Transparency = 1
			anchor.Anchored = true; anchor.CanCollide = false
			anchor.Position = dp.Position; anchor.Parent = Workspace
			local att = Instance.new("Attachment"); att.Parent = anchor
			local burst = Instance.new("ParticleEmitter")
			burst.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0,   Color3.fromRGB(255,220,80)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255,80,20)),
				ColorSequenceKeypoint.new(1,   Color3.fromRGB(60,40,30)),
			})
			burst.Size        = NumberSequence.new({NumberSequenceKeypoint.new(0,1.2),NumberSequenceKeypoint.new(1,0)})
			burst.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(1,1)})
			burst.Lifetime    = NumberRange.new(0.3,0.8); burst.Speed = NumberRange.new(5,18)
			burst.SpreadAngle = Vector2.new(180,180); burst.Rate = 0; burst.Parent = att
			burst:Emit(20)
			task.delay(1, function() if anchor and anchor.Parent then anchor:Destroy() end end)
		end
		drone:Destroy()
	end
	droneModels[tower] = nil; droneAlive[tower] = false
	droneRespawnAt[tower] = tick() + Wanderer.DRONE_RESPAWN_TIME
	if activeDroneMovements[tower] then
		activeDroneMovements[tower]:Disconnect(); activeDroneMovements[tower] = nil
	end
end

-- ============================================================
-- RECONNAISSANCE PULSE VFX
-- ============================================================

local reconPulseConnections = {}

local function startReconPulse(tower: Model)
	local ex = reconPulseConnections[tower]
	if ex then ex:Disconnect(); reconPulseConnections[tower] = nil end

	local drone = droneModels[tower]
	if not drone or not drone.PrimaryPart then return end

	local lastPulse = 0
	local conn
	conn = RunService.Heartbeat:Connect(function()
		local now = tick()
		if now - lastPulse < 0.5 then return end
		lastPulse = now

		if not reconActive[tower] then conn:Disconnect(); reconPulseConnections[tower] = nil; return end
		local dp = drone and drone.PrimaryPart
		if not dp or not dp.Parent then conn:Disconnect(); reconPulseConnections[tower] = nil; return end

		local range = tower:GetAttribute("RNG") or 35
		local ring = Instance.new("Part")
		ring.Name = "ReconPulse"; ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.1,0.5,0.5); ring.Color = Color3.fromRGB(60,220,80)
		ring.Material = Enum.Material.Neon; ring.Transparency = 0.2
		ring.Anchored = true; ring.CanCollide = false; ring.CastShadow = false
		ring.CFrame = CFrame.new(dp.Position) * CFrame.Angles(0,0,math.rad(90)); ring.Parent = Workspace
		TweenService:Create(ring, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{Size=Vector3.new(0.05, range*2, range*2), Transparency=1}):Play()
		task.delay(0.6, function() if ring and ring.Parent then ring:Destroy() end end)
	end)
	reconPulseConnections[tower] = conn
end

-- ============================================================
-- SUPPRESSING FIRE ZONE VFX
-- ============================================================

local function spawnSuppressingZone(position: Vector3): Part
	local zone = Instance.new("Part")
	zone.Name = "SuppressingFireZone"; zone.Shape = Enum.PartType.Cylinder
	zone.Size = Vector3.new(0.12, Wanderer.SUPPRESS_RADIUS*2, Wanderer.SUPPRESS_RADIUS*2)
	zone.Color = Color3.fromRGB(220,120,20); zone.Material = Enum.Material.Neon
	zone.Transparency = 0.55; zone.Anchored = true; zone.CanCollide = false; zone.CastShadow = false
	zone.CFrame = CFrame.new(position.X, position.Y-2.5, position.Z) * CFrame.Angles(0,0,math.rad(90))
	zone.Parent = Workspace

	local att = Instance.new("Attachment"); att.Position = Vector3.new(0,3,0); att.Parent = zone
	local rain = Instance.new("ParticleEmitter")
	rain.Color = ColorSequence.new(Color3.fromRGB(255,210,80))
	rain.Size  = NumberSequence.new({NumberSequenceKeypoint.new(0,0.12),NumberSequenceKeypoint.new(1,0)})
	rain.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.2),NumberSequenceKeypoint.new(1,1)})
	rain.Lifetime = NumberRange.new(0.3,0.6); rain.Speed = NumberRange.new(8,20)
	rain.SpreadAngle = Vector2.new(30,30); rain.Acceleration = Vector3.new(0,-30,0)
	rain.Rate = 60; rain.Parent = att
	return zone
end

-- ============================================================
-- ANIMATION STATE MACHINE
-- ============================================================

local function playIdle(tower: Model, st)
	local animator = getOrCreateAnimator(tower)
	if not animator then return end
	safeDestroy(st.idleTrack)
	st.idleTrack = loadAndPlay(animator, IDLE_ANIM_ID, true, Enum.AnimationPriority.Idle, 0.2)
end

-- ── FIX BUG 1 ─────────────────────────────────────────────────────────────
-- Added GUN_RAISE_MAX_WAIT timeout.  If the raise AnimationTrack's Stopped
-- event never fires (common on server-side rigs without a loaded Humanoid or
-- when the asset hasn't replicated), gunState was stuck at "raising" forever
-- and IsReadyToFire never returned true.  The timeout forces "shoot_hold"
-- within GUN_RAISE_MAX_WAIT seconds regardless.
-- ──────────────────────────────────────────────────────────────────────────
local function triggerGunRaise(tower: Model, st)
	if st.gunState == "raising" or st.gunState == "raised" or st.gunState == "shoot_hold" then return end

	st.gunState = "raising"
	safeStop(st.idleTrack, 0.12); safeStop(st.lowerTrack, 0.1); safeStop(st.commandTrack, 0.1)

	-- Advances state to shoot_hold; guarded by `raiseDone` so it runs exactly once.
	local raiseDone = false
	local function finishRaise()
		if raiseDone then return end
		raiseDone = true
		if not tower or not tower.Parent then return end
		if st.gunState ~= "raising" and st.gunState ~= "raised" then return end

		st.gunState        = "raised"
		st.readyToFireTime = tick() + Wanderer.GUN_RAISE_DELAY
		st.lastShotTime    = tick()

		task.wait(Wanderer.GUN_RAISE_DELAY)
		if not tower or not tower.Parent then return end
		if st.gunState ~= "raised" then return end

		st.gunState     = "shoot_hold"
		st.lastShotTime = tick()

		local animator2 = getOrCreateAnimator(tower)
		if animator2 then
			safeDestroy(st.gunIdleTrack)
			st.gunIdleTrack = loadAndPlay(animator2, GUN_IDLE_ANIM_ID, true, Enum.AnimationPriority.Action4, 0.1)
			safeDestroy(st.shootTrack); st.shootTrack = nil
			local ok, track = pcall(function()
				local obj = Instance.new("Animation"); obj.AnimationId = SHOOT_ANIM_ID
				local t = animator2:LoadAnimation(obj); obj:Destroy()
				t.Looped = false; t.Priority = Enum.AnimationPriority.Action4
				return t
			end)
			if ok and track then st.shootTrack = track end
		end
	end

	local animator = getOrCreateAnimator(tower)
	if not animator then task.spawn(finishRaise); return end

	safeDestroy(st.raiseTrack)
	local raiseTrack = loadAndPlay(animator, RAISE_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.12)
	if not raiseTrack then task.spawn(finishRaise); return end
	st.raiseTrack = raiseTrack

	-- Timeout fallback
	task.delay(Wanderer.GUN_RAISE_MAX_WAIT, function() task.spawn(finishRaise) end)
	-- Normal path (Stopped fires)
	task.spawn(function() raiseTrack.Stopped:Wait(); task.spawn(finishRaise) end)
end

local function triggerGunLower(tower: Model, st)
	if st.gunState == "lowering" or st.gunState == "idle" or st.gunState == "walking" then return end

	st.gunState = "lowering"
	safeStop(st.gunIdleTrack, 0.12); safeStop(st.shootTrack, 0.12)

	local animator = getOrCreateAnimator(tower)
	if not animator then st.gunState = "idle"; playIdle(tower, st); return end

	safeDestroy(st.lowerTrack)
	local lowerTrack = loadAndPlay(animator, LOWER_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.12)
	if not lowerTrack then st.gunState = "idle"; playIdle(tower, st); return end
	st.lowerTrack = lowerTrack

	task.spawn(function()
		lowerTrack.Stopped:Wait()
		if not tower or not tower.Parent then return end
		if st.gunState ~= "lowering" then return end
		st.gunState = "idle"; playIdle(tower, st)
	end)
end

local function playShootBrief(tower: Model, st)
	if st.shootTrack then
		pcall(function()
			st.shootTrack.TimePosition = 0
			if not st.shootTrack.IsPlaying then st.shootTrack:Play(0.05) end
		end)
	else
		local animator = getOrCreateAnimator(tower)
		if not animator then return end
		local ok, track = pcall(function()
			local obj = Instance.new("Animation"); obj.AnimationId = SHOOT_ANIM_ID
			local t = animator:LoadAnimation(obj); obj:Destroy()
			t.Looped = false; t.Priority = Enum.AnimationPriority.Action4; t:Play(0.05)
			return t
		end)
		if ok and track then st.shootTrack = track end
	end
end

-- ============================================================
-- VFX
-- ============================================================

function Wanderer.SpawnHitParticles(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name = "WandererHitAnchor"; anchor.Size = Vector3.new(0.1,0.1,0.1)
	anchor.Transparency = 1; anchor.Anchored = true; anchor.CanCollide = false
	anchor.Position = position; anchor.Parent = Workspace
	local att = Instance.new("Attachment"); att.Parent = anchor
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(255,230,100)),
		ColorSequenceKeypoint.new(0.5, color),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(60,60,60)),
	})
	sparks.Size         = NumberSequence.new({NumberSequenceKeypoint.new(0,0.25),NumberSequenceKeypoint.new(1,0)})
	sparks.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(1,1)})
	sparks.Lifetime     = NumberRange.new(0.12,0.3); sparks.Speed = NumberRange.new(5,16)
	sparks.SpreadAngle  = Vector2.new(180,90); sparks.Acceleration = Vector3.new(0,-12,0)
	sparks.Rate = 0; sparks.Parent = att; sparks:Emit(10)
	task.delay(0.5, function() if anchor and anchor.Parent then anchor:Destroy() end end)
end

local function spawnBullet(fromPos: Vector3, toPos: Vector3, isHighCaliber: boolean?)
	local dir = toPos - fromPos
	local dist = dir.Magnitude
	if dist < 0.1 then return end
	dir = dir.Unit

	local size = isHighCaliber and Vector3.new(0.13,0.13,0.8) or Vector3.new(0.09,0.09,0.5)
	local bullet = Instance.new("Part")
	bullet.Name = "WandererBullet"; bullet.Size = size
	bullet.Color = isHighCaliber and Color3.fromRGB(255,200,60) or Color3.fromRGB(240,230,180)
	bullet.Material = Enum.Material.Neon; bullet.Anchored = true
	bullet.CanCollide = false; bullet.CastShadow = false
	bullet.CFrame = CFrame.new(fromPos, toPos); bullet.Parent = Workspace

	local attA = Instance.new("Attachment"); attA.Position = Vector3.new(0,0,size.Z/2);  attA.Parent = bullet
	local attB = Instance.new("Attachment"); attB.Position = Vector3.new(0,0,-size.Z/2); attB.Parent = bullet
	local trail = Instance.new("Trail")
	trail.Attachment0 = attA; trail.Attachment1 = attB
	trail.Lifetime    = isHighCaliber and 0.12 or 0.06
	trail.MinLength   = 0; trail.FaceCamera = true
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, isHighCaliber and Color3.fromRGB(255,215,80) or Color3.fromRGB(255,240,180)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(80,80,80)),
	})
	trail.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(1,1)})
	trail.Parent = bullet

	local elapsed = 0; local travelTime = dist / Wanderer.BULLET_SPEED
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= travelTime or not bullet.Parent then
			conn:Disconnect()
			if bullet.Parent then bullet:Destroy() end; return
		end
		bullet.CFrame = CFrame.new(fromPos + dir*(elapsed*Wanderer.BULLET_SPEED), toPos)
	end)
end

-- ============================================================
-- MODEL CREATION
-- ============================================================

function Wanderer.CreateModel(position: Vector3, TowerStats: any): Model?
	local template = TowerStats.Templates["Wanderer"]
	if not template then return nil end

	local towerModels   = ServerStorage:FindFirstChild("TowerModels")
	local templateModel = towerModels and towerModels:FindFirstChild("Wanderer")
	if not templateModel then warn("[Wanderer] ServerStorage.TowerModels.Wanderer not found"); return nil end

	local model = templateModel:Clone(); model.Name = "Wanderer"
	if model.PrimaryPart then model.PrimaryPart.Anchored = true end

	local rangeStuds = template.RNG
	local circle = Instance.new("Part"); circle.Name = "RangeCircle"
	circle.Shape = Enum.PartType.Cylinder
	circle.Size  = Vector3.new(0.15, rangeStuds*2, rangeStuds*2)
	circle.Anchored = true; circle.CanCollide = false
	circle.Color = Color3.fromRGB(30,140,60); circle.Transparency = 1
	circle.Material = Enum.Material.SmoothPlastic; circle.Parent = model

	model:SetAttribute("ATK",         template.ATK)
	model:SetAttribute("AP",          template.AP)
	model:SetAttribute("ATK_SPD",     template.ATK_SPD)
	model:SetAttribute("RNG",         rangeStuds)
	model:SetAttribute("HP",          template.HP)
	model:SetAttribute("MaxHP",       template.HP)
	model:SetAttribute("MOVE_SPD",    template.MOVE_SPD)
	model:SetAttribute("DamageMulti", template.DamageMulti or 1.0)
	model:SetAttribute("AttackType",  template.AttackType  or "Ranged")
	model:SetAttribute("State",       "Idle")
	model:SetAttribute("Owner",       "")
	model:SetAttribute("TowerType",   "Wanderer")

	model:PivotTo(CFrame.new(position))
	local lowestY = math.huge
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "RangeCircle" then
			lowestY = math.min(lowestY, part.Position.Y - part.Size.Y/2)
		end
	end
	if lowestY < math.huge then
		local lift = position.Y - lowestY
		model:PivotTo(CFrame.new(Vector3.new(position.X, position.Y+lift, position.Z)))
	end

	local finalPos = model.PrimaryPart and model.PrimaryPart.Position or position
	circle.CFrame  = CFrame.new(finalPos.X, finalPos.Y-2.5, finalPos.Z) * CFrame.Angles(0,0,math.rad(90))
	return model
end

-- ============================================================
-- MOTOR6D BASE STORAGE
-- ============================================================

function Wanderer.StoreBaseC0s(model: Model)
	if baseC0s[model] then return end
	local torso = model.PrimaryPart; if not torso then return end
	local stored = {}
	for _, n in ipairs({"Neck","LeftShoulder","RightShoulder","LeftHip","RightHip"}) do
		local motor = torso:FindFirstChild(n)
		if motor then stored[n] = motor.C0 end
	end
	baseC0s[model] = stored
end

function Wanderer.RestoreBaseC0s(model: Model)
	local stored = baseC0s[model]; if not stored then return end
	local torso  = model.PrimaryPart; if not torso then return end
	for n, c0 in pairs(stored) do
		local motor = torso:FindFirstChild(n)
		if motor then motor.C0 = c0 end
	end
end

-- ============================================================
-- WALK ANIMATION
-- ============================================================

function Wanderer.StartWalk(model: Model)
	if walkTracks[model] then return end
	local st = getAnimState(model)
	safeStop(st.idleTrack, 0.15); safeStop(st.gunIdleTrack, 0.1)
	safeStop(st.shootTrack, 0.1); safeStop(st.lowerTrack, 0.15); safeStop(st.commandTrack, 0.1)
	st.gunState = "walking"
	local animator = getOrCreateAnimator(model); if not animator then return end
	local track = loadAndPlay(animator, WALK_ANIM_ID, true, Enum.AnimationPriority.Movement, 0.2)
	if track then walkTracks[model] = track end
end

function Wanderer.StopWalk(model: Model)
	local track = walkTracks[model]
	if track then safeStop(track, 0.2); task.delay(0.25, function() safeDestroy(track) end); walkTracks[model] = nil end
	Wanderer.RestoreBaseC0s(model)
	local st = animState[model]; if st then st.gunState = "idle" end
end

-- ============================================================
-- PUBLIC – INIT
-- ============================================================

function Wanderer.InitTower(tower: Model)
	local st = getAnimState(tower)
	spawnDrone(tower)
	st.gunState = "idle"

	local animator = getOrCreateAnimator(tower)
	if animator then
		local deployTrack = loadAndPlay(animator, DEPLOY_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.1)
		if deployTrack then
			task.spawn(function()
				deployTrack.Stopped:Wait()
				if not tower or not tower.Parent then return end
				playIdle(tower, st)
			end)
			return
		end
	end
	playIdle(tower, st)
end

-- ============================================================
-- PUBLIC – DRONE QUERIES
-- ============================================================

function Wanderer.GetDronePosition(tower: Model): Vector3?
	if not droneAlive[tower] then return nil end
	local drone = droneModels[tower]
	if not drone or not drone.Parent then return nil end
	if drone.PrimaryPart then return drone.PrimaryPart.Position end
	local p = drone:FindFirstChildOfClass("BasePart")
	return p and p.Position or nil
end

function Wanderer.IsReconActive(tower: Model): boolean
	return reconActive[tower] == true
end

-- ============================================================
-- PUBLIC – DRONE MOVEMENT
-- ============================================================

function Wanderer.MoveDrone(tower: Model, dest: Vector3)
	if not droneAlive[tower] then return end
	local drone = droneModels[tower]
	if not drone or not drone.PrimaryPart then return end
	local torso = tower.PrimaryPart; if not torso then return end

	local range    = tower:GetAttribute("RNG") or 35
	local flatDiff = Vector3.new(dest.X-torso.Position.X, 0, dest.Z-torso.Position.Z)
	if flatDiff.Magnitude > range then
		local clamped = torso.Position + flatDiff.Unit * range
		dest = Vector3.new(clamped.X, dest.Y, clamped.Z)
	end
	dest = Vector3.new(dest.X, torso.Position.Y+3, dest.Z)

	local st = getAnimState(tower)
	if st.gunState ~= "walking" then
		local animator = getOrCreateAnimator(tower)
		if animator then
			safeStop(st.commandTrack, 0.1)
			st.commandTrack = loadAndPlay(animator, COMMAND_ANIM_ID, false, Enum.AnimationPriority.Action2, 0.1)
		end
	end

	local now = tick()
	if now >= (suppressCooldownEnd[tower] or 0) then
		suppressCooldownEnd[tower] = now + Wanderer.SUPPRESS_COOLDOWN
		local old = suppressData[tower]
		if old and old.zone and old.zone.Parent then old.zone:Destroy() end
		local zone = spawnSuppressingZone(dest)
		suppressData[tower] = {
			pos=dest, endTime=now+Wanderer.SUPPRESS_DURATION,
			lastTick=now-(Wanderer.SUPPRESS_DURATION+0.1), zone=zone,
		}
		task.delay(Wanderer.SUPPRESS_DURATION, function()
			local d = suppressData[tower]
			if d and d.zone and d.zone.Parent then
				TweenService:Create(d.zone, TweenInfo.new(0.5), {Transparency=1}):Play()
				task.delay(0.6, function() if d.zone and d.zone.Parent then d.zone:Destroy() end end)
			end
		end)
	end

	if activeDroneMovements[tower] then activeDroneMovements[tower]:Disconnect(); activeDroneMovements[tower] = nil end

	local speed = Wanderer.DRONE_MOVE_SPEED
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not drone or not drone.PrimaryPart or not drone.Parent then
			conn:Disconnect(); activeDroneMovements[tower] = nil; return
		end
		local cur  = drone.PrimaryPart.Position
		local flat = Vector3.new(dest.X-cur.X, 0, dest.Z-cur.Z)
		if flat.Magnitude < 0.3 then
			conn:Disconnect(); activeDroneMovements[tower] = nil
			drone:PivotTo(CFrame.new(dest)); return
		end
		local step = flat.Unit * speed * dt
		drone:PivotTo(CFrame.new(Vector3.new(cur.X+step.X, dest.Y, cur.Z+step.Z)))
	end)
	activeDroneMovements[tower] = conn
end

-- ============================================================
-- PUBLIC – SUPPRESSING FIRE TICK  (called by TowerManager)
-- ============================================================

function Wanderer.TickSuppressingFire(tower: Model, enemiesFolder: Folder, damageIndicatorRemote: RemoteEvent)
	local data = suppressData[tower]; if not data then return end
	local now  = tick()
	if now >= data.endTime then suppressData[tower] = nil; return end
	if now - data.lastTick < 1.0 then return end
	data.lastTick = now

	local atk    = tower:GetAttribute("ATK")         or 18
	local multi  = tower:GetAttribute("DamageMulti") or 1.0
	local dps    = atk * multi * Wanderer.SUPPRESS_DPS_MULTI

	for _, enemy in ipairs(enemiesFolder:GetChildren()) do
		if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
			if (enemy.PrimaryPart.Position - data.pos).Magnitude <= Wanderer.SUPPRESS_RADIUS then
				local hp    = enemy:GetAttribute("HP") or 0
				local newHP = hp - dps
				enemy:SetAttribute("HP", newHP)
				if damageIndicatorRemote then
					damageIndicatorRemote:FireAllClients(enemy.PrimaryPart.Position, dps, "Normal")
				end
				if newHP <= 0 and enemy.Parent then enemy:Destroy() end
			end
		end
	end
end

-- ============================================================
-- PUBLIC – RECONNAISSANCE
-- ============================================================

function Wanderer.ActivateReconnaissance(tower: Model)
	local now = tick()
	if now < (reconCooldownEnd[tower] or 0) then return end
	if not droneAlive[tower] then return end

	reconActive[tower]      = true
	reconEndAt[tower]       = now + Wanderer.RECON_DURATION
	reconCooldownEnd[tower] = now + Wanderer.RECON_COOLDOWN
	startReconPulse(tower)

	task.delay(Wanderer.RECON_DURATION, function()
		if not tower or not tower.Parent then return end
		reconActive[tower] = false
		local pc = reconPulseConnections[tower]
		if pc then pc:Disconnect(); reconPulseConnections[tower] = nil end
	end)
end

function Wanderer.TickReconnaissance(tower: Model)
	if not reconActive[tower] then return end
	if tick() >= (reconEndAt[tower] or 0) then
		reconActive[tower] = false
		local pc = reconPulseConnections[tower]
		if pc then pc:Disconnect(); reconPulseConnections[tower] = nil end
	end
end

function Wanderer.IsReconReady(tower: Model): boolean
	return tick() >= (reconCooldownEnd[tower] or 0)
end

-- ============================================================
-- PUBLIC – DRONE RESPAWN TICK  (called by TowerManager)
-- ============================================================

function Wanderer.TickDroneRespawn(tower: Model)
	if droneAlive[tower] then return end
	if tick() >= (droneRespawnAt[tower] or 0) then spawnDrone(tower) end
end

-- ============================================================
-- PUBLIC – ANIMATION INTERFACE
-- ============================================================

function Wanderer.IsReadyToFire(tower: Model): boolean
	local st = animState[tower]; if not st then return false end
	return st.gunState == "shoot_hold" and tick() >= st.readyToFireTime
end

-- ── FIX BUG 2 ─────────────────────────────────────────────────────────────
-- Gun-lower now ONLY runs when hasTarget = false.
-- Original code lowered mid-combat causing a permanent raise/lower cycle.
-- ──────────────────────────────────────────────────────────────────────────
function Wanderer.UpdateCombatState(tower: Model, hasTarget: boolean, target: Instance?)
	local st = getAnimState(tower); if not st then return end
	if st.gunState == "walking" then return end

	if hasTarget and target then
		if st.gunState == "idle" then triggerGunRaise(tower, st) end

		if st.gunState == "raising" or st.gunState == "raised" or st.gunState == "shoot_hold" then
			local torso      = tower.PrimaryPart
			local targetPart = (target :: Model).PrimaryPart
			if torso and targetPart then
				local flatDir = Vector3.new(
					targetPart.Position.X - torso.Position.X, 0,
					targetPart.Position.Z - torso.Position.Z)
				if flatDir.Magnitude > 0.1 then
					torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
				end
			end
		end
	else
		-- No target: lower after idle delay
		if (st.gunState == "shoot_hold" or st.gunState == "raised") and
			(tick() - st.lastShotTime) >= Wanderer.GUN_LOWER_DELAY
		then
			triggerGunLower(tower, st); return
		end
		if st.gunState == "idle" then
			if not (st.idleTrack and st.idleTrack.IsPlaying) then playIdle(tower, st) end
		end
	end
end

-- ============================================================
-- PUBLIC – ATTACK  (called by TowerManager)
-- ============================================================

function Wanderer.DoAttack(tower: Model, target: Model, _enemiesFolder: Folder?): boolean
	local st = getAnimState(tower); if not st then return false end
	if not target or not target.Parent or not target.PrimaryPart then return false end

	local atk     = tower:GetAttribute("ATK")         or 18
	local multi   = tower:GetAttribute("DamageMulti") or 1.0
	local isRecon = reconActive[tower] == true
	local impactPos = target.PrimaryPart.Position
	local torso     = tower.PrimaryPart
	local dronePos  = Wanderer.GetDronePosition(tower)

	local fromPos: Vector3
	if isRecon then
		-- FIX: handle BasePart (.Position) vs Attachment (.WorldPosition)
		local barrel = torso and torso:FindFirstChild("GunBarrel")
		if barrel then
			if barrel:IsA("BasePart")  then fromPos = barrel.Position
			elseif barrel:IsA("Attachment") then fromPos = barrel.WorldPosition
			else fromPos = torso and torso.Position or impactPos end
		else
			fromPos = torso and torso.Position or impactPos
		end
	else
		fromPos = dronePos or (torso and torso.Position) or impactPos
	end

	if isRecon then
		local damage = atk * multi * Wanderer.HIGH_CALIBER_MULTI
		local newHP  = (target:GetAttribute("HP") or 0) - damage
		target:SetAttribute("HP", newHP)
		local dr = ReplicatedStorage:FindFirstChild("ShowDamageIndicator")
		if dr then dr:FireAllClients(impactPos, damage, "Critical") end
		Wanderer.SpawnHitParticles(impactPos, Color3.fromRGB(255,200,60))
		spawnBullet(fromPos, impactPos, true)
		playShootBrief(tower, st); st.lastShotTime = tick()
		if newHP <= 0 and target.Parent then target:Destroy() end
	else
		local damage = atk * multi * Wanderer.HEAVY_ROUNDS_MULTI
		local newHP1 = (target:GetAttribute("HP") or 0) - damage
		target:SetAttribute("HP", newHP1)
		local dr = ReplicatedStorage:FindFirstChild("ShowDamageIndicator")
		if dr then dr:FireAllClients(impactPos, damage, "Normal") end
		Wanderer.SpawnHitParticles(impactPos, Color3.fromRGB(180,210,255))
		spawnBullet(fromPos, impactPos, false)
		playShootBrief(tower, st); st.lastShotTime = tick()

		if newHP1 <= 0 and target.Parent then
			target:Destroy()
		else
			task.delay(0.12, function()
				if not tower or not tower.Parent then return end
				if not target or not target.Parent or not target.PrimaryPart then return end
				local pos2   = target.PrimaryPart.Position
				local newHP2 = (target:GetAttribute("HP") or 0) - damage
				target:SetAttribute("HP", newHP2)
				local dr2 = ReplicatedStorage:FindFirstChild("ShowDamageIndicator")
				if dr2 then dr2:FireAllClients(pos2, damage, "Normal") end
				Wanderer.SpawnHitParticles(pos2, Color3.fromRGB(180,210,255))
				spawnBullet(fromPos, pos2, false)
				playShootBrief(tower, st)
				if newHP2 <= 0 and target.Parent then target:Destroy() end
			end)
		end
	end

	return true
end

-- ============================================================
-- CLEANUP
-- ============================================================

function Wanderer.CleanupTower(tower: Model)
	local st = animState[tower]
	if st then
		safeDestroy(st.idleTrack); safeDestroy(st.raiseTrack); safeDestroy(st.gunIdleTrack)
		safeDestroy(st.shootTrack); safeDestroy(st.lowerTrack); safeDestroy(st.commandTrack)
		animState[tower] = nil
	end
	baseC0s[tower] = nil
	local wt = walkTracks[tower]
	if wt then pcall(function() wt:Stop(0); wt:Destroy() end); walkTracks[tower] = nil end

	if activeDroneMovements[tower] then activeDroneMovements[tower]:Disconnect(); activeDroneMovements[tower] = nil end
	local drone = droneModels[tower]
	if drone and drone.Parent then drone:Destroy() end
	droneModels[tower] = nil; droneAlive[tower] = nil; droneRespawnAt[tower] = nil

	local pc = reconPulseConnections[tower]
	if pc then pc:Disconnect(); reconPulseConnections[tower] = nil end
	reconActive[tower] = nil; reconEndAt[tower] = nil; reconCooldownEnd[tower] = nil

	local sd = suppressData[tower]
	if sd and sd.zone and sd.zone.Parent then sd.zone:Destroy() end
	suppressData[tower] = nil; suppressCooldownEnd[tower] = nil
end

return Wanderer
