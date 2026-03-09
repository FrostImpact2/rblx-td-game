--[[
	EnemyManager (Server Script)
	Place in ServerScriptService/

	Coordinates enemy spawning and wave logic.
	Delegates per-enemy behaviour to enemy modules (e.g. BasicZombie).
]]

local ServerStorage     = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local EnemyStats        = require(ReplicatedStorage:WaitForChild("EnemyStats", 10))
local PathfindingModule = require(ReplicatedStorage:WaitForChild("PathfindingModule", 10))

if not EnemyStats        then error("[EnemyManager] Could not find EnemyStats!")        end
if not PathfindingModule then error("[EnemyManager] Could not find PathfindingModule!") end

-- Individual enemy modules
local BasicZombie = require(script.Parent:WaitForChild("Enemies"):WaitForChild("BasicZombie", 10))

print("[EnemyManager] Modules loaded!")

-- Workspace references
local pathFolder    = Workspace:WaitForChild("Path", 10)
local enemiesFolder = Workspace:WaitForChild("Enemies", 10)
local spawnPart     = Workspace:WaitForChild("EnemySpawn", 10)
local basePart      = Workspace:WaitForChild("Base", 10)

if not pathFolder    then error("[EnemyManager] Missing 'Path' folder!")     end
if not enemiesFolder then error("[EnemyManager] Missing 'Enemies' folder!")  end
if not spawnPart     then error("[EnemyManager] Missing 'EnemySpawn' part!") end
if not basePart      then error("[EnemyManager] Missing 'Base' part!")       end

-- Model templates stored in ServerStorage/EnemyModels/
local modelTemplates = ServerStorage:WaitForChild("EnemyModels", 10)
if not modelTemplates then error("[EnemyManager] Missing 'EnemyModels' folder in ServerStorage!") end

local waypoints = PathfindingModule.BuildWaypoints(pathFolder)
print("[EnemyManager] Found " .. #waypoints .. " waypoints.")
if #waypoints == 0 then error("[EnemyManager] No waypoints found!") end

-- ============================================================
-- EXPOSE PUNCH ANIMATION  (TowerManager invokes this to play
-- the animation on a specific enemy via its enemy module)
-- ============================================================

local punchBindable       = Instance.new("BindableFunction")
punchBindable.Name        = "PlayEnemyPunch"
punchBindable.Parent      = ReplicatedStorage

punchBindable.OnInvoke = function(enemyModel: Model)
	BasicZombie.PlayPunchAnimation(enemyModel)
end

-- ============================================================
-- ENEMY MODEL CREATION
-- ============================================================

local function createEnemyModel(templateName: string): Model?
	local stats = EnemyStats.Templates[templateName]
	if not stats then
		warn("[EnemyManager] Unknown template: " .. templateName)
		return nil
	end

	local modelTemplate = modelTemplates:FindFirstChild(templateName)
	if not modelTemplate then
		warn("[EnemyManager] No model named '" .. templateName .. "' in ServerStorage.EnemyModels!")
		return nil
	end

	local model = modelTemplate:Clone()
	model.Name  = templateName

	-- Ensure PrimaryPart is set
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

	-- Apply stats as model attributes
	model:SetAttribute("ATK",        stats.ATK)
	model:SetAttribute("ATK_SPD",    stats.ATK_SPD)
	model:SetAttribute("MOVE_SPD",   stats.MOVE_SPD)
	model:SetAttribute("HP",         stats.HP)
	model:SetAttribute("MaxHP",      stats.HP)
	model:SetAttribute("RNG",        stats.RNG)
	model:SetAttribute("TARGETING",  stats.TARGETING)

	local rangeStuds = EnemyStats.ResolveRng(stats.RNG)
	model:SetAttribute("RangeStuds", rangeStuds)

	-- Flat range-circle indicator (shown/hidden by client)
	local circle = Instance.new("Part")
	circle.Name         = "RangeCircle"
	circle.Shape        = Enum.PartType.Cylinder
	circle.Size         = Vector3.new(0.15, rangeStuds * 2, rangeStuds * 2)
	circle.Anchored     = true
	circle.CanCollide   = false
	circle.Color        = Color3.fromRGB(30, 100, 200)
	circle.Material     = Enum.Material.SmoothPlastic
	circle.Transparency = 1
	circle.Parent       = model

	return model
end

-- ============================================================
-- ENEMY SPAWNING
-- ============================================================

local activeEnemies = {}

local function spawnEnemy(templateName: string)
	local model = createEnemyModel(templateName)
	if not model then return end

	local root     = model.PrimaryPart
	local spawnPos = spawnPart.Position + Vector3.new(0, 3.3, 0)

	root.Anchored = true
	model:PivotTo(CFrame.new(spawnPos))
	model.Parent = enemiesFolder

	-- Keep the range-circle flush with the ground as the enemy moves
	local circle = model:FindFirstChild("RangeCircle")
	root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if circle and circle.Parent then
			local pos = root.Position
			circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end)

	-- Delegate animation setup to the appropriate enemy module
	BasicZombie.SetupAnimations(model)

	local moveSpeed = EnemyStats.ResolveMoveSpd(model:GetAttribute("MOVE_SPD"))
	print("[EnemyManager] Spawned " .. templateName .. " | Speed: " .. moveSpeed)

	local stopFunc = PathfindingModule.StartMoving(
		model,
		waypoints,
		moveSpeed,
		function()
			-- Enemy reached the base
			BasicZombie.StopAnimations(model)
			local baseHP = basePart:GetAttribute("HP") or 100
			local atk    = model:GetAttribute("ATK") or 1
			basePart:SetAttribute("HP", baseHP - atk)
			print("[EnemyManager] Enemy reached base! Base HP: " .. tostring(basePart:GetAttribute("HP")))
			model:Destroy()
		end
	)

	table.insert(activeEnemies, { Model = model, Stop = stopFunc })
end

-- ============================================================
-- WAVE SPAWNING
-- ============================================================

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
-- START
-- ============================================================

print("[EnemyManager] Starting in 3 seconds...")
task.wait(3)
print("[EnemyManager] SPAWNING WAVE!")
spawnWave("BasicZombie", 5, 2)
