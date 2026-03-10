--[[
	Vitalist (ModuleScript)
	Place in ServerScriptService/Towers/

	Hybrid Medic | 5/7 Difficulty

	Abilities
	  - Basic Attack  – C-310 Mendor:
	      Fires in bursts of 8 hitscan shots from the gun barrel.
	      ATK mode  : each shot deals 0.125× ATK to the targeted enemy.
	      SUPP mode : each shot heals 0.125× ATK to the nearest ally tower.
	      Each bullet adds 1 Charge (max 40). At 40 Charge the next
	      basic attack is replaced by Nano Blast.

	  - Enhanced Attack – Nano Blast:
	      Fires one large energy burst (hitscan laser from the gun barrel).
	      ATK mode  : blue laser to the targeted enemy,   2× AP damage,
	                  pierces all enemies along the beam.
	      SUPP mode : green laser to the nearest ally tower, 2× AP healing.
	      Resets Charge to 0; triggers a reload animation.
	      VFX + damage fire only AFTER the enhanced-shoot animation ends.

	  - Move Skill – Combat Protocol:
	      On Move, if the destination is ≤ 8 studs from the tower,
	      the tower switches between ATK and SUPP protocols.

	Targeting
	  ATK  : "First" – enemy with the highest WaypointIndex in range
	          (ties broken by proximity).
	  SUPP : nearest ally tower in range that is below MaxHP.

	Animation state machine
	  idle  →  raising  →  shoot_hold  →  (no target 3 s)  →  lowering  →  idle
	  shoot_hold  →  (burst fires)  →  shoot_hold
	  shoot_hold  →  (Nano Blast fires)  →  reloading  →  shoot_hold
	  Any state  →  walking  (on player move)
	  walking  →  idle  (on arrival)
	  Any state  →  protocol_switch  (on short move)

	Animation IDs
	  Idle           : 98169705964556   (looped)
	  Gun Raise      : 101238020869924  (one-shot)
	  Gun Idle       : 93669945158951   (looped, raised pose)
	  Gun Shoot      : 113123940530235  (one-shot per bullet; cycle 8×)
	  Enhanced Shoot : 119922322699649  (one-shot)
	  Gun Reload     : 87714279300663   (one-shot)
	  Gun Lower      : 134321960932781  (one-shot)
	  Protocol Switch: 112311342264233  (one-shot)
	  Walk           : 73323871613223   (looped)
]]

local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")
local ServerStorage     = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Vitalist = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

Vitalist.BULLETS_PER_BURST      = 8      -- bullets per basic attack
Vitalist.MAX_CHARGE             = 40     -- charge needed for Nano Blast
Vitalist.PROTOCOL_SWITCH_RANGE  = 8      -- studs; move within this → switch protocol
Vitalist.GUN_RAISE_DELAY        = 0.15   -- seconds after raise before first shot
Vitalist.GUN_LOWER_DELAY        = 3.0    -- seconds without a shot → lower gun
Vitalist.BURST_SHOT_INTERVAL    = 0.065   -- seconds between individual burst shots
Vitalist.NANO_PIERCE_RADIUS     = 4.5    -- studs off-axis; enemies within this are pierced

-- ====== ANIMATION IDs ======
local IDLE_ANIM_ID            = "rbxassetid://98169705964556"
local RAISE_ANIM_ID           = "rbxassetid://101238020869924"
local GUN_IDLE_ANIM_ID        = "rbxassetid://93669945158951"
local SHOOT_ANIM_ID           = "rbxassetid://113123940530235"
local ENHANCED_SHOOT_ANIM_ID  = "rbxassetid://119922322699649"
local RELOAD_ANIM_ID          = "rbxassetid://87714279300663"
local LOWER_ANIM_ID           = "rbxassetid://134321960932781"
local PROTOCOL_SWITCH_ANIM_ID = "rbxassetid://112311342264233"
local WALK_ANIM_ID            = "rbxassetid://73323871613223"

-- ====== VFX COLOURS ======
local SUPP_COLOR = Color3.fromRGB(50, 220, 80)   -- green (healing)
local ATK_COLOR  = Color3.fromRGB(50, 150, 255)  -- blue  (damage)

-- ============================================================
-- INTERNAL STATE
-- ============================================================

local animState   = {}  -- tower → animation-state record
local baseC0s     = {}  -- tower → stored Motor6D C0 values
local chargeGuis  = {}  -- tower → charge-display billboard data

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
	warn("[Vitalist] No Humanoid or AnimationController – can't animate")
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
			-- "idle"|"raising"|"raised"|"shoot_hold"|"lowering"|"reloading"|"walking"|"switching"
			gunState     = "idle",

			idleTrack       = nil,
			raiseTrack      = nil,
			gunIdleTrack    = nil,
			shootTrack      = nil,
			enhShootTrack   = nil,
			reloadTrack     = nil,
			lowerTrack      = nil,
			switchTrack     = nil,
			walkTrack       = nil,

			reloading       = false,
			bursting        = false,
			burstEndTime    = 0,   -- earliest tick() a new burst may begin
			lastShotTime    = -math.huge,
			readyToFireTime = 0,
		}
	end
	return animState[tower]
end

-- Returns the world position of the gun barrel, falling back to torso.
-- Handles both Attachment (.WorldPosition) and BasePart (.Position).
local function getBarrelPos(tower: Model): Vector3
	local barrel = tower:FindFirstChild("GunBarrel", true)
	if barrel then
		if barrel:IsA("Attachment") then
			return barrel.WorldPosition
		elseif barrel:IsA("BasePart") then
			return barrel.Position
		end
	end
	local torso = tower.PrimaryPart
	return torso and torso.Position or Vector3.zero
end

-- Returns every enemy in enemiesFolder whose centre lies within
-- pierceRadius studs of the ray (origin → direction).
-- Results are sorted nearest-first along the ray.
local function getEnemiesAlongRay(
	origin: Vector3,
	direction: Vector3,
	maxRange: number,
	pierceRadius: number,
	enemiesFolder: Folder
): {Model}
	local dir     = direction.Unit
	local results = {}

	for _, e in ipairs(enemiesFolder:GetChildren()) do
		if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
			local toEnemy = e.PrimaryPart.Position - origin
			local t       = toEnemy:Dot(dir)           -- signed distance along ray
			if t >= 0 and t <= maxRange then
				local closest = origin + dir * t
				local off     = (e.PrimaryPart.Position - closest).Magnitude
				if off <= pierceRadius then
					table.insert(results, { enemy = e, t = t })
				end
			end
		end
	end

	table.sort(results, function(a, b) return a.t < b.t end)

	local enemies = {}
	for _, r in ipairs(results) do
		table.insert(enemies, r.enemy)
	end
	return enemies
end

-- ============================================================
-- CHARGE DISPLAY
-- ============================================================

function Vitalist.CreateChargeDisplay(tower: Model)
	if chargeGuis[tower] then return end

	local head = tower:FindFirstChild("Head") or tower.PrimaryPart
	if not head then return end

	local billboard = Instance.new("BillboardGui")
	billboard.Name           = "ChargeDisplay"
	-- Slightly wider and taller than the HP bar (4.5 studs wide × 0.55 studs tall vs HP bar's 4 × 0.4)
	billboard.Size           = UDim2.new(4.5, 0, 0.55, 0)
	billboard.StudsOffset    = Vector3.new(0, 3.8, 0)
	billboard.AlwaysOnTop    = false
	billboard.ResetOnSpawn   = false
	billboard.LightInfluence = 0
	billboard.Parent         = head

	-- Outer black border (matches HP bar style)
	local outline = Instance.new("Frame")
	outline.Name             = "Outline"
	outline.Size             = UDim2.new(1, 0, 1, 0)
	outline.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	outline.BorderSizePixel  = 0
	outline.Parent           = billboard

	-- Dark background
	local bg = Instance.new("Frame")
	bg.Name             = "ChargeBg"
	bg.Size             = UDim2.new(1, -2, 1, -2)
	bg.Position         = UDim2.new(0, 1, 0, 1)
	bg.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
	bg.BorderSizePixel  = 0
	bg.Parent           = outline

	-- Fill bar
	local fill = Instance.new("Frame")
	fill.Name             = "ChargeFill"
	fill.Size             = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = ATK_COLOR
	fill.BorderSizePixel  = 0
	fill.Parent           = bg

	-- Charge text (matches HP bar text style)
	local label = Instance.new("TextLabel")
	label.Name                   = "ChargeText"
	label.Size                   = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text                   = "0 / 40"
	label.TextColor3             = Color3.fromRGB(255, 255, 255)
	label.TextScaled             = true
	label.Font                   = Enum.Font.SourceSans
	label.TextStrokeTransparency = 0.5
	label.Parent                 = bg

	chargeGuis[tower] = { billboard = billboard, fill = fill, label = label }
end

function Vitalist.UpdateChargeDisplay(tower: Model)
	local data = chargeGuis[tower]
	if not data then return end

	local charge   = tower:GetAttribute("Charge")   or 0
	local protocol = tower:GetAttribute("Protocol") or "ATK"
	local ratio    = math.clamp(charge / Vitalist.MAX_CHARGE, 0, 1)
	data.fill.Size = UDim2.new(ratio, 0, 1, 0)

	-- Yellow when ready for Nano Blast, otherwise ATK/SUPP colour
	if charge >= Vitalist.MAX_CHARGE then
		data.fill.BackgroundColor3 = Color3.fromRGB(220, 220, 60)
	else
		data.fill.BackgroundColor3 = (protocol == "SUPP") and SUPP_COLOR or ATK_COLOR
	end

	if data.label then
		data.label.Text = charge .. " / " .. Vitalist.MAX_CHARGE
	end
end

-- ============================================================
-- VFX – HITSCAN LASER BEAM
-- ============================================================

-- Fires an instant laser from fromPos to toPos.
-- color: ATK_COLOR (blue) or SUPP_COLOR (green)
-- isEnhanced: true for Nano Blast (thicker, longer-lived)
function Vitalist.SpawnHitscanBeam(fromPos: Vector3, toPos: Vector3, color: Color3, isEnhanced: boolean?)
	local anchorA = Instance.new("Part")
	anchorA.Name         = "VitalistBeamA"
	anchorA.Size         = Vector3.new(0.05, 0.05, 0.05)
	anchorA.Transparency = 1
	anchorA.Anchored     = true
	anchorA.CanCollide   = false
	anchorA.CastShadow   = false
	anchorA.Position     = fromPos
	anchorA.Parent       = Workspace

	local attA = Instance.new("Attachment")
	attA.Parent = anchorA

	local anchorB = Instance.new("Part")
	anchorB.Name         = "VitalistBeamB"
	anchorB.Size         = Vector3.new(0.05, 0.05, 0.05)
	anchorB.Transparency = 1
	anchorB.Anchored     = true
	anchorB.CanCollide   = false
	anchorB.CastShadow   = false
	anchorB.Position     = toPos
	anchorB.Parent       = Workspace

	local attB = Instance.new("Attachment")
	attB.Parent = anchorB

	local beam = Instance.new("Beam")
	beam.Attachment0    = attA
	beam.Attachment1    = attB
	beam.Width0         = isEnhanced and 10 or 0.12
	beam.Width1         = isEnhanced and 10 or 0.05
	beam.Segments       = 1
	beam.FaceCamera     = true
	beam.LightEmission  = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   color),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 255, 220)),
		ColorSequenceKeypoint.new(1,   color),
	})
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 0),
	})
	beam.Parent = anchorA

	local duration = isEnhanced and 0.45 or 0.12

	-- Fade out the beam by tweening Width0/Width1
	TweenService:Create(beam,
		TweenInfo.new(duration, Enum.EasingStyle.Quad),
		{ Width0 = 0, Width1 = 0 }
	):Play()

	-- Soft ambient glow (replaces jarring full-brightness flash)
	local light = Instance.new("PointLight")
	light.Brightness = isEnhanced and 1.5 or 0.6
	light.Color      = color
	light.Range      = isEnhanced and 14 or 7
	light.Parent     = anchorA
	TweenService:Create(light, TweenInfo.new(duration + 0.1), { Brightness = 0 }):Play()

	task.delay(duration + 0.15, function()
		if anchorA and anchorA.Parent then anchorA:Destroy() end
		if anchorB and anchorB.Parent then anchorB:Destroy() end
	end)
end

-- ============================================================
-- VFX – HIT / HEAL PARTICLES
-- ============================================================

function Vitalist.SpawnHitParticles(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name         = "VitalistHitAnchor"
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Position     = position
	anchor.Parent       = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	local burst = Instance.new("ParticleEmitter")
	burst.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.3, color),
		ColorSequenceKeypoint.new(1, color),
	})
	burst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.5),
		NumberSequenceKeypoint.new(0.4, 0.25),
		NumberSequenceKeypoint.new(1,   0),
	})
	burst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	burst.Lifetime      = NumberRange.new(0.12, 0.28)
	burst.Speed         = NumberRange.new(4, 14)
	burst.SpreadAngle   = Vector2.new(180, 180)
	burst.LightEmission = 0.6
	burst.Rate          = 0
	burst.Parent        = att
	burst:Emit(6)

	local scatter = Instance.new("ParticleEmitter")
	scatter.Color = ColorSequence.new(color)
	scatter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.28),
		NumberSequenceKeypoint.new(0.5, 0.14),
		NumberSequenceKeypoint.new(1,   0),
	})
	scatter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	scatter.Lifetime      = NumberRange.new(0.2, 0.45)
	scatter.Speed         = NumberRange.new(3, 9)
	scatter.SpreadAngle   = Vector2.new(180, 90)
	scatter.Acceleration  = Vector3.new(0, -12, 0)
	scatter.LightEmission = 0.4
	scatter.Rate          = 0
	scatter.Parent        = att
	scatter:Emit(10)

	task.delay(0.55, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- ============================================================
-- VFX – NANO BLAST ENHANCED IMPACT
-- ============================================================

function Vitalist.SpawnEnhancedHitVFX(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name         = "NanoBlastAnchor"
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Position     = position
	anchor.Parent       = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	-- Expanding shockwave ring
	local ring = Instance.new("Part")
	ring.Name         = "NanoRing"
	ring.Shape        = Enum.PartType.Cylinder
	ring.Size         = Vector3.new(0.1, 0.5, 0.5)
	ring.Color        = color
	ring.Material     = Enum.Material.Neon
	ring.Transparency = 0.15
	ring.Anchored     = true
	ring.CanCollide   = false
	ring.CastShadow   = false
	ring.CFrame       = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent       = Workspace
	TweenService:Create(ring,
		TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.05, 7, 7), Transparency = 1 }
	):Play()

	task.delay(0.9, function()
		if ring   and ring.Parent   then ring:Destroy()   end
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- ============================================================
-- VFX – MUZZLE FLASH
-- ============================================================

function Vitalist.SpawnMuzzleFlash(position: Vector3, color: Color3, isEnhanced: boolean?)
	-- Intentionally minimal; extend as needed.
end

-- ============================================================
-- TARGETING
-- ============================================================

--[[
	Returns the best target for this tower given its current protocol:

	ATK  → enemy with the highest WaypointIndex in range
	         (ties broken by closest distance).
	SUPP → nearest ally tower in range that is BELOW its MaxHP.
	         Towers at full health are skipped entirely.
]]
function Vitalist.FindTarget(
	tower: Model,
	enemiesFolder: Folder?,
	towersFolder: Folder?
): Model?
	local protocol = tower:GetAttribute("Protocol") or "ATK"
	local torso    = tower.PrimaryPart
	if not torso then return nil end
	local pos   = torso.Position
	local range = tower:GetAttribute("RNG") or 20

	if protocol == "ATK" then
		local bestEnemy  = nil
		local bestWP     = -math.huge
		local bestDist   = math.huge

		for _, e in ipairs(enemiesFolder and enemiesFolder:GetChildren() or {}) do
			if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
				local d = (e.PrimaryPart.Position - pos).Magnitude
				if d <= range then
					local wp = e:GetAttribute("WaypointIndex") or 0
					if wp > bestWP or (wp == bestWP and d < bestDist) then
						bestWP    = wp
						bestDist  = d
						bestEnemy = e
					end
				end
			end
		end
		return bestEnemy

	else -- SUPP
		local nearest  = nil
		local nearDist = math.huge

		for _, t in ipairs(towersFolder and towersFolder:GetChildren() or {}) do
			if t:IsA("Model") and t ~= tower and t.PrimaryPart then
				local hp    = t:GetAttribute("HP")    or 0
				local maxHP = t:GetAttribute("MaxHP") or 1
				-- Skip towers that are dead or already at full health
				if hp > 0 and hp < maxHP then
					local d = (t.PrimaryPart.Position - pos).Magnitude
					if d <= range and d < nearDist then
						nearDist = d
						nearest  = t
					end
				end
			end
		end
		return nearest
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

	st.gunState     = "raising"
	st.lastShotTime = tick()  -- prevent the lower-timer firing during raise

	safeStop(st.idleTrack,  0.12)
	safeStop(st.lowerTrack, 0.1)

	local animator = getOrCreateAnimator(tower)
	if not animator then
		st.gunState        = "shoot_hold"
		st.readyToFireTime = tick() + Vitalist.GUN_RAISE_DELAY
		return
	end

	safeDestroy(st.raiseTrack)
	local raiseTrack = loadAndPlay(animator, RAISE_ANIM_ID, false, Enum.AnimationPriority.Action, 0.12)
	if not raiseTrack then
		st.gunState        = "shoot_hold"
		st.readyToFireTime = tick() + Vitalist.GUN_RAISE_DELAY
		return
	end
	st.raiseTrack = raiseTrack

	task.spawn(function()
		if raiseTrack.IsPlaying then raiseTrack.Stopped:Wait() end

		if not tower or not tower.Parent then return end
		if st.gunState ~= "raising" then return end

		st.gunState        = "raised"
		st.readyToFireTime = tick() + Vitalist.GUN_RAISE_DELAY

		task.wait(Vitalist.GUN_RAISE_DELAY)

		if not tower or not tower.Parent then return end
		if st.gunState ~= "raised" then return end

		st.gunState     = "shoot_hold"
		st.lastShotTime = tick()

		local animator2 = getOrCreateAnimator(tower)
		if animator2 then
			safeDestroy(st.gunIdleTrack)
			st.gunIdleTrack = loadAndPlay(
				animator2, GUN_IDLE_ANIM_ID, true,
				Enum.AnimationPriority.Action, 0.1
			)
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
	local lowerTrack = loadAndPlay(animator, LOWER_ANIM_ID, false, Enum.AnimationPriority.Action, 0.12)
	if not lowerTrack then
		st.gunState = "idle"
		playIdle(tower, st)
		return
	end
	st.lowerTrack = lowerTrack

	task.spawn(function()
		if lowerTrack.IsPlaying then lowerTrack.Stopped:Wait() end
		if not tower or not tower.Parent then return end
		if st.gunState ~= "lowering" then return end
		st.gunState = "idle"
		playIdle(tower, st)
	end)
end

local function triggerReload(tower: Model, st)
	st.reloading    = true
	st.lastShotTime = tick()

	safeStop(st.gunIdleTrack,  0.1)
	safeStop(st.shootTrack,    0.1)
	safeStop(st.enhShootTrack, 0.1)

	local animator = getOrCreateAnimator(tower)
	if not animator then
		st.reloading = false
		return
	end

	safeDestroy(st.reloadTrack)
	local reloadTrack = loadAndPlay(
		animator, RELOAD_ANIM_ID, false,
		Enum.AnimationPriority.Action, 0.1
	)
	if not reloadTrack then
		st.reloading = false
		return
	end
	st.reloadTrack = reloadTrack

	task.spawn(function()
		if reloadTrack.IsPlaying then reloadTrack.Stopped:Wait() end
		if not tower or not tower.Parent then return end
		st.reloading    = false
		st.lastShotTime = tick()

		-- Resume gun-idle to hold raised pose
		local animator2 = getOrCreateAnimator(tower)
		if animator2 and st.gunState == "shoot_hold" then
			safeDestroy(st.gunIdleTrack)
			st.gunIdleTrack = loadAndPlay(
				animator2, GUN_IDLE_ANIM_ID, true,
				Enum.AnimationPriority.Action, 0.1
			)
		end
	end)
end

-- Play one cycle of the burst-shoot animation.
local function playShootOnce(tower: Model, st)
	local animator = getOrCreateAnimator(tower)
	if not animator then return end
	safeDestroy(st.shootTrack)
	local ok, track = pcall(function()
		local obj = Instance.new("Animation")
		obj.AnimationId = SHOOT_ANIM_ID
		local t = animator:LoadAnimation(obj)
		obj:Destroy()
		t.Looped   = false
		t.Priority = Enum.AnimationPriority.Action4
		t:Play(0.03)
		return t
	end)
	if ok and track then
		st.shootTrack = track
	end
end

-- ============================================================
-- MODEL CREATION
-- ============================================================

function Vitalist.CreateModel(position: Vector3, TowerStats: any): Model?
	local template = TowerStats.Templates["Vitalist"]
	if not template then return nil end

	local towerModels   = ServerStorage:FindFirstChild("TowerModels")
	local templateModel = towerModels and towerModels:FindFirstChild("Vitalist")
	if not templateModel then
		warn("[Vitalist] ServerStorage.TowerModels.Vitalist not found")
		return nil
	end

	local model = templateModel:Clone()
	model.Name  = "Vitalist"

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
	circle.Color        = Color3.fromRGB(50, 180, 80)
	circle.Transparency = 1
	circle.Material     = Enum.Material.SmoothPlastic
	circle.Parent       = model

	model:SetAttribute("ATK",         template.ATK)
	model:SetAttribute("AP",          template.AP)
	model:SetAttribute("ATK_SPD",     template.ATK_SPD)
	model:SetAttribute("RNG",         rangeStuds)
	model:SetAttribute("HP",          template.HP)
	model:SetAttribute("MaxHP",       template.HP)
	model:SetAttribute("MOVE_SPD",    template.MOVE_SPD)
	model:SetAttribute("DamageMulti", template.DamageMulti or 1.0)
	model:SetAttribute("AttackType",  template.AttackType  or "Hybrid")
	model:SetAttribute("State",       "Idle")
	model:SetAttribute("Owner",       "")
	model:SetAttribute("TowerType",   "Vitalist")
	model:SetAttribute("Charge",      0)
	model:SetAttribute("Protocol",    "ATK")  -- "ATK" or "SUPP"

	model:PivotTo(CFrame.new(position))

	-- Sit the model exactly on the ground by measuring the lowest non-decorative part
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

function Vitalist.StoreBaseC0s(model: Model)
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

function Vitalist.RestoreBaseC0s(model: Model)
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

function Vitalist.StartWalk(model: Model)
	local st = getAnimState(model)
	safeStop(st.idleTrack,    0.15)
	safeStop(st.raiseTrack,   0.1)
	safeStop(st.gunIdleTrack, 0.1)
	safeStop(st.shootTrack,   0.1)
	safeStop(st.lowerTrack,   0.15)
	safeStop(st.reloadTrack,  0.1)
	st.gunState = "walking"

	local animator = getOrCreateAnimator(model)
	if not animator then return end
	if not (st.walkTrack and st.walkTrack.IsPlaying) then
		safeDestroy(st.walkTrack)
		st.walkTrack = loadAndPlay(animator, WALK_ANIM_ID, true, Enum.AnimationPriority.Movement, 0.15)
	end
end

function Vitalist.StopWalk(model: Model)
	Vitalist.RestoreBaseC0s(model)
	local st = animState[model]
	if not st then return end
	safeStop(st.walkTrack, 0.15)
	st.walkTrack = nil
	st.gunState  = "idle"
	playIdle(model, st)
end

-- ============================================================
-- PROTOCOL SWITCH
-- ============================================================

-- Toggles the Protocol attribute (ATK↔SUPP) and plays the switch animation.
function Vitalist.TriggerProtocolSwitch(tower: Model)
	local currentProtocol = tower:GetAttribute("Protocol") or "ATK"
	local newProtocol     = (currentProtocol == "ATK") and "SUPP" or "ATK"
	tower:SetAttribute("Protocol", newProtocol)

	local st = getAnimState(tower)

	local animator = getOrCreateAnimator(tower)
	if not animator then return end

	safeDestroy(st.switchTrack)
	local switchTrack = loadAndPlay(
		animator, PROTOCOL_SWITCH_ANIM_ID, false,
		Enum.AnimationPriority.Action4, 0.1
	)
	st.switchTrack = switchTrack

	Vitalist.UpdateChargeDisplay(tower)
end

-- ============================================================
-- PUBLIC – ANIMATION INTERFACE
-- ============================================================

function Vitalist.InitTower(tower: Model)
	local st = getAnimState(tower)
	playIdle(tower, st)
	Vitalist.CreateChargeDisplay(tower)
	Vitalist.UpdateChargeDisplay(tower)
end

function Vitalist.IsReadyToFire(tower: Model): boolean
	local st = animState[tower]
	if not st then return false end
	if st.reloading then return false end
	if st.bursting  then return false end
	return st.gunState == "shoot_hold" and tick() >= st.readyToFireTime
end

function Vitalist.UpdateCombatState(tower: Model, hasTarget: boolean, target: Instance?)
	local st = getAnimState(tower)
	if not st then return end

	if st.reloading or st.bursting then return end

	-- Lower gun if no shot for GUN_LOWER_DELAY seconds.
	-- st.lastShotTime is updated per-bullet during bursts so this won't
	-- fire mid-burst even at slow BURST_SHOT_INTERVAL values.
	if (st.gunState == "shoot_hold" or st.gunState == "raised") and
		(tick() - st.lastShotTime) >= Vitalist.GUN_LOWER_DELAY
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

--[[
	target        : primary target (enemy Model in ATK, ally tower Model in SUPP).
	enemiesFolder : used for Nano Blast pierce scan and retargeting.
	towersFolder  : used for SUPP retargeting.
]]
function Vitalist.DoAttack(
	tower: Model,
	target: Model,
	enemiesFolder: Folder?,
	towersFolder: Folder?
): boolean
	local st = getAnimState(tower)
	if st.reloading or st.bursting then return false end
	if tick() < st.burstEndTime then return false end  -- enforce inter-burst gap

	local atk      = tower:GetAttribute("ATK")        or 12
	local ap       = tower:GetAttribute("AP")          or 18
	local multi    = tower:GetAttribute("DamageMulti") or 1.0
	local charge   = tower:GetAttribute("Charge")      or 0
	local protocol = tower:GetAttribute("Protocol")    or "ATK"

	local isEnhanced = (charge >= Vitalist.MAX_CHARGE)
	local beamColor  = (protocol == "SUPP") and SUPP_COLOR or ATK_COLOR

	-- Face the primary target
	local torso = tower.PrimaryPart
	if torso and target.PrimaryPart then
		local flatDir = Vector3.new(
			target.PrimaryPart.Position.X - torso.Position.X,
			0,
			target.PrimaryPart.Position.Z - torso.Position.Z
		)
		if flatDir.Magnitude > 0.1 then
			torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
		end
	end

	-- ── ENHANCED: Nano Blast ──────────────────────────────────────────────
	if isEnhanced then
		tower:SetAttribute("Charge", 0)
		Vitalist.UpdateChargeDisplay(tower)

		-- Resolve the primary blast target (SUPP: lowest-HP-ratio ally; ATK: first enemy)
		local blastTarget = target
		local blastRange  = tower:GetAttribute("RNG") * 2 or 40

		if protocol == "SUPP" and towersFolder then
			local pos          = torso and torso.Position or Vector3.zero
			local bestHPRatio  = math.huge
			local bestTower    = nil
			for _, t in ipairs(towersFolder:GetChildren()) do
				if t:IsA("Model") and t ~= tower and t.PrimaryPart then
					local hp    = t:GetAttribute("HP")    or 0
					local maxHP = t:GetAttribute("MaxHP") or 1
					local d     = (t.PrimaryPart.Position - pos).Magnitude
					-- Only consider towers that are actually below max HP
					if d <= blastRange and hp > 0 and hp < maxHP then
						local ratio = hp / maxHP
						if ratio < bestHPRatio then
							bestHPRatio = ratio
							bestTower   = t
						end
					end
				end
			end
			if bestTower then blastTarget = bestTower end

		elseif protocol == "ATK" and enemiesFolder then
			-- "First" targeting: highest WaypointIndex in range
			local pos    = torso and torso.Position or Vector3.zero
			local bestWP   = -math.huge
			local bestDist = math.huge
			local bestEnemy = nil
			for _, e in ipairs(enemiesFolder:GetChildren()) do
				if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
					local d = (e.PrimaryPart.Position - pos).Magnitude
					if d <= blastRange then
						local wp = e:GetAttribute("WaypointIndex") or 0
						if wp > bestWP or (wp == bestWP and d < bestDist) then
							bestWP    = wp
							bestDist  = d
							bestEnemy = e
						end
					end
				end
			end
			if bestEnemy then blastTarget = bestEnemy end
		end

		if not blastTarget or not blastTarget.Parent or not blastTarget.PrimaryPart then
			return false
		end

		local blastDmg = ap * multi * 2

		-- Play the enhanced-shoot animation; fire everything AFTER it ends.
		local animator = getOrCreateAnimator(tower)
		safeStop(st.gunIdleTrack, 0.1)
		safeDestroy(st.enhShootTrack)

		local enhTrack = animator and loadAndPlay(
			animator, ENHANCED_SHOOT_ANIM_ID, false,
			Enum.AnimationPriority.Action4, 0.05
		) or nil
		st.enhShootTrack = enhTrack

		task.spawn(function()
			-- Wait for animation to complete before firing VFX + damage
			--if enhTrack then
				--if enhTrack.IsPlaying then enhTrack.Stopped:Wait() end

			--end

			if not tower or not tower.Parent then return end

			local fromPos = getBarrelPos(tower)

			if protocol == "ATK" and enemiesFolder then
				-- ── Pierce: find all enemies along the beam ──────────────────
				local aimDir  = (blastTarget.PrimaryPart.Position - fromPos)
				local pierced = getEnemiesAlongRay(fromPos, aimDir, blastRange, Vitalist.NANO_PIERCE_RADIUS, enemiesFolder)

				-- Beam endpoint: extend to range in the aim direction
				local beamEnd = fromPos + aimDir.Unit * blastRange

				Vitalist.SpawnMuzzleFlash(fromPos, beamColor, true)
				Vitalist.SpawnHitscanBeam(fromPos, beamEnd, beamColor, true)

				for _, e in ipairs(pierced) do
					if e and e.Parent and e.PrimaryPart then
						local impactPos = e.PrimaryPart.Position
						local hp        = e:GetAttribute("HP") or 0
						local newHP     = hp - blastDmg
						e:SetAttribute("HP", newHP)
						Vitalist.SpawnEnhancedHitVFX(impactPos, beamColor)
						if newHP <= 0 and e.Parent then
							e:Destroy()
						end
					end
				end

			else
				-- ── SUPP single-target heal ───────────────────────────────────
				if blastTarget.Parent and blastTarget.PrimaryPart then
					local impactPos = blastTarget.PrimaryPart.Position
					local hp        = blastTarget:GetAttribute("HP")    or 0
					local maxHP     = blastTarget:GetAttribute("MaxHP") or 1
					blastTarget:SetAttribute("HP", math.min(hp + blastDmg, maxHP))
					Vitalist.SpawnMuzzleFlash(fromPos, beamColor, true)
					Vitalist.SpawnHitscanBeam(fromPos, impactPos, beamColor, true)
					Vitalist.SpawnEnhancedHitVFX(impactPos, beamColor)
				end
			end

			if tower and tower.Parent then
				triggerReload(tower, st)
			end
		end)

		st.lastShotTime = tick()
		return true
	end

	-- ── NORMAL BURST: 8 hitscan shots ────────────────────────────────────
	st.bursting = true

	task.spawn(function()
		local ok, err = pcall(function()
			local bulletDmg = (atk * multi) * 0.125

			for i = 1, Vitalist.BULLETS_PER_BURST do
				if not tower or not tower.Parent then break end
				if not target or not target.Parent then break end

				-- Refresh lastShotTime immediately so the gun-lower timer
				-- cannot fire mid-burst regardless of BURST_SHOT_INTERVAL value.
				st.lastShotTime = tick()

				local targetPart = target.PrimaryPart
				if not targetPart then break end
				local impactPos = targetPart.Position

				-- Apply effect
				if protocol == "SUPP" then
					local hp    = target:GetAttribute("HP")    or 0
					local maxHP = target:GetAttribute("MaxHP") or 1
					-- Skip healing towers that are already at full health
					if hp < maxHP then
						target:SetAttribute("HP", math.min(hp + bulletDmg, maxHP))
					end
				else
					local hp    = target:GetAttribute("HP") or 0
					local newHP = hp - bulletDmg
					target:SetAttribute("HP", newHP)
					if newHP <= 0 and target.Parent then
						target:Destroy()
						target = nil
					end
				end

				-- VFX – always fire from the gun barrel
				local fromPos = getBarrelPos(tower)
				Vitalist.SpawnMuzzleFlash(fromPos, beamColor, false)
				Vitalist.SpawnHitscanBeam(fromPos, impactPos, beamColor, false)
				if target then
					Vitalist.SpawnHitParticles(impactPos, beamColor)
				end

				-- Shoot animation (one cycle per bullet)
				playShootOnce(tower, st)

				-- Increment charge
				local newCharge = math.min((tower:GetAttribute("Charge") or 0) + 1, Vitalist.MAX_CHARGE)
				tower:SetAttribute("Charge", newCharge)
				Vitalist.UpdateChargeDisplay(tower)

				-- Update lastShotTime each bullet so the gun-lower timer
				-- cannot trigger mid-burst even at slow BURST_SHOT_INTERVAL values.
				st.lastShotTime = tick()

				if i < Vitalist.BULLETS_PER_BURST then
					task.wait(Vitalist.BURST_SHOT_INTERVAL)
				end
			end
		end)

		if not ok then
			warn("[Vitalist] Burst loop error:", err)
		end

		-- Enforce a rest gap equal to the full burst duration before the next burst.
		-- This prevents the external attack loop from immediately re-triggering when
		-- BURST_SHOT_INTERVAL is set higher than the default 0.065 s.
		local burstDuration = Vitalist.BULLETS_PER_BURST * Vitalist.BURST_SHOT_INTERVAL
		st.burstEndTime = tick() + burstDuration
		st.bursting     = false
		st.lastShotTime = tick()
	end)

	return true
end

-- ============================================================
-- CLEANUP
-- ============================================================

function Vitalist.CleanupTower(tower: Model)
	local st = animState[tower]
	if st then
		safeDestroy(st.walkTrack)
		safeDestroy(st.idleTrack)
		safeDestroy(st.raiseTrack)
		safeDestroy(st.gunIdleTrack)
		safeDestroy(st.shootTrack)
		safeDestroy(st.enhShootTrack)
		safeDestroy(st.reloadTrack)
		safeDestroy(st.lowerTrack)
		safeDestroy(st.switchTrack)
		animState[tower] = nil
	end

	baseC0s[tower] = nil

	local cd = chargeGuis[tower]
	if cd then
		pcall(function() cd.billboard:Destroy() end)
		chargeGuis[tower] = nil
	end
end

return Vitalist
