--[[
	Pathfinder Tower Module
	ServerScriptService/Towers/Pathfinder.luau

	Zone DPS | 6/7 Difficulty

	Passive: Between Existences
	  On Move, become Ghosted (1.2× speed, untargetable by enemies).
	  Cannot attack normally.
	  ATK SPD → Ability Haste at ⅓ rate, reducing ability cooldowns.

	Basic Attack: Reclamation
	  Upon reaching 4 WAYPOINTs placed, pull all active souls through
	  waypoints oldest-first, dealing 1× ATK per leg with 0.25× ATK
	  amplification per waypoint passed. Triggers only when a WAYPOINT
	  is in range.

	Move Skill: Anchor  (6 s CD)
	  On Move within 9 studs, dash to destination and plant a WAYPOINT.
	  Max 3 waypoints; placing a 4th removes the oldest.

	Strike Skill: Soulbind  (4 s CD)
	  Fire a spectral bolt at the targeted enemy, dealing 0.8× ATK.
	  Lodges a TETHERED SOUL for 8 s (max 4).  If host dies the soul
	  becomes UNTETHERED, hovering for 12 s before fading.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local ServerStorage     = game:GetService("ServerStorage")
local Workspace         = game:GetService("Workspace")
local CombatMath        = require(ReplicatedStorage:WaitForChild("CombatMath", 10))

local Pathfinder = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

Pathfinder.ANCHOR_COOLDOWN      = 6       -- Move Skill cooldown (s)
Pathfinder.ANCHOR_RANGE         = 9       -- Max dash range (studs)
Pathfinder.MAX_WAYPOINTS        = 3       -- Stored waypoints cap
Pathfinder.WAYPOINT_TRIGGER     = 4       -- Counter to trigger Reclamation
Pathfinder.GHOST_SPEED_MULT     = 1.2     -- Movement speed multiplier while ghosted
Pathfinder.ABILITY_HASTE_RATE   = 1 / 3   -- ATK_SPD → haste conversion

Pathfinder.SOULBIND_COOLDOWN    = 4       -- Strike Skill cooldown (s)
Pathfinder.SOULBIND_DAMAGE_MULT = 0.8     -- 0.8× ATK
Pathfinder.SOULBIND_DURATION    = 8       -- Tethered soul lifetime (s)
Pathfinder.MAX_SOULS            = 4       -- Max active tethered souls
Pathfinder.UNTETHERED_DURATION  = 12      -- Untethered soul hover time (s)
Pathfinder.SOULBIND_BOLT_SPEED  = 80      -- Spectral bolt speed (studs/s)
Pathfinder.SOULBIND_SNAP_RADIUS = 5       -- Snap-to-enemy radius (studs)

Pathfinder.RECLAMATION_BASE_MULT = 1.0    -- 1× ATK base per soul leg
Pathfinder.RECLAMATION_AMP       = 0.25   -- +0.25× ATK per waypoint passed
Pathfinder.SOUL_PULL_SPEED       = 25     -- Soul travel speed during Reclamation
Pathfinder.SOUL_HIT_RADIUS       = 3      -- Damage radius around soul path

Pathfinder.DASH_DURATION         = 0.35   -- Anchor dash time (s)

-- Animation IDs
local IDLE_ANIM_ID    = "rbxassetid://93663337842759"
local SPAWN_ANIM_ID   = "rbxassetid://118666124659463"
local SUMMON_ANIM_ID  = "rbxassetid://104035019425960"
local DASH_ANIM_ID    = "rbxassetid://112527657706925"
local WALK_ANIM_ID    = "rbxassetid://73323871613223"
local STRIKE_ANIM_ID  = "rbxassetid://95311978328925"
local BEAM_DISPLAY_DURATION = 0.08

-- ============================================================
-- STATE TABLES
-- ============================================================

local baseC0s          = {}   -- tower → { motorName = CFrame }
local walkTracks       = {}   -- tower → AnimationTrack
local animState        = {}   -- tower → { idleTrack, strikeTrack, … }

local waypointStore    = {}   -- tower → { waypoints = {}, counter = 0 }
local soulStore        = {}   -- tower → { tethered = {}, untethered = {} }

local anchorCDEnd      = {}   -- tower → tick when Anchor is ready
local soulbindCDEnd    = {}   -- tower → tick when Soulbind is ready

local ghostedState     = {}   -- tower → true/nil
local ghostTranspCache = {}   -- tower → { part → original transparency }
local reclamActive     = {}   -- tower → true/nil
local dashActiveMap    = {}   -- tower → true/nil
local pathMovements    = {}   -- tower → RBXScriptConnection

-- ============================================================
-- HELPERS
-- ============================================================

local function getOrCreateAnimator(model: Model): Animator?
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		local a = hum:FindFirstChildOfClass("Animator")
		if not a then a = Instance.new("Animator"); a.Parent = hum end
		return a
	end
	local ac = model:FindFirstChildOfClass("AnimationController")
	if ac then
		local a = ac:FindFirstChildOfClass("Animator")
		if not a then a = Instance.new("Animator"); a.Parent = ac end
		return a
	end
	return nil
end

local function safeStop(track, blend: number?)
	if track then pcall(function() if track.IsPlaying then track:Stop(blend or 0.1) end end) end
end

local function safeDestroy(track)
	if track then pcall(function() if track.IsPlaying then track:Stop(0) end; track:Destroy() end) end
end

local function loadAndPlay(animator: Animator, animId: string, looped: boolean,
		priority: Enum.AnimationPriority, blend: number?): AnimationTrack?
	local ok, t = pcall(function()
		local obj = Instance.new("Animation"); obj.AnimationId = animId
		local tr = animator:LoadAnimation(obj); obj:Destroy()
		tr.Looped = looped; tr.Priority = priority; tr:Play(blend or 0.1)
		return tr
	end)
	return ok and t or nil
end

local function getAnimSt(tower: Model)
	if not animState[tower] then
		animState[tower] = { idleTrack = nil, strikeTrack = nil, dashTrack = nil, summonTrack = nil }
	end
	return animState[tower]
end

local function getWD(tower: Model)
	if not waypointStore[tower] then
		waypointStore[tower] = { waypoints = {}, counter = 0 }
	end
	return waypointStore[tower]
end

local function getSD(tower: Model)
	if not soulStore[tower] then
		soulStore[tower] = { tethered = {}, untethered = {} }
	end
	return soulStore[tower]
end

local function playIdle(tower: Model, st)
	local anim = getOrCreateAnimator(tower); if not anim then return end
	safeDestroy(st.idleTrack)
	st.idleTrack = loadAndPlay(anim, IDLE_ANIM_ID, true, Enum.AnimationPriority.Idle, 0.2)
end

local function getEffectiveCooldown(tower: Model, baseCooldown: number): number
	local atkSpd = tower:GetAttribute("ATK_SPD") or 0.5
	local haste = atkSpd * Pathfinder.ABILITY_HASTE_RATE
	return baseCooldown / (1 + haste)
end

-- ============================================================
-- VFX: WAYPOINT PILLAR
-- ============================================================

local function createWaypointVFX(position: Vector3): Model
	local model = Instance.new("Model"); model.Name = "Waypoint"

	-- Spectral pillar
	local pillar       = Instance.new("Part")
	pillar.Name        = "Pillar"
	pillar.Shape       = Enum.PartType.Cylinder
	pillar.Size        = Vector3.new(4, 1.2, 1.2)
	pillar.Color       = Color3.fromRGB(120, 200, 255)
	pillar.Material    = Enum.Material.Neon
	pillar.Transparency = 0.3
	pillar.Anchored    = true
	pillar.CanCollide  = false
	pillar.CastShadow  = false
	pillar.CFrame      = CFrame.new(position + Vector3.new(0, 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	pillar.Parent      = model
	model.PrimaryPart  = pillar

	-- Ground ring
	local ring       = Instance.new("Part")
	ring.Name        = "Ring"
	ring.Shape       = Enum.PartType.Cylinder
	ring.Size        = Vector3.new(0.08, 2.4, 2.4)
	ring.Color       = Color3.fromRGB(80, 160, 255)
	ring.Material    = Enum.Material.Neon
	ring.Transparency = 0.4
	ring.Anchored    = true
	ring.CanCollide  = false
	ring.CastShadow  = false
	ring.CFrame      = CFrame.new(position + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent      = model

	-- Particles
	local att = Instance.new("Attachment"); att.Parent = pillar
	local pe  = Instance.new("ParticleEmitter")
	pe.Color          = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 200, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 100, 200)),
	})
	pe.LightEmission  = 1
	pe.LightInfluence = 0
	pe.Size           = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency   = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime       = NumberRange.new(0.5, 1.2)
	pe.Rate           = 15
	pe.Speed          = NumberRange.new(1, 3)
	pe.SpreadAngle    = Vector2.new(20, 20)
	pe.Parent         = att

	-- Point light
	local light      = Instance.new("PointLight")
	light.Color      = Color3.fromRGB(100, 180, 255)
	light.Brightness = 1.5
	light.Range      = 10
	light.Parent     = pillar

	model.Parent = Workspace
	return model
end

local function destroyWaypointVFX(vfx: Model?)
	if not vfx or not vfx.Parent then return end
	for _, p in ipairs(vfx:GetDescendants()) do
		if p:IsA("BasePart") then
			TweenService:Create(p, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		end
	end
	task.delay(0.4, function() if vfx and vfx.Parent then vfx:Destroy() end end)
end

-- ============================================================
-- VFX: SOUL ORB (tethered / untethered)
-- ============================================================

local function createSoulVFX(position: Vector3, tethered: boolean): Part
	local col = tethered and Color3.fromRGB(140, 220, 255) or Color3.fromRGB(180, 140, 255)

	local orb       = Instance.new("Part")
	orb.Name        = tethered and "TetheredSoul" or "UntetheredSoul"
	orb.Shape       = Enum.PartType.Ball
	orb.Size        = Vector3.new(0.8, 0.8, 0.8)
	orb.Color       = col
	orb.Material    = Enum.Material.Neon
	orb.Transparency = 0.2
	orb.Anchored    = true
	orb.CanCollide  = false
	orb.CastShadow  = false
	orb.CFrame      = CFrame.new(position)
	orb.Parent      = Workspace

	local att = Instance.new("Attachment"); att.Parent = orb
	local pe  = Instance.new("ParticleEmitter")
	pe.Color          = ColorSequence.new(col)
	pe.LightEmission  = 1
	pe.LightInfluence = 0
	pe.Size           = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency   = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime       = NumberRange.new(0.3, 0.7)
	pe.Rate           = 12
	pe.Speed          = NumberRange.new(0.5, 2)
	pe.SpreadAngle    = Vector2.new(180, 180)
	pe.Parent         = att

	local light      = Instance.new("PointLight")
	light.Color      = col
	light.Brightness = 1
	light.Range      = 6
	light.Parent     = orb

	return orb
end

local function destroySoulVFX(vfx: Part?)
	if not vfx or not vfx.Parent then return end
	TweenService:Create(vfx, TweenInfo.new(0.4), { Transparency = 1, Size = Vector3.new(0.1, 0.1, 0.1) }):Play()
	task.delay(0.5, function() if vfx and vfx.Parent then vfx:Destroy() end end)
end

-- ============================================================
-- VFX: GHOST (transparency + trail particles)
-- ============================================================

local function applyGhostVFX(tower: Model)
	local stored = {}
	for _, p in ipairs(tower:GetDescendants()) do
		if p:IsA("BasePart") and p.Name ~= "RangeCircle" then
			stored[p] = p.Transparency
			TweenService:Create(p, TweenInfo.new(0.2), { Transparency = math.max(p.Transparency, 0.5) }):Play()
		end
	end
	ghostTranspCache[tower] = stored

	local torso = tower.PrimaryPart
	if torso then
		local att   = Instance.new("Attachment"); att.Name = "GhostTrailAtt"; att.Parent = torso
		local trail = Instance.new("ParticleEmitter"); trail.Name = "GhostTrail"
		trail.Color          = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 200, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 100, 180)),
		})
		trail.LightEmission  = 0.8
		trail.LightInfluence = 0
		trail.Size           = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
		trail.Transparency   = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		trail.Lifetime       = NumberRange.new(0.3, 0.6)
		trail.Rate           = 25
		trail.Speed          = NumberRange.new(0.5, 2)
		trail.SpreadAngle    = Vector2.new(180, 180)
		trail.Parent         = att
	end
end

local function removeGhostVFX(tower: Model)
	local stored = ghostTranspCache[tower]
	if stored then
		for p, orig in pairs(stored) do
			if p and p.Parent then
				TweenService:Create(p, TweenInfo.new(0.3), { Transparency = orig }):Play()
			end
		end
		ghostTranspCache[tower] = nil
	end
	local torso = tower.PrimaryPart
	if torso then
		local att = torso:FindFirstChild("GhostTrailAtt")
		if att then att:Destroy() end
	end
end

-- ============================================================
-- VFX: SPECTRAL BOLT (Soulbind projectile)
-- ============================================================

local function spawnSpectralBolt(fromPos: Vector3, toPos: Vector3, onHit: () -> ())
	local dist = (toPos - fromPos).Magnitude
	if dist < 0.1 then onHit(); return end

	local anchorA = Instance.new("Part")
	anchorA.Anchored = true
	anchorA.CanCollide = false
	anchorA.CanQuery = false
	anchorA.CanTouch = false
	anchorA.Transparency = 1
	anchorA.Size = Vector3.new(0.05, 0.05, 0.05)
	anchorA.CFrame = CFrame.new(fromPos)
	anchorA.Parent = Workspace

	local anchorB = Instance.new("Part")
	anchorB.Anchored = true
	anchorB.CanCollide = false
	anchorB.CanQuery = false
	anchorB.CanTouch = false
	anchorB.Transparency = 1
	anchorB.Size = Vector3.new(0.05, 0.05, 0.05)
	anchorB.CFrame = CFrame.new(toPos)
	anchorB.Parent = Workspace

	local attA = Instance.new("Attachment")
	attA.Parent = anchorA
	local attB = Instance.new("Attachment")
	attB.Parent = anchorB

	local beam = Instance.new("Beam")
	beam.Attachment0 = attA
	beam.Attachment1 = attB
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Segments = 1
	beam.Width0 = 0.18
	beam.Width1 = 0.06
	beam.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 220, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 100, 180)),
	})
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 0.8),
	})
	beam.Parent = anchorA

	task.delay(BEAM_DISPLAY_DURATION, function()
		if anchorA and anchorA.Parent then anchorA:Destroy() end
		if anchorB and anchorB.Parent then anchorB:Destroy() end
	end)

	onHit()
end

-- ============================================================
-- VFX: RECLAMATION BEAM
-- ============================================================

local function spawnReclamationBeam(fromPos: Vector3, toPos: Vector3)
	local dir  = toPos - fromPos
	local dist = dir.Magnitude
	if dist < 0.1 then return end

	local mid  = fromPos + dir / 2
	local beam       = Instance.new("Part")
	beam.Name        = "ReclamationBeam"
	beam.Size        = Vector3.new(0.2, 0.2, dist)
	beam.Color       = Color3.fromRGB(100, 180, 255)
	beam.Material    = Enum.Material.Neon
	beam.Transparency = 0.3
	beam.Anchored    = true
	beam.CanCollide  = false
	beam.CastShadow  = false
	beam.CFrame      = CFrame.new(mid, toPos)
	beam.Parent      = Workspace

	TweenService:Create(beam, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
		Size = Vector3.new(0.05, 0.05, dist),
	}):Play()
	task.delay(0.7, function() if beam and beam.Parent then beam:Destroy() end end)
end

-- ============================================================
-- VFX: HIT PARTICLES
-- ============================================================

function Pathfinder.SpawnHitParticles(position: Vector3, color: Color3?)
	local c = color or Color3.fromRGB(120, 200, 255)

	local anchor       = Instance.new("Part")
	anchor.Name        = "PathfinderHitAnchor"
	anchor.Size        = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored    = true
	anchor.CanCollide  = false
	anchor.Position    = position
	anchor.Parent      = Workspace

	local att = Instance.new("Attachment"); att.Parent = anchor
	local pe  = Instance.new("ParticleEmitter")
	pe.Color        = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(200, 240, 255)),
		ColorSequenceKeypoint.new(0.5, c),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(40, 60, 100)),
	})
	pe.Size         = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime     = NumberRange.new(0.15, 0.35)
	pe.Speed        = NumberRange.new(5, 14)
	pe.SpreadAngle  = Vector2.new(180, 90)
	pe.Acceleration = Vector3.new(0, -10, 0)
	pe.Rate         = 0
	pe.Parent       = att
	pe:Emit(10)

	task.delay(0.5, function() if anchor and anchor.Parent then anchor:Destroy() end end)
end

-- ============================================================
-- VFX: DASH IMPACT RING
-- ============================================================

local function spawnDashImpact(position: Vector3)
	local ring       = Instance.new("Part")
	ring.Name        = "DashImpact"
	ring.Shape       = Enum.PartType.Cylinder
	ring.Size        = Vector3.new(0.08, 0.5, 0.5)
	ring.Color       = Color3.fromRGB(120, 200, 255)
	ring.Material    = Enum.Material.Neon
	ring.Transparency = 0.2
	ring.Anchored    = true
	ring.CanCollide  = false
	ring.CastShadow  = false
	ring.CFrame      = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent      = Workspace

	TweenService:Create(ring, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.04, 6, 6), Transparency = 1,
	}):Play()
	task.delay(0.6, function() if ring and ring.Parent then ring:Destroy() end end)
end

-- ============================================================
-- GHOST STATE
-- ============================================================

function Pathfinder.SetGhosted(tower: Model, ghosted: boolean)
	if ghosted then
		if ghostedState[tower] then return end
		ghostedState[tower] = true
		tower:SetAttribute("Ghosted", true)
		applyGhostVFX(tower)
	else
		if not ghostedState[tower] then return end
		ghostedState[tower] = nil
		tower:SetAttribute("Ghosted", false)
		removeGhostVFX(tower)
	end
end

function Pathfinder.IsGhosted(tower: Model): boolean
	return ghostedState[tower] == true
end

-- ============================================================
-- CREATE MODEL
-- ============================================================

function Pathfinder.CreateModel(position: Vector3, TowerStats: any): Model?
	local template = TowerStats.Templates["Pathfinder"]
	if not template then return nil end

	local towerModels   = ServerStorage:FindFirstChild("TowerModels")
	local templateModel = towerModels and towerModels:FindFirstChild("Pathfinder")

	local model
	if templateModel then
		model = templateModel:Clone()
	else
		-- Procedural fallback
		model = Instance.new("Model")
		local ghostColor = Color3.fromRGB(90, 140, 200)

		local torso        = Instance.new("Part")
		torso.Name         = "Torso"
		torso.Size         = Vector3.new(2, 2.4, 1.2)
		torso.Color        = ghostColor
		torso.Material     = Enum.Material.SmoothPlastic
		torso.Anchored     = true
		torso.CanCollide   = false
		torso.CFrame       = CFrame.new(position + Vector3.new(0, 3.5, 0))
		torso.Parent       = model
		model.PrimaryPart  = torso

		local head       = Instance.new("Part")
		head.Name        = "Head"
		head.Shape       = Enum.PartType.Ball
		head.Size        = Vector3.new(1.4, 1.4, 1.4)
		head.Color       = ghostColor
		head.Material    = Enum.Material.SmoothPlastic
		head.Anchored    = true
		head.CanCollide  = false
		head.CFrame      = CFrame.new(position + Vector3.new(0, 5.6, 0))
		head.Parent      = model

		local hum = Instance.new("Humanoid"); hum.Parent = model
	end

	model.Name = "Pathfinder"
	if model.PrimaryPart then model.PrimaryPart.Anchored = true end

	local rangeStuds = template.RNG

	-- Range circle
	local circle       = Instance.new("Part")
	circle.Name        = "RangeCircle"
	circle.Shape       = Enum.PartType.Cylinder
	circle.Size        = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored    = true
	circle.CanCollide  = false
	circle.Color       = Color3.fromRGB(100, 180, 255)
	circle.Transparency = 1
	circle.Material    = Enum.Material.SmoothPlastic
	circle.Parent      = model

	model:SetAttribute("ATK",         template.ATK)
	model:SetAttribute("ATK_SPD",     template.ATK_SPD)
	model:SetAttribute("RNG",         rangeStuds)
	model:SetAttribute("HP",          template.HP)
	model:SetAttribute("MaxHP",       template.HP)
	model:SetAttribute("DEF",         template.DEF or 0)
	model:SetAttribute("MOVE_SPD",    template.MOVE_SPD)
	model:SetAttribute("DamageMulti", template.DamageMulti or 1.0)
	model:SetAttribute("AttackType",  template.AttackType  or "Zone")
	model:SetAttribute("State",       "Idle")
	model:SetAttribute("Owner",       "")
	model:SetAttribute("TowerType",   "Pathfinder")
	model:SetAttribute("Ghosted",     false)

	model:PivotTo(CFrame.new(position))

	-- Ground-snap
	local lowestY = math.huge
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p.Name ~= "RangeCircle" then
			lowestY = math.min(lowestY, p.Position.Y - p.Size.Y / 2)
		end
	end
	if lowestY < math.huge then
		model:PivotTo(CFrame.new(Vector3.new(position.X, position.Y + (position.Y - lowestY), position.Z)))
	end

	local finalPos = model.PrimaryPart and model.PrimaryPart.Position or position
	circle.CFrame = CFrame.new(finalPos.X, finalPos.Y - 2.5, finalPos.Z)
		* CFrame.Angles(0, 0, math.rad(90))

	return model
end

-- ============================================================
-- INIT / CLEANUP
-- ============================================================

function Pathfinder.InitTower(tower: Model)
	local st = getAnimSt(tower)
	getWD(tower)
	getSD(tower)

	local animator = getOrCreateAnimator(tower)
	if animator then
		local spawn = loadAndPlay(animator, SPAWN_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.1)
		if spawn then
			task.spawn(function()
				spawn.Stopped:Wait()
				if tower and tower.Parent then playIdle(tower, st) end
			end)
			return
		end
	end
	playIdle(tower, st)
end

function Pathfinder.StoreBaseC0s(model: Model)
	if baseC0s[model] then return end
	local torso = model.PrimaryPart; if not torso then return end
	local stored = {}
	for _, n in ipairs({"Neck", "LeftShoulder", "RightShoulder", "LeftHip", "RightHip"}) do
		local motor = torso:FindFirstChild(n)
		if motor then stored[n] = motor.C0 end
	end
	baseC0s[model] = stored
end

function Pathfinder.RestoreBaseC0s(model: Model)
	local stored = baseC0s[model]; if not stored then return end
	local torso = model.PrimaryPart; if not torso then return end
	for n, c0 in pairs(stored) do
		local motor = torso:FindFirstChild(n)
		if motor then motor.C0 = c0 end
	end
end

function Pathfinder.StartWalk(model: Model)
	if walkTracks[model] then return end
	local st = getAnimSt(model)
	safeStop(st.idleTrack, 0.15)
	local animator = getOrCreateAnimator(model); if not animator then return end
	walkTracks[model] = loadAndPlay(animator, WALK_ANIM_ID, true, Enum.AnimationPriority.Movement, 0.2)
end

function Pathfinder.StopWalk(model: Model)
	local track = walkTracks[model]
	if track then
		safeStop(track, 0.2)
		task.delay(0.25, function() safeDestroy(track) end)
		walkTracks[model] = nil
	end
	Pathfinder.RestoreBaseC0s(model)
end

function Pathfinder.CleanupTower(tower: Model)
	local st = animState[tower]
	if st then
		safeDestroy(st.idleTrack)
		safeDestroy(st.strikeTrack)
		safeDestroy(st.dashTrack)
		safeDestroy(st.summonTrack)
		animState[tower] = nil
	end
	safeDestroy(walkTracks[tower]); walkTracks[tower] = nil
	baseC0s[tower] = nil

	local wd = waypointStore[tower]
	if wd then
		for _, wp in ipairs(wd.waypoints) do destroyWaypointVFX(wp.vfx) end
		waypointStore[tower] = nil
	end
	local sd = soulStore[tower]
	if sd then
		for _, s in ipairs(sd.tethered)   do destroySoulVFX(s.vfx) end
		for _, s in ipairs(sd.untethered) do destroySoulVFX(s.vfx) end
		soulStore[tower] = nil
	end

	anchorCDEnd[tower]      = nil
	soulbindCDEnd[tower]    = nil
	ghostedState[tower]     = nil
	ghostTranspCache[tower] = nil
	reclamActive[tower]     = nil
	dashActiveMap[tower]    = nil
	if pathMovements[tower] then pathMovements[tower]:Disconnect(); pathMovements[tower] = nil end
	tower:SetAttribute("Ghosted", false)
end

-- ============================================================
-- COMBAT INTERFACE (required by TowerManager)
-- ============================================================

function Pathfinder.IsReadyToFire(_tower: Model): boolean
	return false -- cannot attack normally
end

function Pathfinder.DoAttack(_tower: Model, _target: Model, _enemiesFolder: Folder?): boolean
	return false -- cannot attack normally
end

function Pathfinder.UpdateCombatState(tower: Model, _hasTarget: boolean, _target: Instance?)
	local st = getAnimSt(tower)
	if not dashActiveMap[tower] and not reclamActive[tower] then
		local playing = st.idleTrack and pcall(function() return st.idleTrack.IsPlaying end) and st.idleTrack.IsPlaying
		if not playing then playIdle(tower, st) end
	end
end

-- ============================================================
-- MOVE SKILL: ANCHOR  (Dash + Waypoint)
-- ============================================================

local function addWaypoint(tower: Model, position: Vector3)
	local wd = getWD(tower)
	if #wd.waypoints >= Pathfinder.MAX_WAYPOINTS then
		local oldest = table.remove(wd.waypoints, 1)
		destroyWaypointVFX(oldest.vfx)
	end
	table.insert(wd.waypoints, { pos = position, vfx = createWaypointVFX(position) })
	wd.counter = wd.counter + 1
end

local function performDash(tower: Model, dest: Vector3, onComplete: () -> ())
	local torso = tower.PrimaryPart
	if not torso then onComplete(); return end

	dashActiveMap[tower] = true
	tower:SetAttribute("State", "Leaping")

	local st   = getAnimSt(tower)
	local anim = getOrCreateAnimator(tower)
	if anim then
		safeStop(st.idleTrack, 0.1)
		st.dashTrack = loadAndPlay(anim, DASH_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.05)
	end

	local flatDir = Vector3.new(dest.X - torso.Position.X, 0, dest.Z - torso.Position.Z)
	if flatDir.Magnitude > 0.1 then
		torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
	end

	local startPos = torso.Position
	local duration = Pathfinder.DASH_DURATION
	local elapsed  = 0
	local conn; conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local eased = 1 - (1 - alpha) ^ 2

		if not torso or not torso.Parent then
			conn:Disconnect(); dashActiveMap[tower] = nil; onComplete(); return
		end

		local newPos  = startPos:Lerp(dest, eased)
		local lookDir = Vector3.new(dest.X - startPos.X, 0, dest.Z - startPos.Z)
		if lookDir.Magnitude > 0.1 then
			torso.CFrame = CFrame.new(newPos, newPos + lookDir.Unit)
		else
			torso.CFrame = CFrame.new(newPos) * (torso.CFrame - torso.CFrame.Position)
		end

		if alpha >= 1 then
			conn:Disconnect()
			dashActiveMap[tower] = nil
			spawnDashImpact(dest)
			onComplete()
		end
	end)
end

function Pathfinder.HandleMove(tower: Model, dest: Vector3, updateCircleFn: ((Model, Vector3) -> ())?)
	local torso = tower.PrimaryPart; if not torso then return end

	-- Cancel existing movement
	if pathMovements[tower] then pathMovements[tower]:Disconnect(); pathMovements[tower] = nil end

	-- Ghosted passive always activates on move
	Pathfinder.SetGhosted(tower, true)

	local startPos = torso.Position
	local flatDist = (Vector3.new(dest.X, 0, dest.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude

	local now         = tick()
	local anchorReady = now >= (anchorCDEnd[tower] or 0)
	local effectiveCD = getEffectiveCooldown(tower, Pathfinder.ANCHOR_COOLDOWN)

	if flatDist <= Pathfinder.ANCHOR_RANGE and anchorReady then
		-- ═══ ANCHOR: Dash + Waypoint ═══
		anchorCDEnd[tower] = now + effectiveCD
		tower:SetAttribute("MoveCooldownEnd", now + effectiveCD)
		tower:SetAttribute("MoveCooldownMax", effectiveCD)

		local anim = getOrCreateAnimator(tower)
		local st   = getAnimSt(tower)
		if anim then
			safeDestroy(st.summonTrack)
			st.summonTrack = loadAndPlay(anim, SUMMON_ANIM_ID, false, Enum.AnimationPriority.Action3, 0.05)
		end

		performDash(tower, dest, function()
			if not tower or not tower.Parent then return end
			addWaypoint(tower, dest)
			task.delay(0.3, function()
				if not tower or not tower.Parent then return end
				Pathfinder.SetGhosted(tower, false)
				tower:SetAttribute("State", "Idle")
				if updateCircleFn and torso and torso.Parent then
					updateCircleFn(tower, torso.Position)
				end
				playIdle(tower, getAnimSt(tower))
			end)
		end)
	else
		-- ═══ NORMAL WALK (with ghosted speed) ═══
		tower:SetAttribute("State", "Moving")
		Pathfinder.StartWalk(tower)

		local baseSpeed = tower:GetAttribute("MOVE_SPD") or 16
		local speed     = baseSpeed * Pathfinder.GHOST_SPEED_MULT

		local conn; conn = RunService.Heartbeat:Connect(function(dt)
			if not torso or not torso.Parent then
				conn:Disconnect(); pathMovements[tower] = nil
				Pathfinder.SetGhosted(tower, false)
				return
			end

			local cur  = torso.Position
			local flat = Vector3.new(dest.X - cur.X, 0, dest.Z - cur.Z)
			local dist = flat.Magnitude

			if dist < 0.5 then
				conn:Disconnect(); pathMovements[tower] = nil
				tower:SetAttribute("State", "Idle")
				Pathfinder.StopWalk(tower)
				Pathfinder.SetGhosted(tower, false)
				if updateCircleFn then updateCircleFn(tower, cur) end
				return
			end

			local moveDir = flat.Unit
			local step    = moveDir * speed * dt
			if step.Magnitude > dist then step = moveDir * dist end
			local newPos = cur + step

			local tCF    = CFrame.new(newPos, newPos + moveDir)
			local curRot = torso.CFrame - torso.CFrame.Position
			local tRot   = tCF - tCF.Position
			torso.CFrame = curRot:Lerp(tRot, math.clamp(dt * 8, 0, 1)) + newPos

			if updateCircleFn then updateCircleFn(tower, newPos) end
		end)
		pathMovements[tower] = conn
	end
end

-- ============================================================
-- STRIKE SKILL: SOULBIND
-- ============================================================

function Pathfinder.IsSoulbindReady(tower: Model): boolean
	return tick() >= (soulbindCDEnd[tower] or 0)
end

function Pathfinder.FireSoulbind(tower: Model, targetPos: Vector3, enemiesFolder: Folder, damageRemote: RemoteEvent?)
	local torso = tower.PrimaryPart; if not torso then return end

	local now         = tick()
	local effectiveCD = getEffectiveCooldown(tower, Pathfinder.SOULBIND_COOLDOWN)
	soulbindCDEnd[tower] = now + effectiveCD
	tower:SetAttribute("StrikeCooldownEnd", now + effectiveCD)
	tower:SetAttribute("StrikeCooldownMax", effectiveCD)

	local sd = getSD(tower)

	-- Find nearest enemy to click position
	local bestEnemy: Model? = nil
	local bestDist = math.huge
	for _, enemy in ipairs(enemiesFolder:GetChildren()) do
		if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
			local d = (enemy.PrimaryPart.Position - targetPos).Magnitude
			if d < bestDist and d <= Pathfinder.SOULBIND_SNAP_RADIUS then
				bestDist = d; bestEnemy = enemy
			end
		end
	end
	if not bestEnemy or not bestEnemy.PrimaryPart then return end

	-- Range check from tower
	local rng = tower:GetAttribute("RNG") or 20
	if (bestEnemy.PrimaryPart.Position - torso.Position).Magnitude > rng then return end

	-- Face target
	local flatDir = Vector3.new(
		bestEnemy.PrimaryPart.Position.X - torso.Position.X, 0,
		bestEnemy.PrimaryPart.Position.Z - torso.Position.Z
	)
	if flatDir.Magnitude > 0.1 then
		torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
	end

	-- Play strike animation
	local st   = getAnimSt(tower)
	local anim = getOrCreateAnimator(tower)
	if anim then
		safeDestroy(st.strikeTrack)
		st.strikeTrack = loadAndPlay(anim, STRIKE_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.05)
	end

	local fromPos   = torso.Position
	local impactPos = bestEnemy.PrimaryPart.Position

	spawnSpectralBolt(fromPos, impactPos, function()
		if not bestEnemy or not bestEnemy.Parent or not bestEnemy.PrimaryPart then return end

		local atk    = tower:GetAttribute("ATK") or 14
		local multi  = tower:GetAttribute("DamageMulti") or 1.0
		local rawDamage = atk * multi * Pathfinder.SOULBIND_DAMAGE_MULT
		local damage = CombatMath.ApplyDefense(rawDamage, bestEnemy:GetAttribute("DEF") or 0)

		local hp    = bestEnemy:GetAttribute("HP") or 0
		local newHP = hp - damage
		bestEnemy:SetAttribute("HP", newHP)

		if damageRemote then
			damageRemote:FireAllClients(impactPos, damage, "Normal")
		end
		Pathfinder.SpawnHitParticles(impactPos, Color3.fromRGB(140, 220, 255))

		-- Lodge tethered soul
		if #sd.tethered < Pathfinder.MAX_SOULS then
			table.insert(sd.tethered, {
				enemy      = bestEnemy,
				attachedAt = tick(),
				vfx        = createSoulVFX(impactPos, true),
			})
		end

		if newHP <= 0 and bestEnemy.Parent then bestEnemy:Destroy() end
	end)
end

-- ============================================================
-- SOUL TICK  (update positions, handle expiry)
-- ============================================================

function Pathfinder.TickSouls(tower: Model, _enemiesFolder: Folder)
	local sd  = getSD(tower)
	local now = tick()

	-- Tethered souls
	local i = 1
	while i <= #sd.tethered do
		local soul  = sd.tethered[i]
		local enemy = soul.enemy

		if now - soul.attachedAt >= Pathfinder.SOULBIND_DURATION then
			destroySoulVFX(soul.vfx); table.remove(sd.tethered, i); continue
		end

		if not enemy or not enemy.Parent or (enemy:GetAttribute("HP") or 0) <= 0 then
			local deathPos = (soul.vfx and soul.vfx.Parent)
				and soul.vfx.Position or Vector3.new(0, 5, 0)
			destroySoulVFX(soul.vfx); table.remove(sd.tethered, i)
			table.insert(sd.untethered, {
				pos = deathPos, createdAt = now, vfx = createSoulVFX(deathPos, false),
			})
			continue
		end

		if soul.vfx and soul.vfx.Parent and enemy.PrimaryPart then
			soul.vfx.CFrame = CFrame.new(enemy.PrimaryPart.Position + Vector3.new(0, 2, 0))
		end
		i += 1
	end

	-- Untethered souls
	local j = 1
	while j <= #sd.untethered do
		local soul = sd.untethered[j]
		if now - soul.createdAt >= Pathfinder.UNTETHERED_DURATION then
			destroySoulVFX(soul.vfx); table.remove(sd.untethered, j); continue
		end
		if soul.vfx and soul.vfx.Parent then
			local bob = math.sin((now - soul.createdAt) * 3) * 0.3
			soul.vfx.CFrame = CFrame.new(soul.pos + Vector3.new(0, bob, 0))
		end
		j += 1
	end
end

-- ============================================================
-- RECLAMATION  (Basic Attack – chain pull)
-- ============================================================

local function collectAllSouls(tower: Model): { { pos: Vector3, vfx: Part? } }
	local sd    = getSD(tower)
	local souls = {}
	for _, s in ipairs(sd.tethered) do
		local p = s.vfx and s.vfx.Parent and s.vfx.Position
		if p then table.insert(souls, { pos = p, vfx = s.vfx }) end
	end
	for _, s in ipairs(sd.untethered) do
		local p = s.vfx and s.vfx.Parent and s.vfx.Position
		if p then table.insert(souls, { pos = p, vfx = s.vfx }) end
	end
	return souls
end

local function damageAlongPath(fromPos: Vector3, toPos: Vector3, damage: number, enemiesFolder: Folder, hit: {[Model]: boolean})
	local dir  = toPos - fromPos
	local dist = dir.Magnitude
	if dist < 0.1 then return hit end
	dir = dir.Unit
	local radius = Pathfinder.SOUL_HIT_RADIUS

	for _, enemy in ipairs(enemiesFolder:GetChildren()) do
		if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
			if hit[enemy] then continue end
			local ep = enemy.PrimaryPart.Position
			local t  = math.clamp((ep - fromPos):Dot(dir), 0, dist)
			if (ep - (fromPos + dir * t)).Magnitude <= radius then
				hit[enemy] = true
				local hp    = enemy:GetAttribute("HP") or 0
				local dealt = CombatMath.ApplyDefense(damage, enemy:GetAttribute("DEF") or 0)
				local newHP = hp - dealt
				enemy:SetAttribute("HP", newHP)
				local remote = ReplicatedStorage:FindFirstChild("ShowDamageIndicator")
				if remote then remote:FireAllClients(ep, dealt, "Normal") end
				Pathfinder.SpawnHitParticles(ep, Color3.fromRGB(120, 200, 255))
				if newHP <= 0 and enemy.Parent then enemy:Destroy() end
			end
		end
	end
	return hit
end

function Pathfinder.TriggerReclamation(tower: Model, enemiesFolder: Folder)
	if reclamActive[tower] then return end
	reclamActive[tower] = true

	local wd    = getWD(tower)
	local sd    = getSD(tower)
	local torso = tower.PrimaryPart
	local souls = collectAllSouls(tower)

	local waypoints = {}
	for _, wp in ipairs(wd.waypoints) do table.insert(waypoints, wp.pos) end

	local towerPos = torso and torso.Position or Vector3.new(0, 5, 0)
	local atk      = tower:GetAttribute("ATK") or 14
	local multi    = tower:GetAttribute("DamageMulti") or 1.0

	-- Play strike animation
	local st   = getAnimSt(tower)
	local anim = getOrCreateAnimator(tower)
	if anim then
		safeDestroy(st.strikeTrack)
		st.strikeTrack = loadAndPlay(anim, STRIKE_ANIM_ID, false, Enum.AnimationPriority.Action4, 0.05)
	end

	task.spawn(function()
		for sIdx, soul in ipairs(souls) do
			local curPos      = soul.pos
			local curDmgMult  = Pathfinder.RECLAMATION_BASE_MULT
			local hitEnemies  = {}

			for _, wpPos in ipairs(waypoints) do
				local legDamage = atk * multi * curDmgMult
				spawnReclamationBeam(curPos, wpPos)

				-- Animate soul to waypoint
				local dir  = wpPos - curPos
				local dist = dir.Magnitude
				if dist > 0.1 then
					local travelTime = dist / Pathfinder.SOUL_PULL_SPEED
					local elapsed    = 0
					while elapsed < travelTime do
						local dt = task.wait()
						elapsed += dt
						local alpha = math.clamp(elapsed / travelTime, 0, 1)
						if soul.vfx and soul.vfx.Parent then
							soul.vfx.CFrame = CFrame.new(curPos:Lerp(wpPos, alpha))
						end
					end
					damageAlongPath(curPos, wpPos, legDamage, enemiesFolder, hitEnemies)
				end

				curDmgMult = curDmgMult + Pathfinder.RECLAMATION_AMP
				curPos     = wpPos
				task.wait(0.05)
			end

			-- Final leg → tower
			if torso and torso.Parent then
				local finalPos    = torso.Position
				local finalDamage = atk * multi * curDmgMult
				spawnReclamationBeam(curPos, finalPos)

				local dir  = finalPos - curPos
				local dist = dir.Magnitude
				if dist > 0.1 then
					local travelTime = dist / Pathfinder.SOUL_PULL_SPEED
					local elapsed    = 0
					while elapsed < travelTime do
						local dt = task.wait()
						elapsed += dt
						local alpha = math.clamp(elapsed / travelTime, 0, 1)
						if soul.vfx and soul.vfx.Parent then
							soul.vfx.CFrame = CFrame.new(curPos:Lerp(finalPos, alpha))
						end
					end
					damageAlongPath(curPos, finalPos, finalDamage, enemiesFolder, hitEnemies)
				end
			end

			destroySoulVFX(soul.vfx)
			if sIdx < #souls then task.wait(0.1) end
		end

		-- Consume waypoints
		for _, wp in ipairs(wd.waypoints) do destroyWaypointVFX(wp.vfx) end
		wd.waypoints = {}
		wd.counter   = 0

		-- Clear souls
		sd.tethered   = {}
		sd.untethered = {}

		reclamActive[tower] = nil
	end)
end

function Pathfinder.TickReclamation(tower: Model, enemiesFolder: Folder)
	if reclamActive[tower] then return end

	local wd = getWD(tower)
	local sd = getSD(tower)

	if wd.counter < Pathfinder.WAYPOINT_TRIGGER then return end
	if #wd.waypoints == 0 then return end

	-- At least one waypoint within tower range
	local torso = tower.PrimaryPart; if not torso then return end
	local rng   = tower:GetAttribute("RNG") or 20
	local inRange = false
	for _, wp in ipairs(wd.waypoints) do
		if (wp.pos - torso.Position).Magnitude <= rng then inRange = true; break end
	end
	if not inRange then return end

	-- Must have souls
	if #sd.tethered + #sd.untethered == 0 then return end

	Pathfinder.TriggerReclamation(tower, enemiesFolder)
end

return Pathfinder
