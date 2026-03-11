--[[
	BasicZombie (ModuleScript)
	Place in ServerScriptService/Enemies/

	Handles all BasicZombie-specific enemy behavior:
	  - Walk and punch animation management
	  - Attacking towers (damage, timing, facing)
]]

local FastDummy = {}

-- ============================================================
-- ANIMATION STATE  (per-instance, keyed by model)
-- ============================================================

local walkTracks    = {}  -- model -> AnimationTrack
local punchTracks   = {}  -- model -> AnimationTrack
local attackTimers  = {}  -- model -> last attack timestamp

-- ============================================================
-- CONSTANTS
-- ============================================================

local ATK_SPD_ANIM_SPEED = {
	["VERY SLOW"] = 0.8,
	["SLOW"]      = 1.0,
	["MEDIUM"]    = 1.5,
	["FAST"]      = 2.5,
	["VERY FAST"] = 4.0,
}

local ATK_SPD_COOLDOWN = {
	["VERY SLOW"] = 3.0,
	["SLOW"]      = 2.0,
	["MEDIUM"]    = 1.2,
	["FAST"]      = 0.7,
	["VERY FAST"] = 0.3,
}

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================

local function getOrCreateAnimator(enemyModel: Model): Animator?
	local humanoid = enemyModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn("[BasicZombie] No Humanoid in model, can't animate")
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

-- ============================================================
-- ANIMATIONS
-- ============================================================

function BasicZombie.SetupAnimations(enemyModel: Model)
	local animator = getOrCreateAnimator(enemyModel)
	if not animator then return end

	local humanoid = enemyModel:FindFirstChildOfClass("Humanoid")

	-- Walk animation
	local walkAnimObj = enemyModel:FindFirstChild("WalkAnim")
		or (humanoid and humanoid:FindFirstChild("WalkAnim"))
	if not walkAnimObj then
		warn("[BasicZombie] No 'WalkAnim' Animation found in model")
		return
	end

	local walkTrack = animator:LoadAnimation(walkAnimObj)
	walkTrack.Looped   = true
	walkTrack.Priority = Enum.AnimationPriority.Movement
	walkTrack:Play()
	walkTracks[enemyModel] = walkTrack

	-- Punch animation (pre-load so it's ready instantly)
	local punchAnimObj = enemyModel:FindFirstChild("PunchAnim")
		or (humanoid and humanoid:FindFirstChild("PunchAnim"))
	if punchAnimObj then
		local punchTrack = animator:LoadAnimation(punchAnimObj)
		punchTrack.Looped   = false
		punchTrack.Priority = Enum.AnimationPriority.Action

		local atkSpdTier = enemyModel:GetAttribute("ATK_SPD") or "SLOW"
		punchTrack:AdjustSpeed(ATK_SPD_ANIM_SPEED[atkSpdTier] or 1.0)
		punchTracks[enemyModel] = punchTrack
	end

	-- React to WalkStopped attribute (set by TowerManager aggro system)
	enemyModel:GetAttributeChangedSignal("WalkStopped"):Connect(function()
		local stopped   = enemyModel:GetAttribute("WalkStopped")
		local punchTrack = punchTracks[enemyModel]

		if stopped then
			walkTrack:Stop(0.2)
			if punchTrack then
				punchTrack:Play(0.2)
				punchTrack:AdjustSpeed(0)   -- freeze at frame 0 (combat stance)
				punchTrack.TimePosition = 0
			end
		else
			walkTrack:Play(0.2)
			if punchTrack then
				punchTrack:Stop(0.2)
			end
		end
	end)
end

function BasicZombie.StopAnimations(enemyModel: Model)
	local walkTrack = walkTracks[enemyModel]
	if walkTrack then
		walkTrack:Stop(0.15)
		walkTrack:Destroy()
		walkTracks[enemyModel] = nil
	end
	local punchTrack = punchTracks[enemyModel]
	if punchTrack then
		punchTrack:Stop()
		punchTrack:Destroy()
		punchTracks[enemyModel] = nil
	end
end

function BasicZombie.PlayPunchAnimation(enemyModel: Model)
	local track = punchTracks[enemyModel]
	if not track then return end

	-- Unpause and play from the beginning
	track.TimePosition = 0
	track:AdjustSpeed(1)
	track:Play(0.05)  -- snappy fade-in since we're already in the pose

	-- When punch finishes, freeze back at frame 0 if still in combat
	local conn
	conn = track.Stopped:Connect(function()
		conn:Disconnect()
		if enemyModel:GetAttribute("WalkStopped") then
			track:Play(0)
			track:AdjustSpeed(0)
			track.TimePosition = 0
		end
	end)
end

-- ============================================================
-- COMBAT: Enemy attacks a tower
-- ============================================================

function BasicZombie.AttackTower(
	enemy: Model,
	tower: Model,
	playEnemyPunchBindable,
	spawnHitParticlesFn: ((Vector3, Color3) -> ())?
)
	local now        = tick()
	local last       = attackTimers[enemy] or 0
	local atkSpdTier = enemy:GetAttribute("ATK_SPD") or "FAST"
	local cooldown   = ATK_SPD_COOLDOWN[atkSpdTier] or 1.2

	if now - last < cooldown then return end
	attackTimers[enemy] = now

	-- Face the tower
	local enemyRoot = enemy.PrimaryPart
	local towerRoot = tower.PrimaryPart
	if enemyRoot and towerRoot then
		local dir = Vector3.new(
			towerRoot.Position.X - enemyRoot.Position.X,
			0,
			towerRoot.Position.Z - enemyRoot.Position.Z
		)
		if dir.Magnitude > 0.1 then
			enemyRoot.CFrame = CFrame.new(enemyRoot.Position, enemyRoot.Position + dir.Unit)
		end
	end

	-- Trigger punch animation via bindable (routes back to PlayPunchAnimation)
	if playEnemyPunchBindable then
		pcall(function()
			playEnemyPunchBindable:Invoke(enemy)
		end)
	end

	-- Deal damage after a short delay timed to punch impact
	task.delay(0.15, function()
		if not enemy or not enemy.Parent or not tower or not tower.Parent then return end

		local atk   = enemy:GetAttribute("ATK") or 1
		local hp    = tower:GetAttribute("HP") or 0
		local newHP = hp - atk

		tower:SetAttribute("HP", newHP)
		tower:SetAttribute("LastCombatTime", tick())

		if tower.PrimaryPart and spawnHitParticlesFn then
			spawnHitParticlesFn(tower.PrimaryPart.Position, Color3.fromRGB(255, 60, 60))
		end

		if newHP <= 0 then tower:Destroy() end
	end)

	local indicatorRemote = game:GetService("ReplicatedStorage"):FindFirstChild("ShowDamageIndicator")
	if indicatorRemote and tower and tower.PrimaryPart then
		indicatorRemote:FireAllClients(tower.PrimaryPart.Position, atk, "Enemy")
	end


end

-- ============================================================
-- CLEANUP: call when an enemy is removed
-- ============================================================

function BasicZombie.CleanupEnemy(enemy: Model)
	attackTimers[enemy] = nil
end

return FastDummy
