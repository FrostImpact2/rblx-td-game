--[[
	EnemyManager (Server Script)
	
	Clones a pre-built enemy model from ServerStorage and
	plays its walk animation. Replaces the legacy procedural version.
]]

local ServerStorage    = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace        = game:GetService("Workspace")

local EnemyStats        = require(ReplicatedStorage:WaitForChild("EnemyStats", 10))
local PathfindingModule = require(ReplicatedStorage:WaitForChild("PathfindingModule", 10))

if not EnemyStats then error("[EnemyManager] Could not find EnemyStats!") end
if not PathfindingModule then error("[EnemyManager] Could not find PathfindingModule!") end

print("[EnemyManager] Modules loaded!")

-- Workspace references (same as before)
local pathFolder    = Workspace:WaitForChild("Path", 10)
local enemiesFolder = Workspace:WaitForChild("Enemies", 10)
local spawnPart     = Workspace:WaitForChild("EnemySpawn", 10)
local basePart      = Workspace:WaitForChild("Base", 10)

if not pathFolder then error("[EnemyManager] Missing 'Path' folder!") end
if not enemiesFolder then error("[EnemyManager] Missing 'Enemies' folder!") end
if not spawnPart then error("[EnemyManager] Missing 'EnemySpawn' part!") end
if not basePart then error("[EnemyManager] Missing 'Base' part!") end

-- Model templates folder in ServerStorage
local modelTemplates = ServerStorage:WaitForChild("EnemyModels", 10)
if not modelTemplates then error("[EnemyManager] Missing 'EnemyModels' folder in ServerStorage!") end

local waypoints = PathfindingModule.BuildWaypoints(pathFolder)
print("[EnemyManager] Found " .. #waypoints .. " waypoints.")
if #waypoints == 0 then error("[EnemyManager] No waypoints found!") end

-- ============================================================
-- ANIMATION HELPERS
-- ============================================================

local walkTracks = {}  -- enemyModel -> AnimationTrack
local punchTracks = {} -- enemyModel -> AnimationTrack

local function getOrCreateAnimator(enemyModel: Model): Animator?
	local humanoid = enemyModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn("[EnemyManager] No Humanoid in enemy model, can't animate")
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

local function startWalkAnimation(enemyModel: Model)
	local animator = getOrCreateAnimator(enemyModel)
	if not animator then return end

	local walkAnimObj = enemyModel:FindFirstChild("WalkAnim")
		or enemyModel:FindFirstChildOfClass("Humanoid"):FindFirstChild("WalkAnim")
	if not walkAnimObj then
		warn("[EnemyManager] No 'WalkAnim' Animation found in model")
		return
	end

	local track = animator:LoadAnimation(walkAnimObj)
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Movement
	track:Play()
	walkTracks[enemyModel] = track

	-- Pre-load the punch animation
	local punchAnimObj = enemyModel:FindFirstChild("PunchAnim")
		or enemyModel:FindFirstChildOfClass("Humanoid"):FindFirstChild("PunchAnim")
	if punchAnimObj then
		local punchTrack = animator:LoadAnimation(punchAnimObj)
		punchTrack.Looped = false
		punchTrack.Priority = Enum.AnimationPriority.Action

		-- Scale animation speed to match attack speed
		local atkSpdTier = enemyModel:GetAttribute("ATK_SPD") or "SLOW"
		local atkSpdLookup = {
			["VERY SLOW"]  = 0.8,
			["SLOW"]       = 1.0,
			["MEDIUM"]     = 1.5,
			["FAST"]       = 2.5,
			["VERY FAST"]  = 4.0,
		}
		local animSpeed = atkSpdLookup[atkSpdTier] or 1.0
		punchTrack:AdjustSpeed(animSpeed)

		punchTracks[enemyModel] = punchTrack
	end

	-- Handle walk stop/start AND hold punch frame 0 when aggroed
	enemyModel:GetAttributeChangedSignal("WalkStopped"):Connect(function()
		local stopped = enemyModel:GetAttribute("WalkStopped")
		local punchTrack = punchTracks[enemyModel]

		if stopped then
			-- Stop walking
			track:Stop(0.2)

			-- Hold at first frame of punch animation (combat stance)
			if punchTrack then
				punchTrack:Play(0.2)
				punchTrack:AdjustSpeed(0) -- freeze at frame 0
				punchTrack.TimePosition = 0
			end
		else
			-- Resume walking
			track:Play(0.2)

			-- Stop the punch pose
			if punchTrack then
				punchTrack:Stop(0.2)
			end
		end
	end)
end

local function stopWalkAnimation(enemyModel: Model)
	local track = walkTracks[enemyModel]
	if track then
		track:Stop(0.15)
		track:Destroy()
		walkTracks[enemyModel] = nil
	end
	local punchTrack = punchTracks[enemyModel]
	if punchTrack then
		punchTrack:Stop()
		punchTrack:Destroy()
		punchTracks[enemyModel] = nil
	end
end

local function playPunchAnimation(enemyModel: Model)
	local track = punchTracks[enemyModel]
	if not track then return end

	-- Unpause and play from the beginning
	track.TimePosition = 0
	track:AdjustSpeed(1)
	track:Play(0.05) -- snappy fade-in since we're already in the pose

	-- When the punch finishes, freeze back at frame 0
	local conn
	conn = track.Stopped:Connect(function()
		conn:Disconnect()
		-- Only re-freeze if still aggroed
		if enemyModel:GetAttribute("WalkStopped") then
			track:Play(0)
			track:AdjustSpeed(0)
			track.TimePosition = 0
		end
	end)
end

-- ============================================================
-- EXPOSE PUNCH ANIMATION FOR TOWERMANAGER
-- ============================================================

local punchBindable = Instance.new("BindableFunction")
punchBindable.Name = "PlayEnemyPunch"
punchBindable.Parent = ReplicatedStorage

punchBindable.OnInvoke = function(enemyModel: Model)
	playPunchAnimation(enemyModel)
end

-- ============================================================
-- CREATE ENEMY MODEL (clone from ServerStorage)
-- ============================================================

local function createEnemyModel(templateName: string): Model
	local stats = EnemyStats.Templates[templateName]
	if not stats then
		warn("[EnemyManager] Unknown template: " .. templateName)
		return nil
	end

	-- Find the model template in ServerStorage.EnemyModels
	local modelTemplate = modelTemplates:FindFirstChild(templateName)
	if not modelTemplate then
		warn("[EnemyManager] No model named '" .. templateName .. "' in ServerStorage.EnemyModels!")
		return nil
	end

	-- Clone the model
	local model = modelTemplate:Clone()
	model.Name = templateName

	-- Verify PrimaryPart
	if not model.PrimaryPart then
		local hrp = model:FindFirstChild("HumanoidRootPart")
		if hrp then
			model.PrimaryPart = hrp
		else
			warn("[EnemyManager] Model has no HumanoidRootPart or PrimaryPart set!")
			model:Destroy()
			return nil
		end
	end

	-- Apply stats as attributes (same as legacy)
	model:SetAttribute("ATK", stats.ATK)
	model:SetAttribute("ATK_SPD", stats.ATK_SPD)
	model:SetAttribute("MOVE_SPD", stats.MOVE_SPD)
	model:SetAttribute("HP", stats.HP)
	model:SetAttribute("MaxHP", stats.HP)
	model:SetAttribute("RNG", stats.RNG)
	model:SetAttribute("TARGETING", stats.TARGETING)

	local rangeStuds = EnemyStats.ResolveRng(stats.RNG)
	model:SetAttribute("RangeStuds", rangeStuds)

	-- Range circle (same as legacy)
	local circle = Instance.new("Part")
	circle.Name = "RangeCircle"
	circle.Shape = Enum.PartType.Cylinder
	circle.Size = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored = true
	circle.CanCollide = false
	circle.Color = Color3.fromRGB(30, 100, 200)
	circle.Material = Enum.Material.SmoothPlastic
	circle.Transparency = 1
	circle.Parent = model

	return model
end


-- SPAWN ENEMY

local activeEnemies = {}

local function spawnEnemy(templateName: string)
	local model = createEnemyModel(templateName)
	if not model then return end

	local root = model.PrimaryPart
	local spawnPos = spawnPart.Position + Vector3.new(0, 3.3, 0)

	root.Anchored = true
	model:PivotTo(CFrame.new(spawnPos))
	model.Parent = enemiesFolder

	local circle = model:FindFirstChild("RangeCircle")
	root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if circle and circle.Parent then
			local pos = root.Position
			circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end)

	startWalkAnimation(model) --MAKE TS WORK LATER

	local moveTier = model:GetAttribute("MOVE_SPD")
	local moveSpeed = EnemyStats.ResolveMoveSpd(moveTier)

	print("[EnemyManager] Spawned " .. templateName .. " | Speed: " .. moveSpeed)

	local stopFunc = PathfindingModule.StartMoving(
		model,
		waypoints,
		moveSpeed,
		function()
			stopWalkAnimation(model)
			local baseHP = basePart:GetAttribute("HP") or 100
			local atk = model:GetAttribute("ATK") or 1
			basePart:SetAttribute("HP", baseHP - atk)
			print("[EnemyManager] Enemy reached base! Base HP: " .. basePart:GetAttribute("HP"))
			model:Destroy()
		end
	)

	table.insert(activeEnemies, { Model = model, Stop = stopFunc })
end

local function spawnWave(templateName: string, count: number, delayBetween: number)
	task.spawn(function()
		for i = 1, count do
			print("[EnemyManager] Spawning enemy " .. i .. "/" .. count)
			spawnEnemy(templateName)
			if i < count then
				task.wait(delayBetween)
			end
		end
	end)
end

-- ============================================================
-- GO!
-- ============================================================

print("[EnemyManager] Starting in 3 seconds...")
task.wait(3)
print("[EnemyManager] SPAWNING WAVE!")
spawnWave("BasicZombie", 5, 2)