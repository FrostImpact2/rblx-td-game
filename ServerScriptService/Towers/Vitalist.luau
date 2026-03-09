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
	      ATK mode  : blue laser to the targeted enemy,   2× AP damage.
	      SUPP mode : green laser to the nearest ally tower, 2× AP healing.
	      Resets Charge to 0; triggers a reload animation.

	  - Move Skill – Combat Protocol:
	      On Move, if the destination is ≤ 8 studs from the tower,
	      the tower switches between ATK and SUPP protocols.

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
Vitalist.BURST_SHOT_INTERVAL    = 0.065  -- seconds between individual burst shots

-- ====== ANIMATION IDs ======
local IDLE_ANIM_ID            = "rbxassetid://98169705964556"
local RAISE_ANIM_ID           = "rbxassetid://101238020869924"
local GUN_IDLE_ANIM_ID        = "rbxassetid://93669945158951"
local SHOOT_ANIM_ID           = "rbxassetid://113123940530235"
local ENHANCED_SHOOT_ANIM_ID  = "rbxassetid://119922322699649"
local RELOAD_ANIM_ID          = "rbxassetid://87714279300663"
local LOWER_ANIM_ID           = "rbxassetid://134321960932781"
local PROTOCOL_SWITCH_ANIM_ID = "rbxassetid://112311342264233"

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

			reloading       = false,
			bursting        = false,
			lastShotTime    = -math.huge,
			readyToFireTime = 0,
		}
	end
	return animState[tower]
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
	billboard.Size           = UDim2.new(0, 80, 0, 22)
	billboard.StudsOffset    = Vector3.new(0, 3.8, 0)
	billboard.AlwaysOnTop    = false
	billboard.ResetOnSpawn   = false
	billboard.LightInfluence = 0
	billboard.Parent         = head

	-- Background bar
	local bg = Instance.new("Frame")
	bg.Name                   = "BG"
	bg.Size                   = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3       = Color3.fromRGB(30, 30, 35)
	bg.BackgroundTransparency = 0
	bg.BorderSizePixel        = 0
	bg.Parent                 = billboard
	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 3)
	bgCorner.Parent = bg

	-- Fill bar
	local fill = Instance.new("Frame")
	fill.Name             = "Fill"
	fill.Size             = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = ATK_COLOR
	fill.BorderSizePixel  = 0
	fill.Parent           = bg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = fill

	-- Charge text
	local label = Instance.new("TextLabel")
	label.Name                   = "ChargeLabel"
	label.Size                   = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text                   = "0 / 40"
	label.TextColor3             = Color3.fromRGB(220, 220, 220)
	label.Font                   = Enum.Font.GothamBold
	label.TextSize               = 10
	label.TextXAlignment         = Enum.TextXAlignment.Center
	label.Parent                 = bg

	chargeGuis[tower] = { billboard = billboard, fill = fill, label = label }
end

function Vitalist.UpdateChargeDisplay(tower: Model)
	local data = chargeGuis[tower]
	if not data then return end

	local charge   = tower:GetAttribute("Charge")   or 0
	local protocol = tower:GetAttribute("Protocol") or "ATK"
	local ratio    = math.clamp(charge / Vitalist.MAX_CHARGE, 0, 1)
	data.fill.BackgroundColor3 = (protocol == "SUPP") and SUPP_COLOR or ATK_COLOR

	if data.label then
		data.label.Text = charge .. " / " .. Vitalist.MAX_CHARGE
	end

	-- Glow effect when ready for Nano Blast
	if charge >= Vitalist.MAX_CHARGE then
		data.fill.BackgroundColor3 = Color3.fromRGB(220, 220, 60)
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
	beam.Width0         = isEnhanced and 0.55 or 0.12
	beam.Width1         = isEnhanced and 0.45 or 0.05
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

	-- Fade out the beam
	TweenService:Create(beam,
		TweenInfo.new(duration, Enum.EasingStyle.Quad),
		{ Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		}) }
	):Play()

	-- Point light pop at the origin
	local light = Instance.new("PointLight")
	light.Brightness = isEnhanced and 9 or 3
	light.Color      = color
	light.Range      = isEnhanced and 22 or 10
	light.Parent     = anchorA
	TweenService:Create(light, TweenInfo.new(duration), { Brightness = 0 }):Play()

	task.delay(duration + 0.15, function()
		if anchorA and anchorA.Parent then anchorA:Destroy() end
		if anchorB and anchorB.Parent then anchorB:Destroy() end
	end)
end

-- ============================================================
-- VFX – HIT / HEAL PARTICLES
-- ============================================================

-- Called with green color for healing, blue color for damage.
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

	-- Centre flash
	local bigFlash = Instance.new("ParticleEmitter")
	bigFlash.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(230, 255, 230)),
		ColorSequenceKeypoint.new(1, color),
	})
	bigFlash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   2.0),
		NumberSequenceKeypoint.new(0.3, 0.9),
		NumberSequenceKeypoint.new(1,   0),
	})
	bigFlash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	bigFlash.LightEmission = 0.8
	bigFlash.Lifetime      = NumberRange.new(0.1, 0.22)
	bigFlash.Speed         = NumberRange.new(4, 18)
	bigFlash.SpreadAngle   = Vector2.new(180, 180)
	bigFlash.Rate          = 0
	bigFlash.Parent        = att
	bigFlash:Emit(12)

	-- Sparks
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(220, 255, 220)),
		ColorSequenceKeypoint.new(0.5, color),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(30, 80, 30)),
	})
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.18),
		NumberSequenceKeypoint.new(0.6, 0.08),
		NumberSequenceKeypoint.new(1,   0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0),
		NumberSequenceKeypoint.new(0.7, 0.1),
		NumberSequenceKeypoint.new(1,   1),
	})
	sparks.LightEmission = 0.7
	sparks.Lifetime      = NumberRange.new(0.35, 0.7)
	sparks.Speed         = NumberRange.new(10, 26)
	sparks.SpreadAngle   = Vector2.new(180, 180)
	sparks.Acceleration  = Vector3.new(0, -26, 0)
	sparks.Rate          = 0
	sparks.Parent        = att
	sparks:Emit(24)

	-- Bright point-light
	local light = Instance.new("PointLight")
	light.Brightness = 14
	light.Color      = color
	light.Range      = 24
	light.Parent     = anchor
	TweenService:Create(light, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { Brightness = 0 }):Play()

	task.delay(0.9, function()
		if ring   and ring.Parent   then ring:Destroy()   end
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- ============================================================
-- VFX – MUZZLE FLASH
-- ============================================================

function Vitalist.SpawnMuzzleFlash(position: Vector3, color: Color3, isEnhanced: boolean?)
	local anchor = Instance.new("Part")
	anchor.Name         = "VitalistMuzzle"
	anchor.Size         = Vector3.new(0.05, 0.05, 0.05)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CastShadow   = false
	anchor.Position     = position
	anchor.Parent       = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	local flash = Instance.new("ParticleEmitter")
	flash.Color = ColorSequence.new(isEnhanced
		and Color3.fromRGB(200, 255, 200)
		or  color
	)
	flash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   isEnhanced and 0.5 or 0.22),
		NumberSequenceKeypoint.new(0.4, isEnhanced and 0.25 or 0.11),
		NumberSequenceKeypoint.new(1,   0),
	})
	flash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	flash.Lifetime      = NumberRange.new(0.03, 0.09)
	flash.Speed         = NumberRange.new(2, isEnhanced and 14 or 8)
	flash.SpreadAngle   = Vector2.new(50, 50)
	flash.LightEmission = 0.9
	flash.Rate          = 0
	flash.Parent        = att
	flash:Emit(isEnhanced and 10 or 5)

	local light = Instance.new("PointLight")
	light.Brightness = isEnhanced and 9 or 4
	light.Color      = color
	light.Range      = isEnhanced and 16 or 9
	light.Parent     = anchor
	TweenService:Create(light, TweenInfo.new(0.1), { Brightness = 0 }):Play()

	task.delay(0.3, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
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
	safeStop(st.idleTrack,    0.12)
	safeStop(st.lowerTrack,   0.1)

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
		raiseTrack.Stopped:Wait()

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
		lowerTrack.Stopped:Wait()
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
		reloadTrack.Stopped:Wait()
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
	circle.CFrame = CFrame.new(position.X, position.Y - 2.5, position.Z)
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
end

function Vitalist.StopWalk(model: Model)
	Vitalist.RestoreBaseC0s(model)
	local st = animState[model]
	if st then
		st.gunState = "idle"
	end
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

	-- Play protocol-switch animation on top of current state
	local animator = getOrCreateAnimator(tower)
	if not animator then return end

	safeDestroy(st.switchTrack)
	local switchTrack = loadAndPlay(
		animator, PROTOCOL_SWITCH_ANIM_ID, false,
		Enum.AnimationPriority.Action4, 0.1
	)
	st.switchTrack = switchTrack

	-- Update charge display colour
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

	-- Lower gun if no shot for GUN_LOWER_DELAY seconds
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

-- target is an enemy Model (ATK mode) or an ally tower Model (SUPP mode).
-- enemiesFolder and towersFolder are passed for enhanced-mode retargeting.
function Vitalist.DoAttack(
	tower: Model,
	target: Model,
	enemiesFolder: Folder?,
	towersFolder: Folder?
): boolean
	local st = getAnimState(tower)
	if st.reloading or st.bursting then return false end

	local atk      = tower:GetAttribute("ATK")        or 12
	local ap       = tower:GetAttribute("AP")          or 18
	local multi    = tower:GetAttribute("DamageMulti") or 1.0
	local charge   = tower:GetAttribute("Charge")      or 0
	local protocol = tower:GetAttribute("Protocol")    or "ATK"

	local isEnhanced = (charge >= Vitalist.MAX_CHARGE)
	local beamColor  = (protocol == "SUPP") and SUPP_COLOR or ATK_COLOR

	-- Face the target
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

		-- For Nano Blast, retarget based on protocol
		local blastTarget = target
		if protocol == "SUPP" and towersFolder then
			-- Nearest ally tower in range (lowest HP ratio)
			local pos   = torso and torso.Position or Vector3.zero
			local range = tower:GetAttribute("RNG") or 20
			local bestHPRatio = math.huge
			local bestTower   = nil
			for _, t in ipairs(towersFolder:GetChildren()) do
				if t:IsA("Model") and t ~= tower and t.PrimaryPart then
					local hp    = t:GetAttribute("HP") or 0
					local maxHP = t:GetAttribute("MaxHP") or 1
					local d     = (t.PrimaryPart.Position - pos).Magnitude
					if d <= range and hp > 0 and hp / maxHP < bestHPRatio then
						bestHPRatio = hp / maxHP
						bestTower   = t
					end
				end
			end
			if bestTower then blastTarget = bestTower end
		elseif protocol == "ATK" and enemiesFolder then
			-- Nearest enemy in range
			local pos   = torso and torso.Position or Vector3.zero
			local range = tower:GetAttribute("RNG") or 20
			local nearest, nearDist = nil, math.huge
			for _, e in ipairs(enemiesFolder:GetChildren()) do
				if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
					local d = (e.PrimaryPart.Position - pos).Magnitude
					if d <= range and d < nearDist then nearDist = d; nearest = e end
				end
			end
			if nearest then blastTarget = nearest end
		end

		if not blastTarget or not blastTarget.Parent or not blastTarget.PrimaryPart then
			return false
		end

		local impactPos = blastTarget.PrimaryPart.Position
		local blastDmg  = ap * multi * 2

		-- Apply effect
		if protocol == "SUPP" then
			local hp    = blastTarget:GetAttribute("HP")    or 0
			local maxHP = blastTarget:GetAttribute("MaxHP") or 1
			blastTarget:SetAttribute("HP", math.min(hp + blastDmg, maxHP))
		else
			local hp    = blastTarget:GetAttribute("HP") or 0
			local newHP = hp - blastDmg
			blastTarget:SetAttribute("HP", newHP)
			if newHP <= 0 and blastTarget.Parent then
				blastTarget:Destroy()
			end
		end

		-- VFX
		Vitalist.SpawnEnhancedHitVFX(impactPos, beamColor)
		if torso then
			local barrel  = tower:FindFirstChild("GunBarrel", true)
			local fromPos = barrel and barrel.WorldPosition or torso.Position
			Vitalist.SpawnMuzzleFlash(fromPos, beamColor, true)
			Vitalist.SpawnHitscanBeam(fromPos, impactPos, beamColor, true)
		end

		-- Enhanced shoot animation → reload
		local animator = getOrCreateAnimator(tower)
		if animator then
			safeStop(st.gunIdleTrack, 0.1)
			safeDestroy(st.enhShootTrack)
			local enhTrack = loadAndPlay(
				animator, ENHANCED_SHOOT_ANIM_ID, false,
				Enum.AnimationPriority.Action4, 0.05
			)
			st.enhShootTrack = enhTrack

			task.spawn(function()
				if enhTrack then
					if enhTrack.IsPlaying then enhTrack.Stopped:Wait() end
				else
					task.wait(0.3)
				end
				if tower and tower.Parent then
					triggerReload(tower, st)
				end
			end)
		else
			triggerReload(tower, st)
		end

		st.lastShotTime = tick()
		Vitalist.UpdateChargeDisplay(tower)
		return true
	end

	-- ── NORMAL BURST: 8 hitscan shots ────────────────────────────────────
	st.bursting = true

	task.spawn(function()
		local bulletDmg = (atk * multi) * 0.125

		for i = 1, Vitalist.BULLETS_PER_BURST do
			if not tower or not tower.Parent then break end
			if not target or not target.Parent then break end

			-- Determine current target position (enemies move)
			local targetPart = target.PrimaryPart
			if not targetPart then break end
			local impactPos = targetPart.Position

			-- Apply effect
			if protocol == "SUPP" then
				local hp    = target:GetAttribute("HP")    or 0
				local maxHP = target:GetAttribute("MaxHP") or 1
				target:SetAttribute("HP", math.min(hp + bulletDmg, maxHP))
			else
				local hp    = target:GetAttribute("HP") or 0
				local newHP = hp - bulletDmg
				target:SetAttribute("HP", newHP)
				if newHP <= 0 and target.Parent then
					target:Destroy()
					target = nil
				end
			end

			-- VFX
			if torso then
				local barrel  = tower:FindFirstChild("GunBarrel", true)
				local fromPos = barrel and barrel.WorldPosition or torso.Position
				Vitalist.SpawnMuzzleFlash(fromPos, beamColor, false)
				Vitalist.SpawnHitscanBeam(fromPos, impactPos, beamColor, false)
			end
			if target then
				Vitalist.SpawnHitParticles(impactPos, beamColor)
			end

			-- Shoot animation (one cycle per bullet)
			playShootOnce(tower, st)

			-- Increment charge
			local newCharge = math.min((tower:GetAttribute("Charge") or 0) + 1, Vitalist.MAX_CHARGE)
			tower:SetAttribute("Charge", newCharge)
			Vitalist.UpdateChargeDisplay(tower)

			if i < Vitalist.BULLETS_PER_BURST then
				task.wait(Vitalist.BURST_SHOT_INTERVAL)
			end
		end

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
