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
Wanderer.GUN_LOWER_DELAY     = 3.0   -- seconds without shot → lower gun

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

local animState           = {}  -- tower → animation-state record
local baseC0s             = {}  -- tower → stored Motor6D C0s
local walkTracks          = {}  -- tower → active walk AnimationTrack

local droneModels         = {}  -- tower → Drone Model (child of tower)
local droneAlive          = {}  -- tower → boolean
local droneRespawnAt      = {}  -- tower → tick() when drone respawns
local activeDroneMovements= {}  -- tower → RBXScriptConnection
local droneFloatTimers    = {}  -- tower → float animation timer (seconds)

local reconActive         = {}  -- tower → boolean
local reconEndAt          = {}  -- tower → tick() when Recon expires
local reconCooldownEnd    = {}  -- tower → tick() when Recon CD expires

local suppressCooldownEnd = {}  -- tower → tick() when Suppressing Fire CD expires
local suppressData        = {}  -- tower → { pos, endTime, lastTick, zone }

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
	warn("[Wanderer] No Humanoid or AnimationController found – cannot animate")
	return nil
end

local function safeStop(track, blendTime: number?)
	if track then
		pcall(function()
			if track.IsPlaying then track:Stop(blendTime or 0.1) end
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
			-- "idle" | "raising" | "raised" | "shoot_hold" | "lowering" | "walking"
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

local function ensurePrimaryPart(model: Model): BasePart?
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end
	-- Search all descendants, not just direct children
	local primary = model:FindFirstChildWhichIsA("BasePart", true)
	if primary then
		model.PrimaryPart = primary
	end
	return primary
end

local function buildDroneModel(position: Vector3): Model?
	-- Try to use ServerStorage template first
	local towerModels = ServerStorage:FindFirstChild("TowerModels")
	local template    = towerModels and towerModels:FindFirstChild("Drone")
	if template then
		local m = template:Clone()
		m.Name = "Drone"
		-- Anchor ALL parts so the drone floats and gravity cannot pull any piece down
		for _, desc in ipairs(m:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Anchored   = true
				desc.CanCollide = false
			end
		end
		-- Guarantee a PrimaryPart so position queries and PivotTo work correctly
		local primary = ensurePrimaryPart(m)
		if not primary then
			warn("[Wanderer] Drone template has no BasePart descendants")
			return nil
		end
		m:PivotTo(CFrame.new(position))
		return m
	end

	-- Fallback: procedural MQ-9-style drone shape
	local model   = Instance.new("Model")
	model.Name    = "Drone"

	local grey    = Color3.fromRGB(55, 58, 65)
	local darkGrey = Color3.fromRGB(35, 36, 42)

	-- Central fuselage
	local body    = Instance.new("Part")
	body.Name     = "Body"
	body.Size     = Vector3.new(0.8, 0.3, 2.2)
	body.Color    = grey
	body.Material = Enum.Material.SmoothPlastic
	body.Anchored = true
	body.CanCollide = false
	body.CastShadow = false
	body.CFrame   = CFrame.new(position)
	body.Parent   = model
	model.PrimaryPart = body

	-- Wing (flat slab)
	local wing    = Instance.new("Part")
	wing.Name     = "Wing"
	wing.Size     = Vector3.new(3.6, 0.12, 0.9)
	wing.Color    = grey
	wing.Material = Enum.Material.SmoothPlastic
	wing.Anchored = true
	wing.CanCollide = false
	wing.CastShadow = false
	wing.CFrame   = CFrame.new(position + Vector3.new(0, 0, 0.1))
	wing.Parent   = model

	-- Tail fin
	local tail    = Instance.new("Part")
	tail.Name     = "Tail"
	tail.Size     = Vector3.new(0.12, 0.6, 0.6)
	tail.Color    = darkGrey
	tail.Material = Enum.Material.SmoothPlastic
	tail.Anchored = true
	tail.CanCollide = false
	tail.CastShadow = false
	tail.CFrame   = CFrame.new(position + Vector3.new(0, 0.25, -0.9))
	tail.Parent   = model

	-- Camera pod underneath
	local cam     = Instance.new("Part")
	cam.Name      = "Camera"
	cam.Shape     = Enum.PartType.Ball
	cam.Size      = Vector3.new(0.35, 0.35, 0.35)
	cam.Color     = Color3.fromRGB(20, 20, 25)
	cam.Material  = Enum.Material.SmoothPlastic
	cam.Anchored  = true
	cam.CanCollide = false
	cam.CastShadow = false
	cam.CFrame    = CFrame.new(position + Vector3.new(0, -0.28, 0.4))
	cam.Parent    = model

	-- Engine glow
	local engine  = Instance.new("Part")
	engine.Name   = "Engine"
	engine.Shape  = Enum.PartType.Cylinder
	engine.Size   = Vector3.new(0.22, 0.4, 0.4)
	engine.Color  = Color3.fromRGB(255, 130, 20)
	engine.Material = Enum.Material.Neon
	engine.Anchored = true
	engine.CanCollide = false
	engine.CastShadow = false
	engine.CFrame = CFrame.new(position + Vector3.new(0, 0, -1.15))
		* CFrame.Angles(0, 0, math.rad(90))
	engine.Parent = model

	return model
end

-- ============================================================
-- DRONE MANAGEMENT
-- ============================================================


-- ============================================================
-- DRONE MANAGEMENT
-- ============================================================

local function spawnDrone(tower: Model)
	local torso = tower.PrimaryPart
	if not torso then return end

	-- Remove existing drone if any
	local existing = droneModels[tower]
	if existing and existing.Parent then existing:Destroy() end

	local spawnPos = torso.Position
	local drone    = buildDroneModel(spawnPos + Vector3.new(0, 3, 2))
	drone.Parent   = tower

	droneModels[tower] = drone
	droneAlive[tower]  = true

	-- DroneRangeCircle: shows where the drone can currently shoot enemies
	local droneRng = tower:GetAttribute("RNG") / 3
	local existingDrc = tower:FindFirstChild("DroneRangeCircle")
	if existingDrc then existingDrc:Destroy() end
	local drc        = Instance.new("Part")
	drc.Name         = "DroneRangeCircle"
	drc.Shape        = Enum.PartType.Cylinder
	drc.Size         = Vector3.new(0.12, droneRng * 2, droneRng * 2)
	drc.Anchored     = true
	drc.CanCollide   = false
	drc.Color        = Color3.fromRGB(56, 69, 255)
	drc.Transparency = 1
	drc.Material     = Enum.Material.Neon
	local dp = drone.PrimaryPart
	if dp then
		drc.CFrame = CFrame.new(dp.Position.X, dp.Position.Y - 5.5, dp.Position.Z)
			* CFrame.Angles(0, 0, math.rad(90))
	end
	drc.Parent = tower

	-- Play summon animation on Wanderer
	local st = getAnimState(tower)
	local animator = getOrCreateAnimator(tower)
	if animator then
		local summonTrack = loadAndPlay(
			animator, SUMMON_ANIM_ID, false,
			Enum.AnimationPriority.Action3, 0.1
		)
		-- Return to idle after summon anim finishes
		if summonTrack then
			task.spawn(function()
				summonTrack.Stopped:Wait()
				if tower and tower.Parent and st.gunState ~= "walking" then
					st.gunState = "idle"
					-- idle will be kicked by UpdateCombatState
				end
			end)
		end
	end

	-- Green pulse VFX showing the drone is active
	local dronePart = drone.PrimaryPart
	if dronePart then
		local light = Instance.new("PointLight")
		light.Brightness = 2
		light.Color      = Color3.fromRGB(80, 230, 100)
		light.Range      = 8
		light.Parent     = dronePart

		-- Fade light in and out once
		TweenService:Create(light, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true), { Brightness = 0.2 }):Play()
		task.delay(1.5, function()
			if light and light.Parent then light:Destroy() end
		end)

		-- Persistent ambient hover light
		local hoverLight = Instance.new("PointLight")
		hoverLight.Name       = "HoverLight"
		hoverLight.Brightness = 0.8
		hoverLight.Color      = Color3.fromRGB(60, 200, 255)
		hoverLight.Range      = 14
		hoverLight.Parent     = dronePart

		-- Hover particle attachment
		local att = Instance.new("Attachment")
		att.Name   = "HoverAtt"
		att.Parent = dronePart
		local hoverParticles = Instance.new("ParticleEmitter")
		hoverParticles.Name          = "HoverParticles"
		hoverParticles.Color         = ColorSequence.new(Color3.fromRGB(60, 220, 255))
		hoverParticles.LightEmission = 1
		hoverParticles.LightInfluence = 0
		hoverParticles.Size          = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0) })
		hoverParticles.Transparency  = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		hoverParticles.Lifetime      = NumberRange.new(0.4, 0.8)
		hoverParticles.Rate          = 8
		hoverParticles.Speed         = NumberRange.new(0.5, 1.5)
		hoverParticles.SpreadAngle   = Vector2.new(30, 30)
		hoverParticles.Parent        = att

		-- Movement speed-line particles (enabled in MoveDrone, disabled while idle)
		local moveAtt = Instance.new("Attachment")
		moveAtt.Name   = "MoveAtt"
		moveAtt.Parent = dronePart
		local moveParticles = Instance.new("ParticleEmitter")
		moveParticles.Name          = "MoveParticles"
		moveParticles.Color         = ColorSequence.new(Color3.fromRGB(120, 200, 255))
		moveParticles.LightEmission = 1
		moveParticles.LightInfluence = 0
		moveParticles.Size          = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(1, 0) })
		moveParticles.Transparency  = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
		moveParticles.Lifetime      = NumberRange.new(0.15, 0.3)
		moveParticles.Rate          = 0   -- enabled only while moving
		moveParticles.Speed         = NumberRange.new(3, 6)
		moveParticles.SpreadAngle   = Vector2.new(160, 160)
		moveParticles.Parent        = moveAtt
	end

	droneFloatTimers[tower] = 0
end

local function destroyDrone(tower: Model)
	local drone = droneModels[tower]
	if drone and drone.Parent then
		-- Explosion-like VFX
		local dronePart = drone.PrimaryPart
		if dronePart then
			local anchor  = Instance.new("Part")
			anchor.Size   = Vector3.new(0.1, 0.1, 0.1)
			anchor.Transparency = 1
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.Position = dronePart.Position
			anchor.Parent   = Workspace

			local att = Instance.new("Attachment")
			att.Parent = anchor

			local burst = Instance.new("ParticleEmitter")
			burst.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 220, 80)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 80,  20)),
				ColorSequenceKeypoint.new(1,   Color3.fromRGB(60,  40,  30)),
			})
			burst.Size        = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
			burst.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
			burst.Lifetime    = NumberRange.new(0.3, 0.8)
			burst.Speed       = NumberRange.new(5, 18)
			burst.SpreadAngle = Vector2.new(180, 180)
			burst.Rate        = 0
			burst.Parent      = att
			burst:Emit(20)

			task.delay(1.0, function()
				if anchor and anchor.Parent then anchor:Destroy() end
			end)
		end

		drone:Destroy()
	end

	droneModels[tower]      = nil
	droneAlive[tower]       = false
	droneRespawnAt[tower]   = tick() + Wanderer.DRONE_RESPAWN_TIME
	droneFloatTimers[tower] = nil

	-- Cancel any active drone movement
	if activeDroneMovements[tower] then
		activeDroneMovements[tower]:Disconnect()
		activeDroneMovements[tower] = nil
	end

	-- Remove DroneRangeCircle
	local drc = tower:FindFirstChild("DroneRangeCircle")
	if drc and drc.Parent then drc:Destroy() end
end

-- ============================================================
-- RECONNAISSANCE PULSE VFX
-- ============================================================

local reconPulseConnections = {}  -- tower → RBXScriptConnection

local function startReconPulse(tower: Model)
	-- Cancel existing pulse
	local existing = reconPulseConnections[tower]
	if existing then existing:Disconnect(); reconPulseConnections[tower] = nil end

	local drone = droneModels[tower]
	if not drone or not drone.PrimaryPart then return end

	local pulseInterval = 0.5  -- seconds between pulses
	local lastPulse = 0

	local conn
	conn = RunService.Heartbeat:Connect(function()
		local now = tick()
		if now - lastPulse < pulseInterval then return end
		lastPulse = now

		if not reconActive[tower] then
			conn:Disconnect()
			reconPulseConnections[tower] = nil
			return
		end

		local dronePart = drone and drone.PrimaryPart
		if not dronePart or not dronePart.Parent then
			conn:Disconnect()
			reconPulseConnections[tower] = nil
			return
		end

		local range = tower:GetAttribute("RNG") / 3

		-- Expanding ring pulse
		local ring     = Instance.new("Part")
		ring.Name      = "ReconPulse"
		ring.Shape     = Enum.PartType.Cylinder
		ring.Size      = Vector3.new(0.1, 0.5, 0.5)
		ring.Color     = Color3.fromRGB(60, 220, 80)
		ring.Material  = Enum.Material.Neon
		ring.Transparency = 0.2
		ring.Anchored  = true
		ring.CanCollide = false
		ring.CastShadow = false
		ring.CFrame    = CFrame.new(dronePart.Position) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent    = Workspace

		local targetSize = Vector3.new(0.05, range * 2, range * 2)
		TweenService:Create(
			ring,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = targetSize, Transparency = 1 }
		):Play()

		task.delay(0.6, function()
			if ring and ring.Parent then ring:Destroy() end
		end)
	end)

	reconPulseConnections[tower] = conn
end

-- ============================================================
-- SUPPRESSING FIRE ZONE VFX
-- ============================================================

local function spawnSuppressingZone(position: Vector3): Part
	local zone       = Instance.new("Part")
	zone.Name        = "SuppressingFireZone"
	zone.Shape       = Enum.PartType.Cylinder
	zone.Size        = Vector3.new(0.12, Wanderer.SUPPRESS_RADIUS * 2, Wanderer.SUPPRESS_RADIUS * 2)
	zone.Color       = Color3.fromRGB(220, 120, 20)
	zone.Material    = Enum.Material.Neon
	zone.Transparency = 0.55
	zone.Anchored    = true
	zone.CanCollide  = false
	zone.CastShadow  = false
	zone.CFrame      = CFrame.new(position.X, position.Y - 5, position.Z)
		* CFrame.Angles(0, 0, math.rad(90))
	zone.Parent      = Workspace

	-- Bullet rain particles above zone
	local att = Instance.new("Attachment")
	att.Position = Vector3.new(0, 3, 0)
	att.Parent   = zone

	local rain = Instance.new("ParticleEmitter")
	rain.Color = ColorSequence.new(Color3.fromRGB(255, 210, 80))
	rain.Size  = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(1, 0),
	})
	rain.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	rain.Lifetime     = NumberRange.new(0.3, 0.6)
	rain.Speed        = NumberRange.new(8, 20)
	rain.SpreadAngle  = Vector2.new(30, 30)
	rain.Acceleration = Vector3.new(0, -30, 0)
	rain.Rate         = 60
	rain.Parent       = att

	return zone
end

-- ============================================================
-- ANIMATION STATE MACHINE (WANDERER CHARACTER)
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
	safeStop(st.idleTrack,    0.12)
	safeStop(st.lowerTrack,   0.1)
	safeStop(st.commandTrack, 0.1)

	local animator = getOrCreateAnimator(tower)
	if not animator then
		st.gunState        = "shoot_hold"
		st.readyToFireTime = tick() + Wanderer.GUN_RAISE_DELAY
		st.lastShotTime    = tick()
		return
	end

	safeDestroy(st.raiseTrack)
	local raiseTrack = loadAndPlay(animator, RAISE_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.12)
	if not raiseTrack then
		st.gunState        = "shoot_hold"
		st.readyToFireTime = tick() + Wanderer.GUN_RAISE_DELAY
		st.lastShotTime    = tick()
		return
	end
	st.raiseTrack = raiseTrack

	task.spawn(function()
		raiseTrack.Stopped:Wait()
		if not tower or not tower.Parent then return end
		if st.gunState ~= "raising" then return end

		st.gunState        = "raised"
		st.readyToFireTime = tick() + Wanderer.GUN_RAISE_DELAY
		st.lastShotTime    = tick()

		task.wait(Wanderer.GUN_RAISE_DELAY)
		if not tower or not tower.Parent then return end
		if st.gunState ~= "raised" then return end

		st.gunState     = "shoot_hold"
		st.lastShotTime = tick()

		-- Start gun-idle (raised aim pose)
		local animator2 = getOrCreateAnimator(tower)
		if animator2 then
			safeDestroy(st.gunIdleTrack)
			st.gunIdleTrack = loadAndPlay(
				animator2, GUN_IDLE_ANIM_ID, true,
				Enum.AnimationPriority.Action4, 0.1
			)
		end

		-- Pre-load shoot track
		safeDestroy(st.shootTrack)
		st.shootTrack = nil
		if animator2 then
			local ok, shootTrack = pcall(function()
				local obj = Instance.new("Animation")
				obj.AnimationId = SHOOT_ANIM_ID
				local t = animator2:LoadAnimation(obj)
				obj:Destroy()
				t.Looped   = false
				t.Priority = Enum.AnimationPriority.Action4
				return t
			end)
			if ok and shootTrack then
				st.shootTrack = shootTrack
			end
		end
	end)
end

local function triggerGunLower(tower: Model, st)
	if st.gunState == "lowering" or
		st.gunState == "idle"     or
		st.gunState == "walking"  then
		return
	end

	st.gunState = "lowering"
	safeStop(st.gunIdleTrack, 0.12)
	safeStop(st.shootTrack,   0.12)

	local animator = getOrCreateAnimator(tower)
	if not animator then
		st.gunState = "idle"
		playIdle(tower, st)
		return
	end

	safeDestroy(st.lowerTrack)
	local lowerTrack = loadAndPlay(animator, LOWER_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.12)
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

local function playShootBrief(tower: Model, st)
	if st.shootTrack then
		pcall(function()
			st.shootTrack.TimePosition = 0
			if not st.shootTrack.IsPlaying then
				st.shootTrack:Play(0.05)
			end
		end)
	else
		local animator = getOrCreateAnimator(tower)
		if not animator then return end
		local ok, track = pcall(function()
			local obj = Instance.new("Animation")
			obj.AnimationId = SHOOT_ANIM_ID
			local t = animator:LoadAnimation(obj)
			obj:Destroy()
			t.Looped   = false
			t.Priority = Enum.AnimationPriority.Action4
			t:Play(0.05)
			return t
		end)
		if ok and track then
			st.shootTrack = track
		end
	end
end

-- ============================================================
-- VFX
-- ============================================================

-- Standard hit sparks (called by TowerManager for enemy hit feedback)
function Wanderer.SpawnHitParticles(position: Vector3, color: Color3)
	local anchor    = Instance.new("Part")
	anchor.Name     = "WandererHitAnchor"
	anchor.Size     = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.Position = position
	anchor.Parent   = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 230, 100)),
		ColorSequenceKeypoint.new(0.5, color),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(60,  60,  60)),
	})
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	sparks.Lifetime     = NumberRange.new(0.12, 0.3)
	sparks.Speed        = NumberRange.new(5, 16)
	sparks.SpreadAngle  = Vector2.new(180, 90)
	sparks.Acceleration = Vector3.new(0, -12, 0)
	sparks.Rate         = 0
	sparks.Parent       = att
	sparks:Emit(10)

	task.delay(0.5, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- Bullet tracer from origin to target
local function spawnBullet(fromPos: Vector3, toPos: Vector3, isHighCaliber: boolean?)
	local dir  = toPos - fromPos
	local dist = dir.Magnitude
	if dist < 0.1 then return end
	dir = dir.Unit

	local size = isHighCaliber
		and Vector3.new(0.13, 0.13, 0.8)
		or  Vector3.new(0.09, 0.09, 0.5)

	local bullet     = Instance.new("Part")
	bullet.Name      = "WandererBullet"
	bullet.Size      = size
	bullet.Color     = isHighCaliber
		and Color3.fromRGB(255, 200, 60)
		or  Color3.fromRGB(240, 230, 180)
	bullet.Material  = Enum.Material.Neon
	bullet.Anchored  = true
	bullet.CanCollide = false
	bullet.CastShadow = false
	bullet.CFrame    = CFrame.new(fromPos, toPos)
	bullet.Parent    = Workspace

	local attA = Instance.new("Attachment")
	attA.Position = Vector3.new(0, 0, size.Z / 2)
	attA.Parent   = bullet

	local attB = Instance.new("Attachment")
	attB.Position = Vector3.new(0, 0, -(size.Z / 2))
	attB.Parent   = bullet

	local trail = Instance.new("Trail")
	trail.Attachment0 = attA
	trail.Attachment1 = attB
	trail.Lifetime    = isHighCaliber and 0.12 or 0.06
	trail.MinLength   = 0
	trail.FaceCamera  = true
	trail.Color       = ColorSequence.new({
		ColorSequenceKeypoint.new(0, isHighCaliber and Color3.fromRGB(255, 215, 80) or Color3.fromRGB(255, 240, 180)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 80, 80)),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = bullet

	local SPEED = Wanderer.BULLET_SPEED
	local travelTime = dist / SPEED
	local elapsed    = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= travelTime or not bullet.Parent then
			conn:Disconnect()
			if bullet.Parent then bullet:Destroy() end
			return
		end
		bullet.CFrame = CFrame.new(fromPos + dir * (elapsed * SPEED), toPos)
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
	if not templateModel then
		warn("[Wanderer] ServerStorage.TowerModels.Wanderer not found")
		return nil
	end

	local model = templateModel:Clone()
	model.Name  = "Wanderer"

	if model.PrimaryPart then
		model.PrimaryPart.Anchored = true
	end

	local rangeStuds = template.RNG

	-- Range circle (shows drone movement / attack range)
	local circle     = Instance.new("Part")
	circle.Name      = "RangeCircle"
	circle.Shape     = Enum.PartType.Cylinder
	circle.Size      = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored  = true
	circle.CanCollide = false
	circle.Color     = Color3.fromRGB(30, 120, 215)
	circle.Transparency = 1
	circle.Material  = Enum.Material.SmoothPlastic
	circle.Parent    = model

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

	-- Ground-snap
	local lowestY = math.huge
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "RangeCircle" then
			lowestY = math.min(lowestY, part.Position.Y - part.Size.Y / 2)
		end
	end
	if lowestY < math.huge then
		local lift = position.Y - lowestY
		model:PivotTo(CFrame.new(Vector3.new(position.X, position.Y + lift, position.Z)))
	end

	local finalPos = model.PrimaryPart and model.PrimaryPart.Position or position
	circle.CFrame = CFrame.new(finalPos.X, finalPos.Y - 2.5, finalPos.Z)
		* CFrame.Angles(0, 0, math.rad(90))

	return model
end

-- ============================================================
-- MOTOR6D BASE STORAGE
-- ============================================================

function Wanderer.StoreBaseC0s(model: Model)
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

function Wanderer.RestoreBaseC0s(model: Model)
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
-- WALK ANIMATION  (Wanderer itself never walks, but the
-- interface must be provided for TowerManager compatibility)
-- ============================================================

function Wanderer.StartWalk(model: Model)
	if walkTracks[model] then return end
	local st = getAnimState(model)
	safeStop(st.idleTrack,    0.15)
	safeStop(st.gunIdleTrack, 0.1)
	safeStop(st.shootTrack,   0.1)
	safeStop(st.lowerTrack,   0.15)
	safeStop(st.commandTrack, 0.1)
	st.gunState = "walking"

	local animator = getOrCreateAnimator(model)
	if not animator then return end
	local track = loadAndPlay(animator, WALK_ANIM_ID, true, Enum.AnimationPriority.Movement, 0.2)
	if track then walkTracks[model] = track end
end

function Wanderer.StopWalk(model: Model)
	local track = walkTracks[model]
	if track then
		safeStop(track, 0.2)
		task.delay(0.25, function() safeDestroy(track) end)
		walkTracks[model] = nil
	end
	Wanderer.RestoreBaseC0s(model)
	local st = animState[model]
	if st then st.gunState = "idle" end
end

-- ============================================================
-- PUBLIC – INIT
-- ============================================================

function Wanderer.InitTower(tower: Model)
	local st = getAnimState(tower)

	-- Spawn drone immediately so it is always live regardless of animation state
	spawnDrone(tower)
	st.gunState = "idle"

	-- Play deploy animation for visual effect (fire-and-forget)
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

-- Returns the drone's current world position, or nil if no live drone.
function Wanderer.GetDronePosition(tower: Model): Vector3?
	if not droneAlive[tower] then return nil end
	local drone = droneModels[tower]
	if not drone or not drone.Parent then return nil end
	if drone.PrimaryPart then
		return drone.PrimaryPart.Position
	end
	-- Fallback: use bounding box center when PrimaryPart is unset
	local firstPart = drone:FindFirstChildOfClass("BasePart")
	return firstPart and firstPart.Position or nil
end

-- Returns true while Reconnaissance is active.
function Wanderer.IsReconActive(tower: Model): boolean
	return reconActive[tower] == true
end

-- Face drone toward a world position (flat)
local function faceDroneToward(tower: Model, worldPos: Vector3)
	local drone = droneModels[tower]
	if not drone or not drone.PrimaryPart then return end

	local origin = drone.PrimaryPart.Position
	local flatDir = Vector3.new(worldPos.X - origin.X, 0, worldPos.Z - origin.Z)
	if flatDir.Magnitude < 0.1 then return end

	-- Flip 180° because the drone model's front face points backward
	drone:PivotTo(CFrame.new(origin, origin + flatDir.Unit) * CFrame.Angles(0, math.pi, 0))
end

-- ============================================================
-- PUBLIC – DRONE MOVEMENT
-- ============================================================

function Wanderer.MoveDrone(tower: Model, dest: Vector3)
	if not droneAlive[tower] then return end
	local drone = droneModels[tower]
	if not drone or not drone.PrimaryPart then return end

	local torso = tower.PrimaryPart
	if not torso then return end

	-- Clamp destination to within Wanderer's RNG
	local range = tower:GetAttribute("RNG") or 60
	local flatDiff = Vector3.new(dest.X - torso.Position.X, 0, dest.Z - torso.Position.Z)
	if flatDiff.Magnitude > range then
		local clamped = torso.Position + flatDiff.Unit * range
		dest = Vector3.new(clamped.X, dest.Y, clamped.Z)
	end

	-- Drone hovers a few studs above the ground
	local droneHeight = torso.Position.Y + 3
	dest = Vector3.new(dest.X, droneHeight, dest.Z)

	-- Make Wanderer face the direction of the drone command
	local flatDir = Vector3.new(dest.X - torso.Position.X, 0, dest.Z - torso.Position.Z)
	if flatDir.Magnitude > 0.1 then
		torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
	end

	-- Face drone toward destination immediately
	faceDroneToward(tower, dest)

	-- Play COMMAND animation on Wanderer
	local st = getAnimState(tower)
	if st.gunState ~= "walking" then
		local animator = getOrCreateAnimator(tower)
		if animator then
			safeStop(st.commandTrack, 0.1)
			st.commandTrack = loadAndPlay(
				animator, COMMAND_ANIM_ID, false,
				Enum.AnimationPriority.Action2, 0.1
			)
		end
	end

	-- Trigger Suppressing Fire at destination (if off cooldown)
	local now = tick()
	local cdEnd = suppressCooldownEnd[tower] or 0
	if now >= cdEnd then
		suppressCooldownEnd[tower] = now + Wanderer.SUPPRESS_COOLDOWN

		-- Clean up any existing zone
		local old = suppressData[tower]
		if old and old.zone and old.zone.Parent then old.zone:Destroy() end

		local zone = spawnSuppressingZone(dest)
		suppressData[tower] = {
			pos = Vector3.new(dest.X, 0, dest.Z), -- flat center for distance checks
			endTime = now + Wanderer.SUPPRESS_DURATION,
			lastTick = now - (Wanderer.SUPPRESS_DURATION + 0.1),
			zone = zone,
		}

		task.delay(Wanderer.SUPPRESS_DURATION, function()
			local d = suppressData[tower]
			if d and d.zone and d.zone.Parent then
				-- Fade out zone
				TweenService:Create(d.zone, TweenInfo.new(0.5), { Transparency = 1 }):Play()
				task.delay(0.6, function()
					if d.zone and d.zone.Parent then d.zone:Destroy() end
				end)
			end
		end)
	end

	-- Cancel any in-progress drone movement
	if activeDroneMovements[tower] then
		activeDroneMovements[tower]:Disconnect()
		activeDroneMovements[tower] = nil
	end

	-- Enable movement particles
	local dronePrimary = drone.PrimaryPart
	if dronePrimary then
		local moveAtt = dronePrimary:FindFirstChild("MoveAtt")
		local mp = moveAtt and moveAtt:FindFirstChildOfClass("ParticleEmitter")
		if mp then mp.Rate = 35 end
	end

	-- Smoothly move drone to destination
	local speed = Wanderer.DRONE_MOVE_SPEED
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not drone or not drone.PrimaryPart or not drone.Parent then
			conn:Disconnect()
			activeDroneMovements[tower] = nil
			return
		end

		local cur = drone.PrimaryPart.Position
		local flat = Vector3.new(dest.X - cur.X, 0, dest.Z - cur.Z)
		local dist = flat.Magnitude

		if dist < 0.3 then
			conn:Disconnect()
			activeDroneMovements[tower] = nil
			drone:PivotTo(CFrame.new(dest))
			-- Disable movement particles on arrival
			local dp2 = drone.PrimaryPart
			if dp2 then
				local ma2 = dp2:FindFirstChild("MoveAtt")
				local mp2 = ma2 and ma2:FindFirstChildOfClass("ParticleEmitter")
				if mp2 then mp2.Rate = 0 end
			end
			return
		end

		local step = flat.Unit * speed * dt
		local newPos = Vector3.new(cur.X + step.X, dest.Y, cur.Z + step.Z)

		if flat.Magnitude > 0.05 then
			drone:PivotTo(CFrame.new(newPos, newPos + flat.Unit) * CFrame.Angles(0, math.pi, 0))
		else
			drone:PivotTo(CFrame.new(newPos))
		end
	end)
	activeDroneMovements[tower] = conn
end

-- ============================================================
-- PUBLIC – SUPPRESSING FIRE TICK
-- ============================================================

function Wanderer.TickSuppressingFire(
	tower: Model,
	enemiesFolder: Folder,
	damageIndicatorRemote: RemoteEvent
)
	local data = suppressData[tower]
	if not data then return end

	local now = tick()
	if now >= data.endTime then
		-- Begin zone fade-out animation before cleanup
		local zone = data.zone
		if zone and zone.Parent then
			TweenService:Create(
				zone,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Transparency = 1 }
			):Play()

			-- Fully destroy the zone after the fade-out
			task.delay(0.6, function()
				if zone and zone.Parent then zone:Destroy() end
			end)
		end

		suppressData[tower] = nil
		return
	end

	-- Apply continuous bullet visuals (added earlier)
	local drone = droneModels[tower]
	if not drone or not drone.PrimaryPart then return end
	local droneOrigin = drone.PrimaryPart.Position

	local pos = data.pos
	local radius = Wanderer.SUPPRESS_RADIUS

	for _ = 1, 2 do
		local randomOffset = Vector3.new(
			math.random(-radius, radius),
			0,
			math.random(-radius, radius)
		)
		local targetPoint = pos + randomOffset
		spawnBullet(droneOrigin, targetPoint, false)
	end

	-- Apply damage tick (1 per second)
	if now - data.lastTick >= 1.0 then
		data.lastTick = now

		local atk = tower:GetAttribute("ATK") or 18
		local multi = tower:GetAttribute("DamageMulti") or 1.0
		local dps = atk * multi * Wanderer.SUPPRESS_DPS_MULTI

		for _, enemy in ipairs(enemiesFolder:GetChildren()) do
			if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
				local dVec = Vector3.new(
					enemy.PrimaryPart.Position.X - pos.X,
					0,
					enemy.PrimaryPart.Position.Z - pos.Z
				)
				local d = dVec.Magnitude
				if d <= radius then
					local hp = enemy:GetAttribute("HP") or 0
					local newHP = hp - dps
					enemy:SetAttribute("HP", newHP)
					if damageIndicatorRemote then
						damageIndicatorRemote:FireAllClients(enemy.PrimaryPart.Position, dps, "Normal")
					end
					if newHP <= 0 and enemy.Parent then
						enemy:Destroy()
					end
				end
			end
		end
	end
end

local function createRangeDisplay(radius: number, color: Color3): Part
	local rangeCircle = Instance.new("Part")
	rangeCircle.Name = "RangeDisplay"
	rangeCircle.Shape = Enum.PartType.Cylinder
	rangeCircle.Size = Vector3.new(0.1, radius * 2, radius * 2)
	rangeCircle.Transparency = 0.6
	rangeCircle.Color = color
	rangeCircle.Anchored = true
	rangeCircle.CanCollide = false
	rangeCircle.CastShadow = false
	rangeCircle.Material = Enum.Material.SmoothPlastic
	return rangeCircle
end

-- ============================================================
-- PUBLIC – RECONNAISSANCE
-- ============================================================

function Wanderer.ActivateReconnaissance(tower: Model)
	local now    = tick()
	local cdEnd  = reconCooldownEnd[tower] or 0
	if now < cdEnd then return end  -- on cooldown

	if not droneAlive[tower] then return end

	reconActive[tower]      = true
	reconEndAt[tower]       = now + Wanderer.RECON_DURATION
	reconCooldownEnd[tower] = now + Wanderer.RECON_COOLDOWN
	tower:SetAttribute("StrikeCooldownEnd", now + Wanderer.RECON_COOLDOWN)
	tower:SetAttribute("StrikeCooldownMax", Wanderer.RECON_COOLDOWN)

	-- Visual pulse from drone
	startReconPulse(tower)

	-- Auto-expire
	task.delay(Wanderer.RECON_DURATION, function()
		if not tower or not tower.Parent then return end
		reconActive[tower] = false
		-- Stop any remaining pulse connection
		local pc = reconPulseConnections[tower]
		if pc then pc:Disconnect(); reconPulseConnections[tower] = nil end
	end)
end

-- Called each Heartbeat frame to handle Recon expiry cleanly.
function Wanderer.TickReconnaissance(tower: Model)
	if not reconActive[tower] then return end
	if tick() >= (reconEndAt[tower] or 0) then
		reconActive[tower] = false
		local pc = reconPulseConnections[tower]
		if pc then pc:Disconnect(); reconPulseConnections[tower] = nil end
	end
end

-- Returns true if Reconnaissance is currently off cooldown.
function Wanderer.IsReconReady(tower: Model): boolean
	return tick() >= (reconCooldownEnd[tower] or 0)
end

-- ============================================================
-- PUBLIC – DRONE RESPAWN TICK
-- ============================================================

function Wanderer.TickDroneRespawn(tower: Model)
	if droneAlive[tower] then return end
	local respawnAt = droneRespawnAt[tower] or 0
	if tick() >= respawnAt then
		spawnDrone(tower)
	end
end

-- ============================================================
-- PUBLIC – ANIMATION INTERFACE
-- ============================================================

function Wanderer.IsReadyToFire(tower: Model): boolean
	if not reconActive[tower] then
		return true
	end
	local st = animState[tower]
	if not st then return false end
	return st.gunState == "shoot_hold" and tick() >= st.readyToFireTime
end

function Wanderer.UpdateCombatState(tower: Model, hasTarget: boolean, target: Instance?)
	local st = getAnimState(tower)
	if not st then return end
	if st.gunState == "walking" then return end

	-- Only animate Wanderer while Recon is active
	if not reconActive[tower] then
		if st.gunState ~= "idle" and st.gunState ~= "lowering" then
			triggerGunLower(tower, st)
		else
			if not (st.idleTrack and st.idleTrack.IsPlaying) then
				playIdle(tower, st)
			end
		end
		return
	end

	-- Lower gun after GUN_LOWER_DELAY with no shots
	if (st.gunState == "shoot_hold" or st.gunState == "raised") and
		(tick() - st.lastShotTime) >= Wanderer.GUN_LOWER_DELAY
	then
		triggerGunLower(tower, st)
		return
	end

	if hasTarget and target then
		if st.gunState == "idle" then
			triggerGunRaise(tower, st)
		end

		-- Face target
		if st.gunState == "raising" or st.gunState == "raised" or st.gunState == "shoot_hold" then
			local torso = tower.PrimaryPart
			local targetPart = (target :: Model).PrimaryPart
			if torso and targetPart then
				local flatDir = Vector3.new(
					targetPart.Position.X - torso.Position.X,
					0,
					targetPart.Position.Z - torso.Position.Z
				)
				if flatDir.Magnitude > 0.1 then
					torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
				end
			end
		end
	else
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

function Wanderer.DoAttack(tower: Model, target: Model, _enemiesFolder: Folder?): boolean
	local st = getAnimState(tower)
	if not st then return false end

	if not target or not target.Parent or not target.PrimaryPart then return false end

	local atk    = tower:GetAttribute("ATK")         or 18
	local multi  = tower:GetAttribute("DamageMulti")  or 1.0
	local isRecon = reconActive[tower] == true

	local impactPos = target.PrimaryPart.Position

	-- Determine firing origin
	local torso = tower.PrimaryPart
	local dronePos = Wanderer.GetDronePosition(tower)

	local fromPos: Vector3
	if isRecon then
		-- High Caliber: Wanderer fires from its own position
		local gunBarrel = torso and torso:FindFirstChild("GunBarrel")
		fromPos = gunBarrel and gunBarrel.WorldPosition or (torso and torso.Position) or impactPos
	else
		-- Heavy Rounds: Drone fires
		fromPos = dronePos or (torso and torso.Position) or impactPos
		faceDroneToward(tower, impactPos)
	end

	if isRecon then
		-- ── High Caliber (1.5× ATK) ──
		local damage = atk * multi * Wanderer.HIGH_CALIBER_MULTI
		local hp     = target:GetAttribute("HP") or 0
		local newHP  = hp - damage
		target:SetAttribute("HP", newHP)

		local indicatorRemote = ReplicatedStorage:FindFirstChild("ShowDamageIndicator")
		if indicatorRemote then
			indicatorRemote:FireAllClients(impactPos, damage, "Critical")
		end

		Wanderer.SpawnHitParticles(impactPos, Color3.fromRGB(255, 200, 60))
		spawnBullet(fromPos, impactPos, true)

		playShootBrief(tower, st)
		st.lastShotTime = tick()

		if newHP <= 0 and target.Parent then target:Destroy() end

	else
		-- ── Heavy Rounds: 2 shots × 0.5× ATK ──
		local damage = atk * multi * Wanderer.HEAVY_ROUNDS_MULTI

		-- Shot 1
		local hp1    = target:GetAttribute("HP") or 0
		local newHP1 = hp1 - damage
		target:SetAttribute("HP", newHP1)

		local indicatorRemote = ReplicatedStorage:FindFirstChild("ShowDamageIndicator")
		if indicatorRemote then
			indicatorRemote:FireAllClients(impactPos, damage, "Normal")
		end

		Wanderer.SpawnHitParticles(impactPos, Color3.fromRGB(180, 210, 255))
		spawnBullet(fromPos, impactPos, false)

		if newHP1 <= 0 and target.Parent then
			target:Destroy()
		else
			-- Shot 2 (slight delay for burst feel)
			task.delay(0.12, function()
				if not tower or not tower.Parent then return end
				if not target or not target.Parent or not target.PrimaryPart then return end

				local hp2    = target:GetAttribute("HP") or 0
				local newHP2 = hp2 - damage
				target:SetAttribute("HP", newHP2)

				local dr = ReplicatedStorage:FindFirstChild("ShowDamageIndicator")
				if dr then dr:FireAllClients(target.PrimaryPart.Position, damage, "Normal") end

				faceDroneToward(tower, target.PrimaryPart.Position)
				Wanderer.SpawnHitParticles(target.PrimaryPart.Position, Color3.fromRGB(180, 210, 255))
				spawnBullet(fromPos, target.PrimaryPart.Position, false)

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
	-- Stop animation tracks
	local st = animState[tower]
	if st then
		safeDestroy(st.idleTrack)
		safeDestroy(st.raiseTrack)
		safeDestroy(st.gunIdleTrack)
		safeDestroy(st.shootTrack)
		safeDestroy(st.lowerTrack)
		safeDestroy(st.commandTrack)
		animState[tower] = nil
	end

	baseC0s[tower] = nil

	local wt = walkTracks[tower]
	if wt then
		pcall(function() wt:Stop(0); wt:Destroy() end)
		walkTracks[tower] = nil
	end

	-- Drone
	if activeDroneMovements[tower] then
		activeDroneMovements[tower]:Disconnect()
		activeDroneMovements[tower] = nil
	end

	local drone = droneModels[tower]
	if drone and drone.Parent then drone:Destroy() end
	droneModels[tower]    = nil
	droneAlive[tower]     = nil
	droneRespawnAt[tower] = nil

	-- Recon
	local pc = reconPulseConnections[tower]
	if pc then pc:Disconnect(); reconPulseConnections[tower] = nil end
	reconActive[tower]      = nil
	reconEndAt[tower]       = nil
	reconCooldownEnd[tower] = nil

	-- Suppressing Fire
	local sd = suppressData[tower]
	if sd and sd.zone and sd.zone.Parent then sd.zone:Destroy() end
	suppressData[tower]        = nil
	suppressCooldownEnd[tower] = nil
end

return Wanderer