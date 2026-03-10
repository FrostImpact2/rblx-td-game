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
	  shoot_hold  →  (Headhunter fires, full anim plays)  →  reloading  →  shoot_hold
	  Any state  →  walking  (on player-initiated move)
	  walking  →  idle  (on arrival)

	Animations
	  Idle      : 130403916615858  (looped)
	  Walk      : 73323871613223   (looped)
	  Gun Raise : 75900515991486   (one-shot, Action priority)
	  Aim Idle  : 112216226009616  (looped, Action priority – holds raised pose)
	  Shoot     : 108396781520756  (one-shot, Action priority – recoil burst)
	  Gun Lower : 107226036750887  (one-shot, Action priority)
	  Reload    : 134398343804499  (one-shot, Action priority)

	Bullet display (IMAGE-BASED)
	  Requires: ReplicatedStorage > DeadeyeAssets > BulletIcons
	  Contains three Decal objects:
	    • BulletActive  – gold/brass bullet image
	    • BulletGlow    – glowing bullet image (3rd slot)
	    • BulletSpent   – dark grey spent casing image
	  Falls back to coloured ImageLabels if folder is missing.

	Bullet icons float above the tower's head.
	  Slot 1 & 2 show BulletActive → BulletSpent when fired.
	  Slot 3 shows BulletGlow    → BulletSpent when fired.
	  After Headhunter fires: full recoil animation plays first,
	  then all three go grey and the reload animation runs.
]]

local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")
local ServerStorage     = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
Deadeye.HEADHUNTER_AIM_TIME    = 0.65   -- ← seconds Headhunter holds the laser before firing

-- ====== ANIMATION IDs ======
local IDLE_ANIM_ID     = "rbxassetid://130403916615858"
local WALK_ANIM_ID     = "rbxassetid://73323871613223"
local RAISE_ANIM_ID    = "rbxassetid://75900515991486"
local AIM_IDLE_ANIM_ID = "rbxassetid://112216226009616"
local SHOOT_ANIM_ID    = "rbxassetid://108396781520756"
local LOWER_ANIM_ID    = "rbxassetid://107226036750887"
local RELOAD_ANIM_ID   = "rbxassetid://134398343804499"

-- ====== FALLBACK BULLET COLOURS (used if image folder is absent) ======
local FB_ACTIVE_COLOR = Color3.fromRGB(220, 175, 50)
local FB_GLOW_COLOR   = Color3.fromRGB(255, 210, 0)
local FB_SPENT_COLOR  = Color3.fromRGB(75,  75,  75)

-- ============================================================
-- INTERNAL STATE
-- ============================================================

local animState  = {}   -- tower → animation-state record
local baseC0s    = {}   -- tower → stored Motor6D C0 values
local walkTracks = {}   -- tower → active walk AnimationTrack
local bulletGuis = {}   -- tower → { billboard, labels[], usingImages }

local headhunterAimStart = {}  -- tower → tick() when lock-on began
local aimBeams           = {}  -- tower → aim-laser data

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
			-- "idle"|"raising"|"raised"|"shoot_hold"|"lowering"|"walking"
			gunState     = "idle",

			idleTrack    = nil,
			raiseTrack   = nil,
			aimIdleTrack = nil,
			shootTrack   = nil,
			lowerTrack   = nil,
			reloadTrack  = nil,

			reloading       = false,
			lastShotTime    = -math.huge,
			readyToFireTime = 0,
		}
	end
	return animState[tower]
end

-- ============================================================
-- BULLET IMAGE LOADER
-- ============================================================


local function getBulletImages(): { active: string, glow: string, spent: string }?
	-- Always re-check; don't permanently cache failures
	local assets = ReplicatedStorage:FindFirstChild("DeadeyeAssets")
	local icons  = assets and assets:FindFirstChild("BulletIcons")
	if not icons then
		warn("[Deadeye] ReplicatedStorage.DeadeyeAssets.BulletIcons not found")
		return nil
	end

	local dActive = icons:FindFirstChild("BulletActive")
	local dGlow   = icons:FindFirstChild("BulletGlow")
	local dUsed   = icons:FindFirstChild("BulletUsed")

	if not dActive or not dGlow or not dUsed then
		warn("[Deadeye] Missing Decal(s) in BulletIcons – found:",
			dActive and "BulletActive" or "MISSING BulletActive",
			dGlow   and "BulletGlow"   or "MISSING BulletGlow",
			dUsed   and "BulletUsed"   or "MISSING BulletUsed"
		)
		return nil
	end

	local tActive = dActive.Texture
	local tGlow   = dGlow.Texture
	local tUsed   = dUsed.Texture

	if tActive == "" or tGlow == "" or tUsed == "" then
		warn("[Deadeye] One or more BulletIcons Decals has an empty Texture –",
			"BulletActive:", tActive,
			"BulletGlow:", tGlow,
			"BulletUsed:", tUsed
		)
		return nil
	end

	return { active = tActive, glow = tGlow, spent = tUsed }
end

-- ============================================================
-- BULLET DISPLAY
-- ============================================================

function Deadeye.CreateBulletDisplay(tower: Model)
	if bulletGuis[tower] then return end

	local head = tower:FindFirstChild("Head") or tower.PrimaryPart
	if not head then return end

	local billboard = Instance.new("BillboardGui")
	billboard.Name           = "BulletDisplay"
	-- Use stud-based size so bullets scale with world, not screen pixels
	billboard.StudsOffset    = Vector3.new(0, 3.8, 0)
	billboard.Size           = UDim2.new(2, 0, 0.65, 0)
	billboard.AlwaysOnTop    = false
	billboard.ResetOnSpawn   = false
	billboard.LightInfluence = 0
	billboard.Parent         = head

	local container = Instance.new("Frame")
	container.Size                   = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent                 = billboard

	local layout = Instance.new("UIListLayout")
	layout.FillDirection       = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment   = Enum.VerticalAlignment.Center
	layout.Padding             = UDim.new(0.06, 0)
	layout.Parent              = container

	local imgs        = getBulletImages()
	local usingImages = imgs ~= nil

	local labels = {}
	for i = 1, 3 do
		if usingImages then
			-- ── Image-based bullet (scale-relative sizing) ──
			local img = Instance.new("ImageLabel")
			img.Name                    = "Bullet" .. i
			img.Size                    = UDim2.new(0.28, 0, 1, 0)
			img.BackgroundTransparency  = 1
			img.ScaleType               = Enum.ScaleType.Fit
			img.Image                   = (i == 3) and imgs.glow or imgs.active
			img.Parent                  = container
			labels[i]                   = img
		else
			-- ── Fallback: coloured shape (scale-relative sizing) ──
			local wrapper = Instance.new("Frame")
			wrapper.Name                    = "Bullet" .. i
			wrapper.Size                    = UDim2.new(0.24, 0, 0.85, 0)
			wrapper.BackgroundTransparency  = 1
			wrapper.Parent                  = container

			local body = Instance.new("Frame")
			body.Name             = "Body"
			body.Size             = UDim2.new(1, 0, 0.70, 0)
			body.Position         = UDim2.new(0, 0, 0.30, 0)
			body.BorderSizePixel  = 0
			body.BackgroundColor3 = (i == 3) and FB_GLOW_COLOR or FB_ACTIVE_COLOR
			local bc = Instance.new("UICorner")
			bc.CornerRadius = UDim.new(0.18, 0)
			bc.Parent = body
			body.Parent = wrapper

			local tip = Instance.new("Frame")
			tip.Name             = "Tip"
			tip.Size             = UDim2.new(0.7, 0, 0.38, 0)
			tip.Position         = UDim2.new(0.15, 0, 0, 0)
			tip.BorderSizePixel  = 0
			tip.BackgroundColor3 = (i == 3) and FB_GLOW_COLOR or FB_ACTIVE_COLOR
			local tc = Instance.new("UICorner")
			tc.CornerRadius = UDim.new(0.5, 0)
			tc.Parent = tip
			tip.Parent = wrapper

			labels[i] = wrapper
		end
	end

	bulletGuis[tower] = { billboard = billboard, labels = labels, usingImages = usingImages }
end

-- Refresh bullet state.
--   count     : current BasicAttackCount (0, 1, or 2)
--   reloading : true while the reload animation is playing
function Deadeye.UpdateBulletDisplay(tower: Model, count: number, reloading: boolean)
	local data = bulletGuis[tower]
	if not data then return end

	local imgs = data.usingImages and getBulletImages()

	for i, elem in ipairs(data.labels) do
		local spent = reloading or (i <= count)

		if data.usingImages and imgs then
			-- ImageLabel path
			(elem :: ImageLabel).Image = spent and imgs.spent
				or ((i == 3) and imgs.glow or imgs.active)
		else
			-- Fallback coloured-shape path
			local body = elem:FindFirstChild("Body")
			local tip  = elem:FindFirstChild("Tip")
			if not body or not tip then continue end
			local col = spent and FB_SPENT_COLOR
				or ((i == 3) and FB_GLOW_COLOR or FB_ACTIVE_COLOR)
			body.BackgroundColor3 = col
			tip.BackgroundColor3  = col
		end
	end
end


-- ============================================================
-- VFX – NORMAL BULLET WITH TRAIL
-- ============================================================

function Deadeye.SpawnBullet(fromPos: Vector3, toPos: Vector3, isEnhanced: boolean?)
	local dir  = toPos - fromPos
	local dist = dir.Magnitude
	if dist < 0.1 then return end
	dir = dir.Unit

	-- Enhanced bullet is larger and brighter
	local bulletSize = isEnhanced
		and Vector3.new(0.14, 0.14, 0.75)
		or  Vector3.new(0.1,  0.1,  0.55)

	local bullet = Instance.new("Part")
	bullet.Name       = "DeadeyeBullet"
	bullet.Size       = bulletSize
	bullet.Color      = isEnhanced
		and Color3.fromRGB(255, 210, 60)
		or  Color3.fromRGB(255, 245, 200)
	bullet.Material   = Enum.Material.Neon
	bullet.Anchored   = true
	bullet.CanCollide = false
	bullet.CastShadow = false
	bullet.CFrame     = CFrame.new(fromPos, toPos)
	bullet.Parent     = Workspace

	if isEnhanced then
		local light = Instance.new("PointLight")
		light.Brightness = 4
		light.Color      = Color3.fromRGB(255, 200, 60)
		light.Range      = 10
		light.Parent     = bullet
	end

	local attFront = Instance.new("Attachment")
	attFront.Position = Vector3.new(0, 0, bulletSize.Z / 2)
	attFront.Parent   = bullet

	local attBack = Instance.new("Attachment")
	attBack.Position = Vector3.new(0, 0, -(bulletSize.Z / 2))
	attBack.Parent   = bullet

	local trail = Instance.new("Trail")
	trail.Attachment0 = attFront
	trail.Attachment1 = attBack
	trail.Lifetime    = isEnhanced and 0.12 or 0.07
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
		NumberSequenceKeypoint.new(0,   isEnhanced and 1.4 or 1),
		NumberSequenceKeypoint.new(0.5, isEnhanced and 0.7 or 0.5),
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
		task.delay(0.14, function()
			if bullet and bullet.Parent then bullet:Destroy() end
		end)
	end)
end

-- ============================================================
-- VFX – BARREL MUZZLE FLASH  (called on every shot)
-- ============================================================

function Deadeye.SpawnBarrelFlash(position: Vector3, isEnhanced: boolean?)
	local anchor = Instance.new("Part")
	anchor.Name         = "MuzzleFlash"
	anchor.Size         = Vector3.new(0.05, 0.05, 0.05)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.CastShadow   = false
	anchor.Position     = position
	anchor.Parent       = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	-- Burst of flash particles
	local flash = Instance.new("ParticleEmitter")
	flash.Color = ColorSequence.new(
		isEnhanced
			and Color3.fromRGB(255, 200, 60)
			or  Color3.fromRGB(255, 240, 160)
	)
	flash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   isEnhanced and 0.55 or 0.28),
		NumberSequenceKeypoint.new(0.4, isEnhanced and 0.28 or 0.14),
		NumberSequenceKeypoint.new(1,   0),
	})
	flash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	flash.Lifetime    = NumberRange.new(0.03, 0.09)
	flash.Speed       = NumberRange.new(2, isEnhanced and 14 or 8)
	flash.SpreadAngle = Vector2.new(50, 50)
	flash.RotSpeed    = NumberRange.new(-180, 180)
	flash.Rate        = 0
	flash.Parent      = att
	flash:Emit(isEnhanced and 10 or 5)

	-- Smoke wisp
	local smoke = Instance.new("ParticleEmitter")
	smoke.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 200, 200)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 100, 100)),
	})
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.08),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Lifetime    = NumberRange.new(0.15, 0.3)
	smoke.Speed       = NumberRange.new(1, 4)
	smoke.SpreadAngle = Vector2.new(25, 25)
	smoke.Rate        = 0
	smoke.Parent      = att
	smoke:Emit(3)

	-- Soft ambient glow (replaces jarring PointLight flash)
	local glow = Instance.new("PointLight")
	glow.Brightness = isEnhanced and 1.5 or 0.8
	glow.Color      = isEnhanced and Color3.fromRGB(255, 185, 50) or Color3.fromRGB(255, 240, 140)
	glow.Range      = isEnhanced and 10 or 6
	glow.Parent     = anchor

	TweenService:Create(glow, TweenInfo.new(0.25, Enum.EasingStyle.Quad), {Brightness = 0}):Play()

	task.delay(0.35, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- ============================================================
-- VFX – NORMAL HIT PARTICLES
-- ============================================================

function Deadeye.SpawnHitParticles(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Name         = "HitVFXAnchor"
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Position     = position
	anchor.Parent       = Workspace

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
	splatter.Lifetime     = NumberRange.new(0.15, 0.3)
	splatter.Speed        = NumberRange.new(3, 10)
	splatter.SpreadAngle  = Vector2.new(180, 90)
	splatter.Acceleration = Vector3.new(0, -15, 0)
	splatter.Rate         = 0
	splatter.Parent       = att
	splatter:Emit(8)

	task.delay(0.5, function()
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- ============================================================
-- VFX – HEADHUNTER ENHANCED HIT  (impressive 3rd-shot impact)
-- ============================================================

function Deadeye.SpawnEnhancedHitVFX(position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name         = "HeadhunterHitAnchor"
	anchor.Size         = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Position     = position
	anchor.Parent       = Workspace

	local att = Instance.new("Attachment")
	att.Parent = anchor

	-- ── Expanding shockwave ring ──
	local ring = Instance.new("Part")
	ring.Name        = "ShockwaveRing"
	ring.Shape       = Enum.PartType.Cylinder
	ring.Size        = Vector3.new(0.12, 0.5, 0.5)
	ring.Color       = Color3.fromRGB(255, 210, 50)
	ring.Material    = Enum.Material.Neon
	ring.Transparency = 0.15
	ring.Anchored    = true
	ring.CanCollide  = false
	ring.CastShadow  = false
	ring.CFrame      = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent      = Workspace

	TweenService:Create(ring,
		TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.05, 7, 7), Transparency = 1 }
	):Play()

	-- Second, slightly delayed ring
	task.delay(0.08, function()
		if not anchor.Parent then return end
		local ring2 = Instance.new("Part")
		ring2.Name        = "ShockwaveRing2"
		ring2.Shape       = Enum.PartType.Cylinder
		ring2.Size        = Vector3.new(0.10, 0.3, 0.3)
		ring2.Color       = Color3.fromRGB(255, 255, 140)
		ring2.Material    = Enum.Material.Neon
		ring2.Transparency = 0.25
		ring2.Anchored    = true
		ring2.CanCollide  = false
		ring2.CastShadow  = false
		ring2.CFrame      = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
		ring2.Parent      = Workspace
		TweenService:Create(ring2,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.04, 5, 5), Transparency = 1 }
		):Play()
		task.delay(0.4, function()
			if ring2 and ring2.Parent then ring2:Destroy() end
		end)
	end)

	-- ── Large centre flash ──
	local bigFlash = Instance.new("ParticleEmitter")
	bigFlash.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 180)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 190, 40)),
	})
	bigFlash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   2.2),
		NumberSequenceKeypoint.new(0.3, 1.0),
		NumberSequenceKeypoint.new(1,   0),
	})
	bigFlash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	bigFlash.Lifetime    = NumberRange.new(0.1, 0.22)
	bigFlash.Speed       = NumberRange.new(4, 18)
	bigFlash.SpreadAngle = Vector2.new(180, 180)
	bigFlash.Rate        = 0
	bigFlash.Parent      = att
	bigFlash:Emit(14)

	-- ── Gold sparks (long-lived, gravity-affected) ──
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 230, 60)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 140, 20)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 80,  10)),
	})
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.18),
		NumberSequenceKeypoint.new(0.6, 0.09),
		NumberSequenceKeypoint.new(1,   0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0),
		NumberSequenceKeypoint.new(0.7, 0.1),
		NumberSequenceKeypoint.new(1,   1),
	})
	sparks.LightEmission = 0.8
	sparks.Lifetime      = NumberRange.new(0.35, 0.75)
	sparks.Speed         = NumberRange.new(10, 28)
	sparks.SpreadAngle   = Vector2.new(180, 180)
	sparks.Acceleration  = Vector3.new(0, -28, 0)
	sparks.Rate          = 0
	sparks.Parent        = att
	sparks:Emit(28)

	-- ── White-hot core pop ──
	local core = Instance.new("ParticleEmitter")
	core.Color = ColorSequence.new(Color3.fromRGB(255, 255, 240))
	core.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   1.0),
		NumberSequenceKeypoint.new(0.2, 0.4),
		NumberSequenceKeypoint.new(1,   0),
	})
	core.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	core.LightEmission = 1
	core.Lifetime      = NumberRange.new(0.06, 0.12)
	core.Speed         = NumberRange.new(0, 3)
	core.SpreadAngle   = Vector2.new(180, 180)
	core.Rate          = 0
	core.Parent        = att
	core:Emit(6)

	-- ── Smoke bloom ──
	local smokeBloom = Instance.new("ParticleEmitter")
	smokeBloom.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(180, 130, 50)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 90,  40)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(60,  55,  50)),
	})
	smokeBloom.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.4),
		NumberSequenceKeypoint.new(0.5, 1.0),
		NumberSequenceKeypoint.new(1,   1.8),
	})
	smokeBloom.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.4),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1,   1),
	})
	smokeBloom.Lifetime     = NumberRange.new(0.5, 0.9)
	smokeBloom.Speed        = NumberRange.new(2, 7)
	smokeBloom.SpreadAngle  = Vector2.new(180, 180)
	smokeBloom.Acceleration = Vector3.new(0, 4, 0)
	smokeBloom.Rate         = 0
	smokeBloom.Parent       = att
	smokeBloom:Emit(10)

	-- ── Soft point-light (replaces jarring full-brightness flash) ──
	local light = Instance.new("PointLight")
	light.Brightness = 2
	light.Color      = Color3.fromRGB(255, 210, 60)
	light.Range      = 16
	light.Parent     = anchor

	TweenService:Create(light,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad),
		{Brightness = 0}
	):Play()

	task.delay(0.9, function()
		if ring   and ring.Parent   then ring:Destroy()   end
		if anchor and anchor.Parent then anchor:Destroy() end
	end)
end

-- ============================================================
-- VFX – HEADHUNTER AIM LASER
-- ============================================================

function Deadeye.ShowAimLaser(tower: Model, target: Model)
	if aimBeams[tower] then
		local data = aimBeams[tower]
		if target.PrimaryPart and data.att1Part then
			data.att1Part.Position = target.PrimaryPart.Position
		end
		return
	end

	local torso  = tower.PrimaryPart
	if not torso then return end

	-- Find the gun barrel (may be Attachment or BasePart)
	local barrel = tower:FindFirstChild("GunBarrel", true)

	local att0 = Instance.new("Attachment")
	if barrel then
		if barrel:IsA("Attachment") then
			-- Attach directly to the barrel attachment's parent part
			att0.Position = barrel.Position
			att0.Parent   = barrel.Parent or torso
		elseif barrel:IsA("BasePart") then
			att0.Position = Vector3.new(0, 0, -(barrel.Size.Z / 2))
			att0.Parent   = barrel
		else
			att0.Parent = torso
		end
	else
		att0.Parent = torso
	end

	local att1Part = Instance.new("Part")
	att1Part.Name         = "AimLaserAnchor"
	att1Part.Size         = Vector3.new(0.05, 0.05, 0.05)
	att1Part.Transparency = 1
	att1Part.Anchored     = true
	att1Part.CanCollide   = false
	att1Part.CastShadow   = false
	if target.PrimaryPart then
		att1Part.Position = target.PrimaryPart.Position
	end
	att1Part.Parent = Workspace

	local att1 = Instance.new("Attachment")
	att1.Parent = att1Part

	local beam = Instance.new("Beam")
	beam.Attachment0    = att0
	beam.Attachment1    = att1
	beam.Width0         = 0.06
	beam.Width1         = 0.06
	beam.Segments       = 1
	beam.FaceCamera     = true
	beam.LightEmission  = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 30,  30)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 120, 50)),
		ColorSequenceKeypoint.new(1,   Color3.fromRGB(255, 30,  30)),
	})
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0.0),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1,   0.0),
	})
	beam.Parent = att1Part

	aimBeams[tower] = { att0 = att0, att1Part = att1Part, att1 = att1, beam = beam }
end

function Deadeye.HideAimLaser(tower: Model)
	local data = aimBeams[tower]
	if not data then return end
	pcall(function()
		data.att0:Destroy()
		data.att1Part:Destroy()
	end)
	aimBeams[tower] = nil
end

-- ============================================================
-- MODEL CREATION
-- ============================================================

function Deadeye.CreateModel(position: Vector3, TowerStats: any): Model?
	local template = TowerStats.Templates["Deadeye"]
	if not template then return nil end

	local towerModels   = ServerStorage:FindFirstChild("TowerModels")
	local templateModel = towerModels and towerModels:FindFirstChild("Deadeye")
	if not templateModel then
		warn("[Deadeye] ServerStorage.TowerModels.Deadeye not found")
		return nil
	end

	local model = templateModel:Clone()
	model.Name  = "Deadeye"

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
	safeStop(st.idleTrack,    0.15)
	safeStop(st.raiseTrack,   0.1)
	safeStop(st.aimIdleTrack, 0.1)
	safeStop(st.shootTrack,   0.1)
	safeStop(st.lowerTrack,   0.15)
	safeStop(st.reloadTrack,  0.1)
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
	safeStop(st.idleTrack,  0.12)
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

		-- Start looped aim-idle to hold the raised pose cleanly
		local animator2 = getOrCreateAnimator(tower)
		if animator2 then
			safeDestroy(st.aimIdleTrack)
			st.aimIdleTrack = loadAndPlay(
				animator2, AIM_IDLE_ANIM_ID, true,
				Enum.AnimationPriority.Action, 0.1
			)
		end

		-- Pre-load shoot track (not playing yet)
		safeDestroy(st.shootTrack)
		st.shootTrack = nil
		if animator2 then
			local ok, shootTrack = pcall(function()
				local obj = Instance.new("Animation")
				obj.AnimationId = SHOOT_ANIM_ID
				local t = animator2:LoadAnimation(obj)
				obj:Destroy()
				t.Looped   = false
				t.Priority = Enum.AnimationPriority.Action
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
	safeStop(st.aimIdleTrack, 0.12)
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

-- Plays the reload animation then resets bullet display.
local function triggerReload(tower: Model, st)
	st.reloading    = true
	st.lastShotTime = tick()

	-- All bullets grey immediately
	Deadeye.UpdateBulletDisplay(tower, 0, true)

	safeStop(st.aimIdleTrack, 0.1)
	safeStop(st.shootTrack,   0.1)

	local animator = getOrCreateAnimator(tower)
	if not animator then
		st.reloading = false
		Deadeye.UpdateBulletDisplay(tower, 0, false)
		return
	end

	safeDestroy(st.reloadTrack)
	local reloadTrack = loadAndPlay(
		animator, RELOAD_ANIM_ID, false,
		Enum.AnimationPriority.Action, 0.1
	)
	if not reloadTrack then
		st.reloading = false
		Deadeye.UpdateBulletDisplay(tower, 0, false)
		return
	end
	st.reloadTrack = reloadTrack

	task.spawn(function()
		reloadTrack.Stopped:Wait()
		if not tower or not tower.Parent then return end

		st.reloading    = false
		st.lastShotTime = tick()

		-- All bullets light up again
		Deadeye.UpdateBulletDisplay(tower, 0, false)

		-- Resume aim-idle so raised pose is held again
		local animator2 = getOrCreateAnimator(tower)
		if animator2 and st.gunState == "shoot_hold" then
			safeDestroy(st.aimIdleTrack)
			st.aimIdleTrack = loadAndPlay(
				animator2, AIM_IDLE_ANIM_ID, true,
				Enum.AnimationPriority.Action, 0.1
			)
		end
	end)
end

-- Brief recoil burst for normal shots.
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
			t.Priority = Enum.AnimationPriority.Action
			t:Play(0.05)
			return t
		end)
		if ok and track then
			st.shootTrack = track
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
-- PUBLIC – HEADHUNTER AIM TICKER
-- ============================================================

function Deadeye.TickHeadhunterAim(tower: Model, locked: Model?): boolean
	if not locked or not locked.Parent then
		headhunterAimStart[tower] = nil
		Deadeye.HideAimLaser(tower)
		return false
	end

	if not headhunterAimStart[tower] then
		headhunterAimStart[tower] = tick()
	end

	-- Face the locked target
	local torso = tower.PrimaryPart
	if torso and locked.PrimaryPart then
		local flatDir = Vector3.new(
			locked.PrimaryPart.Position.X - torso.Position.X,
			0,
			locked.PrimaryPart.Position.Z - torso.Position.Z
		)
		if flatDir.Magnitude > 0.1 then
			torso.CFrame = CFrame.new(torso.Position, torso.Position + flatDir.Unit)
		end
	end

	-- Draw / update the red aim laser each tick
	Deadeye.ShowAimLaser(tower, locked)

	-- Uses HEADHUNTER_AIM_TIME, not GUN_RAISE_DELAY
	local elapsed = tick() - headhunterAimStart[tower]
	if elapsed >= Deadeye.HEADHUNTER_AIM_TIME then
		headhunterAimStart[tower] = nil
		Deadeye.HideAimLaser(tower)
		return true
	end

	return false
end

-- ============================================================
-- PUBLIC – ANIMATION INTERFACE
-- ============================================================

function Deadeye.InitTower(tower: Model)
	local st = getAnimState(tower)
	playIdle(tower, st)
	Deadeye.CreateBulletDisplay(tower)
	Deadeye.UpdateBulletDisplay(tower, 0, false)
end

function Deadeye.IsReadyToFire(tower: Model): boolean
	local st = animState[tower]
	if not st then return false end
	if st.reloading then return false end
	return st.gunState == "shoot_hold" and tick() >= st.readyToFireTime
end

function Deadeye.UpdateCombatState(tower: Model, hasTarget: boolean, target: Model?)
	local st = getAnimState(tower)
	if not st then return end

	-- Don't drive state transitions while reloading
	if st.reloading then return end

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

function Deadeye.DoAttack(tower: Model, target: Model, enemiesFolder: Folder?): boolean
	local st = getAnimState(tower)

	if st.reloading then return false end

	local atk   = tower:GetAttribute("ATK")             or 12
	local ap    = tower:GetAttribute("AP")               or atk
	local multi = tower:GetAttribute("DamageMulti")      or 1.0
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

	-- Capture impact position before possible destroy
	local impactPos = actualTarget.PrimaryPart.Position

	-- ── Damage ──
	if isEnhanced then
		-- Headhunter – bullet 3
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

		-- ── Enhanced VFX ──
		Deadeye.SpawnEnhancedHitVFX(impactPos)

		if torso then
			local barrel  = tower:FindFirstChild("GunBarrel", true)
			local fromPos = barrel and barrel.WorldPosition or torso.Position
			Deadeye.SpawnBarrelFlash(fromPos, true)
			Deadeye.SpawnBullet(fromPos, impactPos, true)
		end

		-- ── Play the FULL shoot animation, then reload after it finishes ──
		playShootBrief(tower, st)
		st.lastShotTime = tick()

		-- Mark bullet 3 as spent visually right away
		Deadeye.UpdateBulletDisplay(tower, 3, false)

		task.spawn(function()
			-- Wait for the recoil animation to play to completion before reloading
			if st.shootTrack then
				if st.shootTrack.IsPlaying then
					st.shootTrack.Stopped:Wait()
				else
					task.wait(0.25)
				end
			else
				task.wait(0.25)
			end
			if tower and tower.Parent and not st.reloading then
				triggerReload(tower, st)
			end
		end)

	else
		-- Revolver – bullet 1 or 2
		local newCount = count + 1
		tower:SetAttribute("BasicAttackCount", newCount)
		local damage = atk * multi
		local hp     = actualTarget:GetAttribute("HP") or 0
		local newHP  = hp - damage
		actualTarget:SetAttribute("HP", newHP)
		if newHP <= 0 and actualTarget.Parent then
			actualTarget:Destroy()
		end

		-- Grey out the fired bullet slot
		Deadeye.UpdateBulletDisplay(tower, newCount, false)

		-- ── Normal VFX ──
		Deadeye.SpawnHitParticles(impactPos, Color3.fromRGB(210, 210, 255))

		if torso then
			local barrel  = tower:FindFirstChild("GunBarrel", true)
			local fromPos = barrel and barrel.WorldPosition or torso.Position
			Deadeye.SpawnBarrelFlash(fromPos, false)
			Deadeye.SpawnBullet(fromPos, impactPos, false)
		end

		-- ── Brief recoil animation & timer ──
		playShootBrief(tower, st)
		st.lastShotTime = tick()
	end

	return true
end

-- ============================================================
-- CLEANUP
-- ============================================================

function Deadeye.CleanupTower(tower: Model)
	local st = animState[tower]
	if st then
		safeDestroy(st.idleTrack)
		safeDestroy(st.raiseTrack)
		safeDestroy(st.aimIdleTrack)
		safeDestroy(st.shootTrack)
		safeDestroy(st.lowerTrack)
		safeDestroy(st.reloadTrack)
		animState[tower] = nil
	end

	baseC0s[tower] = nil

	local wt = walkTracks[tower]
	if wt then
		pcall(function() wt:Stop(0); wt:Destroy() end)
		walkTracks[tower] = nil
	end

	local gd = bulletGuis[tower]
	if gd then
		pcall(function() gd.billboard:Destroy() end)
		bulletGuis[tower] = nil
	end

	Deadeye.HideAimLaser(tower)
	headhunterAimStart[tower] = nil
end

return Deadeye
