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
	  shoot_hold  →  reloading  →  shoot_hold  (after enhanced shot)
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

	Bullet display
	  3 bullet icons float above the tower's head.
	  Bullets 1 & 2 are gold  → grey when spent.
	  Bullet  3 is glowing    → grey when spent.
	  After the enhanced shot fires all three become grey and the reload
	  animation plays before the display resets.
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
local IDLE_ANIM_ID     = "rbxassetid://130403916615858"
local WALK_ANIM_ID     = "rbxassetid://73323871613223"
local RAISE_ANIM_ID    = "rbxassetid://75900515991486"
local AIM_IDLE_ANIM_ID = "rbxassetid://112216226009616"
local SHOOT_ANIM_ID    = "rbxassetid://108396781520756"
local LOWER_ANIM_ID    = "rbxassetid://107226036750887"
local RELOAD_ANIM_ID   = "rbxassetid://134398343804499"

-- ====== BULLET DISPLAY COLOURS ======
local BULLET_ACTIVE_COLOR = Color3.fromRGB(220, 175, 50)
local BULLET_GLOW_COLOR   = Color3.fromRGB(255, 210, 0)
local BULLET_GLOW_STROKE  = Color3.fromRGB(255, 240, 120)
local BULLET_SPENT_COLOR  = Color3.fromRGB(75,  75,  75)
local BULLET_SPENT_STROKE = Color3.fromRGB(55,  55,  55)

-- ============================================================
-- INTERNAL STATE
-- ============================================================

local animState  = {}   -- tower → animation-state record
local baseC0s    = {}   -- tower → stored Motor6D C0 values
local walkTracks = {}   -- tower → active walk AnimationTrack
local bulletGuis = {}   -- tower → { billboard, bullets[] }

local headhunterAimStart = {}  -- tower → tick() when Headhunter lock-on began
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
			-- "idle" | "raising" | "raised" | "shoot_hold" | "lowering" | "walking"
			gunState     = "idle",

			idleTrack    = nil,
			raiseTrack   = nil,
			aimIdleTrack = nil,   -- looped aim-idle; holds raised pose
			shootTrack   = nil,   -- one-shot recoil burst
			lowerTrack   = nil,
			reloadTrack  = nil,

			reloading         = false,
			lastShotTime      = -math.huge,
			readyToFireTime   = 0,
		}
	end
	return animState[tower]
end

-- ============================================================
-- BULLET DISPLAY
-- ============================================================

-- Build the BillboardGui with 3 bullet icons above the tower's head.
function Deadeye.CreateBulletDisplay(tower: Model)
	if bulletGuis[tower] then return end

	local head = tower:FindFirstChild("Head") or tower.PrimaryPart
	if not head then return end

	local billboard = Instance.new("BillboardGui")
	billboard.Name           = "BulletDisplay"
	billboard.Size           = UDim2.new(0, 56, 0, 22)
	billboard.StudsOffset    = Vector3.new(0, 3.8, 0)
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
	layout.Padding             = UDim.new(0, 5)
	layout.Parent              = container

	local bullets = {}
	for i = 1, 3 do
		local wrapper = Instance.new("Frame")
		wrapper.Name                    = "Bullet" .. i
		wrapper.Size                    = UDim2.new(0, 9, 0, 20)
		wrapper.BackgroundTransparency  = 1
		wrapper.Parent                  = container

		-- Bullet body (lower 70 %)
		local body = Instance.new("Frame")
		body.Name             = "Body"
		body.Size             = UDim2.new(1, 0, 0.70, 0)
		body.Position         = UDim2.new(0, 0, 0.30, 0)
		body.BorderSizePixel  = 0
		body.BackgroundColor3 = (i == 3) and BULLET_GLOW_COLOR or BULLET_ACTIVE_COLOR
		local bodyCorner = Instance.new("UICorner")
		bodyCorner.CornerRadius = UDim.new(0.18, 0)
		bodyCorner.Parent = body
		body.Parent = wrapper

		-- Bullet tip (upper 38 %, narrower, fully rounded)
		local tip = Instance.new("Frame")
		tip.Name             = "Tip"
		tip.Size             = UDim2.new(0.7, 0, 0.38, 0)
		tip.Position         = UDim2.new(0.15, 0, 0, 0)
		tip.BorderSizePixel  = 0
		tip.BackgroundColor3 = (i == 3) and BULLET_GLOW_COLOR or BULLET_ACTIVE_COLOR
		local tipCorner = Instance.new("UICorner")
		tipCorner.CornerRadius = UDim.new(0.5, 0)
		tipCorner.Parent = tip
		tip.Parent = wrapper

		-- Glow stroke on bullet 3 only
		if i == 3 then
			local strokeBody = Instance.new("UIStroke")
			strokeBody.Name      = "GlowStroke"
			strokeBody.Color     = BULLET_GLOW_STROKE
			strokeBody.Thickness = 1.5
			strokeBody.Parent    = body

			local strokeTip = Instance.new("UIStroke")
			strokeTip.Name      = "GlowStroke"
			strokeTip.Color     = BULLET_GLOW_STROKE
			strokeTip.Thickness = 1.5
			strokeTip.Parent    = tip
		end

		bullets[i] = wrapper
	end

	bulletGuis[tower] = { billboard = billboard, bullets = bullets }
end

-- Refresh bullet colours.
--   count     : current BasicAttackCount (0, 1, or 2)
--   reloading : true while the reload animation is playing
function Deadeye.UpdateBulletDisplay(tower: Model, count: number, reloading: boolean)
	local data = bulletGuis[tower]
	if not data then return end

	for i, wrapper in ipairs(data.bullets) do
		local spent = reloading or (i <= count)
		local body  = wrapper:FindFirstChild("Body")
		local tip   = wrapper:FindFirstChild("Tip")
		if not body or not tip then continue end

		if spent then
			body.BackgroundColor3 = BULLET_SPENT_COLOR
			tip.BackgroundColor3  = BULLET_SPENT_COLOR
			local bs = body:FindFirstChild("GlowStroke")
			local ts = tip:FindFirstChild("GlowStroke")
			if bs then bs.Color = BULLET_SPENT_STROKE end
			if ts then ts.Color = BULLET_SPENT_STROKE end
		else
			local col = (i == 3) and BULLET_GLOW_COLOR or BULLET_ACTIVE_COLOR
			body.BackgroundColor3 = col
			tip.BackgroundColor3  = col
			local bs = body:FindFirstChild("GlowStroke")
			local ts = tip:FindFirstChild("GlowStroke")
			if bs then bs.Color = BULLET_GLOW_STROKE end
			if ts then ts.Color = BULLET_GLOW_STROKE end
		end
	end
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
	bullet.Name       = "DeadeyeBullet"
	bullet.Size       = Vector3.new(0.1, 0.1, 0.55)
	bullet.Color      = isEnhanced
		and Color3.fromRGB(255, 210, 60)
		or  Color3.fromRGB(255, 245, 200)
	bullet.Material   = Enum.Material.Neon
	bullet.Anchored   = true
	bullet.CanCollide = false
	bullet.CastShadow = false
	bullet.CFrame     = CFrame.new(fromPos, toPos)
	bullet.Parent     = Workspace

	local attFront = Instance.new("Attachment")
	attFront.Position = Vector3.new(0, 0,  0.28)
	attFront.Parent   = bullet

	local attBack = Instance.new("Attachment")
	attBack.Position = Vector3.new(0, 0, -0.28)
	attBack.Parent   = bullet

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
	local barrel = tower:FindFirstChild("GunBarrel", true)
	local origin = barrel or torso

	local att0 = Instance.new("Attachment")
	if barrel then
		att0.Position = Vector3.new(0, 0, -(barrel.Size.Z / 2))
	end
	att0.Parent = origin

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

-- Plays the reload animation, then resets bullet display and clears reloading.
local function triggerReload(tower: Model, st)
	st.reloading    = true
	st.lastShotTime = tick()   -- prevent gun-lower timer firing mid-reload

	-- All bullets grey immediately
	Deadeye.UpdateBulletDisplay(tower, 0, true)

	-- Fade out aim-idle and shoot so reload blends in cleanly
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
		st.lastShotTime = tick()   -- restart gun-lower countdown after reload

		-- All bullets light up again
		Deadeye.UpdateBulletDisplay(tower, 0, false)

		-- Resume aim-idle so the raised pose is held again
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

	local elapsed = tick() - headhunterAimStart[tower]
	if elapsed >= Deadeye.GUN_RAISE_DELAY then
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

	-- Block attacks while reloading
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

	-- ── Damage ──
	if isEnhanced then
		-- Headhunter – uses bullet 3
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

		-- Mark all 3 bullets spent, then kick off reload
		Deadeye.UpdateBulletDisplay(tower, 3, false)
		triggerReload(tower, st)
	else
		-- Revolver – uses bullet 1 or 2
		local newCount = count + 1
		tower:SetAttribute("BasicAttackCount", newCount)
		local damage = atk * multi
		local hp     = actualTarget:GetAttribute("HP") or 0
		local newHP  = hp - damage
		actualTarget:SetAttribute("HP", newHP)
		if newHP <= 0 and actualTarget.Parent then
			actualTarget:Destroy()
		end

		-- Grey out the bullet that was just fired
		Deadeye.UpdateBulletDisplay(tower, newCount, false)
	end

	-- ── VFX ──
	if actualTarget.PrimaryPart and actualTarget.Parent then
		local hitColor = isEnhanced
			and Color3.fromRGB(255, 200, 50)
			or  Color3.fromRGB(210, 210, 255)
		Deadeye.SpawnHitParticles(actualTarget.PrimaryPart.Position, hitColor)
	end

	if torso then
		local barrel  = tower:FindFirstChild("GunBarrel", true)
		local fromPos = barrel and barrel.WorldPosition or torso.Position
		local toPos   = (actualTarget.PrimaryPart and actualTarget.PrimaryPart.Position)
			or (torso.Position + torso.CFrame.LookVector * 5)
		Deadeye.SpawnBullet(fromPos, toPos, isEnhanced)
	end

	-- ── Animation & timer ──
	playShootBrief(tower, st)
	st.lastShotTime = tick()

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
