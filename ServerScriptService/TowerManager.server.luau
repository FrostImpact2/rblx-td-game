--[[
	TowerManager (Server Script)
	Place in ServerScriptService/

	Coordinates tower placement, targeting, combat AI, aggro, and movement.
	  - Warrior-specific logic is delegated to Towers/Warrior.luau
	  - Deadeye-specific logic is delegated to Towers/Deadeye.luau
	  - Vitalist-specific logic is delegated to Towers/Vitalist.luau
	  - Enemy attack behaviour is delegated to Enemies/BasicZombie.luau
]]


print("[TowerManager] skibid")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local TowerStats        = require(ReplicatedStorage:WaitForChild("TowerStats", 10))
local TowerData         = require(ReplicatedStorage:WaitForChild("TowerData", 10))
local CombatMath        = require(ReplicatedStorage:WaitForChild("CombatMath", 10))
local PathfindingModule = require(ReplicatedStorage:WaitForChild("PathfindingModule", 10))
local CurrencyManager   = require(script.Parent:WaitForChild("CurrencyManager.server", 10))

if not TowerStats then error("[TowerManager] Could not find TowerStats!") end

-- Tower modules
local Warrior    = require(script.Parent:WaitForChild("Towers"):WaitForChild("Warrior",    10))
local Deadeye    = require(script.Parent:WaitForChild("Towers"):WaitForChild("Deadeye",    10))
local Vitalist   = require(script.Parent:WaitForChild("Towers"):WaitForChild("Vitalist",   10))
local Wanderer   = require(script.Parent:WaitForChild("Towers"):WaitForChild("Wanderer",   10))
local Pathfinder = require(script.Parent:WaitForChild("Towers"):WaitForChild("Pathfinder", 10))

-- Enemy modules
local BasicZombie = require(script.Parent:WaitForChild("Enemies"):WaitForChild("BasicZombie", 10))

-- Damage indicator remote  (clients listen to this)
local damageIndicatorRemote      = Instance.new("RemoteEvent")
damageIndicatorRemote.Name       = "ShowDamageIndicator"
damageIndicatorRemote.Parent     = ReplicatedStorage

local activeMovements = {}

-- ============================================================
-- TOWER-MODULE ROUTER
-- ============================================================

local function getTowerModule(tower: Model)
	local tt = tower:GetAttribute("TowerType")
	if tt == "Deadeye"    then return Deadeye    end
	if tt == "Vitalist"   then return Vitalist   end
	if tt == "Wanderer"   then return Wanderer   end
	if tt == "Pathfinder" then return Pathfinder  end
	return Warrior
end

-- Workspace folders
local towersFolder = Workspace:FindFirstChild("Towers")
if not towersFolder then
	towersFolder        = Instance.new("Folder")
	towersFolder.Name   = "Towers"
	towersFolder.Parent = Workspace
end

local enemiesFolder = Workspace:WaitForChild("Enemies", 15)

-- Remotes
local placeRemote       = Instance.new("RemoteEvent")
placeRemote.Name        = "PlaceTower"
placeRemote.Parent      = ReplicatedStorage

local moveRemote        = Instance.new("RemoteEvent")
moveRemote.Name         = "MoveTower"
moveRemote.Parent       = ReplicatedStorage

local strikeSkillRemote  = Instance.new("RemoteEvent")
strikeSkillRemote.Name   = "StrikeSkill"
strikeSkillRemote.Parent = ReplicatedStorage

local sellTowerRemote    = Instance.new("RemoteEvent")
sellTowerRemote.Name     = "SellTower"
sellTowerRemote.Parent   = ReplicatedStorage

local setTargetModeRemote = Instance.new("RemoteEvent")
setTargetModeRemote.Name  = "SetTargetMode"
setTargetModeRemote.Parent = ReplicatedStorage

local playEnemyPunchRemote = ReplicatedStorage:WaitForChild("PlayEnemyPunch", 10)

local pathFolder      = Workspace:WaitForChild("Path", 10)
local cachedWaypoints = pathFolder and PathfindingModule.BuildWaypoints(pathFolder) or {}

-- ============================================================
-- AGGRO STATE
-- ============================================================

local aggroMap     = {}  -- tower  -> enemy
local enemyAggroBy = {}  -- enemy  -> tower
local activePushes = {}  -- enemy  -> RBXScriptConnection

-- ============================================================
-- BURN / FIRE STATE  (from Dynamite explosions)
-- ============================================================

-- enemy -> { burnUntil: number, burnDPS: number, lastTick: number }
local burnMap = {}

-- ============================================================
-- PATH HELPERS
-- ============================================================

local function closestPointOnSegment(A: Vector3, B: Vector3, P: Vector3): Vector3
	local AB    = B - A
	local AP    = P - A
	local lenSq = AB.X * AB.X + AB.Z * AB.Z
	if lenSq < 0.001 then return A end
	local t = math.clamp((AP.X * AB.X + AP.Z * AB.Z) / lenSq, 0, 1)
	return Vector3.new(A.X + AB.X * t, 0, A.Z + AB.Z * t)
end

local function getPathDirection(flatPos: Vector3): Vector3
	local bestDist = math.huge
	local bestDir  = Vector3.new(1, 0, 0)
	for i = 1, #cachedWaypoints - 1 do
		local flatA = Vector3.new(cachedWaypoints[i].X,   0, cachedWaypoints[i].Z)
		local flatB = Vector3.new(cachedWaypoints[i+1].X, 0, cachedWaypoints[i+1].Z)
		local pt    = closestPointOnSegment(flatA, flatB, flatPos)
		local dist  = (pt - flatPos).Magnitude
		if dist < bestDist then
			bestDist = dist
			local seg = flatB - flatA
			if seg.Magnitude > 0.01 then bestDir = seg.Unit end
		end
	end
	return bestDir
end

local function applyDamageToModel(target: Model, rawDamage: number): (number, number)
	local hp      = target:GetAttribute("HP") or 0
	local defense = target:GetAttribute("DEF") or 0
	local damage  = CombatMath.ApplyDefense(rawDamage, defense)
	local newHP   = hp - damage
	target:SetAttribute("HP", newHP)
	if newHP <= 0 and target.Parent then
		target:Destroy()
	end
	return damage, newHP
end

-- ============================================================
-- BODY RADIUS
-- ============================================================

local function getBodyRadius(model: Model): number
	local root = model.PrimaryPart
	if not root then return 1 end
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	local rp = root.Position
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart")
			and part.Name ~= "RangeCircle"
			and part.Name ~= "LeapRangeCircle"
			and part.Name ~= "MoveIndicator"
		then
			local pos = part.Position
			minX = math.min(minX, pos.X - part.Size.X / 2 - rp.X)
			maxX = math.max(maxX, pos.X + part.Size.X / 2 - rp.X)
			minZ = math.min(minZ, pos.Z - part.Size.Z / 2 - rp.Z)
			maxZ = math.max(maxZ, pos.Z + part.Size.Z / 2 - rp.Z)
		end
	end
	return math.max(maxX - minX, maxZ - minZ) / 2
end

-- ============================================================
-- AGGRO PUSH
-- ============================================================

local function startAggroPush(tower: Model, enemy: Model)
	if activePushes[enemy] then return end

	local PUSH_SPEED = 8
	local minDist    = getBodyRadius(enemy) + getBodyRadius(tower) + 0.3

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not enemy or not enemy.Parent or not tower or not tower.Parent then
			conn:Disconnect(); activePushes[enemy] = nil; return
		end
		if not enemy:GetAttribute("Aggroed") then
			conn:Disconnect(); activePushes[enemy] = nil; return
		end

		local er = enemy.PrimaryPart
		local tr = tower.PrimaryPart
		if not er or not tr then conn:Disconnect(); activePushes[enemy] = nil; return end

		local ep      = er.Position
		local tp      = tr.Position
		local flatE   = Vector3.new(ep.X, 0, ep.Z)
		local flatT   = Vector3.new(tp.X, 0, tp.Z)
		local curDist = (flatE - flatT).Magnitude

		if curDist >= minDist then conn:Disconnect(); activePushes[enemy] = nil; return end

		local pathDir       = getPathDirection(flatE)
		local awayFromTower = flatE - flatT
		if awayFromTower.Magnitude < 0.01 then awayFromTower = pathDir end

		local pushDir = (pathDir:Dot(awayFromTower) >= 0) and pathDir or -pathDir
		local step    = math.min(PUSH_SPEED * dt, minDist - curDist)
		local nudge   = pushDir * step
		local newPos  = Vector3.new(ep.X + nudge.X, ep.Y, ep.Z + nudge.Z)

		er.CFrame = CFrame.new(newPos, Vector3.new(tp.X, newPos.Y, tp.Z))
	end)
	activePushes[enemy] = conn
end

-- ============================================================
-- AGGRO
-- ============================================================

local function releaseAggro(tower: Model)
	local enemy = aggroMap[tower]
	if not enemy then return end

	aggroMap[tower]     = nil
	enemyAggroBy[enemy] = nil

	if activePushes[enemy] then
		activePushes[enemy]:Disconnect()
		activePushes[enemy] = nil
	end

	if enemy and enemy.Parent then
		enemy:SetAttribute("Aggroed",     false)
		enemy:SetAttribute("AggroTarget", "")
		enemy:SetAttribute("WalkStopped", false)
	end
end

local function setAggro(tower: Model, enemy: Model)
	releaseAggro(tower)
	if enemyAggroBy[enemy] then return end

	aggroMap[tower]     = enemy
	enemyAggroBy[enemy] = tower

	enemy:SetAttribute("Aggroed",     true)
	enemy:SetAttribute("AggroTarget", tower:GetFullName())
	enemy:SetAttribute("WalkStopped", true)

	startAggroPush(tower, enemy)
end

-- ============================================================
-- TARGETING
-- Unified targeting helper. Modes: "First", "Last", "Strongest", "Weakest", "Random"
-- ============================================================

-- Get enemies in range at a given position
local function getEnemiesInRange(pos: Vector3, range: number, folder: Folder?): {Model}
	local result = {}
	for _, e in ipairs((folder or enemiesFolder):GetChildren()) do
		if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
			if (e.PrimaryPart.Position - pos).Magnitude <= range then
				table.insert(result, e)
			end
		end
	end
	return result
end

-- Score each enemy for "First" targeting:
-- higher score = closer to the end of the path.
-- Uses PathIndex attribute (last waypoint index passed) + fraction toward next waypoint.
local function getProgressScore(enemy: Model): number
	local pathIndex = enemy:GetAttribute("PathIndex") or 0
	local nextDist  = enemy:GetAttribute("PathNextDist") or math.huge
	return pathIndex - nextDist * 0.001   -- weight: higher index wins, ties broken by proximity
end

local function findTargetByMode(
	pos: Vector3,
	range: number,
	mode: string,
	folder: Folder?
): Model?
	local enemies = getEnemiesInRange(pos, range, folder)
	if #enemies == 0 then return nil end

	if mode == "First" then
		local best, bestScore = nil, -math.huge
		for _, e in ipairs(enemies) do
			local s = getProgressScore(e)
			if s > bestScore then bestScore = s; best = e end
		end
		return best

	elseif mode == "Last" then
		local best, bestScore = nil, math.huge
		for _, e in ipairs(enemies) do
			local s = getProgressScore(e)
			if s < bestScore then bestScore = s; best = e end
		end
		return best

	elseif mode == "Strongest" then
		local best, bestHP = nil, -math.huge
		for _, e in ipairs(enemies) do
			local hp = e:GetAttribute("HP") or 0
			if hp > bestHP then bestHP = hp; best = e end
		end
		return best

	elseif mode == "Weakest" then
		local best, bestHP = nil, math.huge
		for _, e in ipairs(enemies) do
			local hp = e:GetAttribute("HP") or 0
			if hp < bestHP then bestHP = hp; best = e end
		end
		return best

	elseif mode == "Random" then
		return enemies[math.random(1, #enemies)]

	else
		-- Default: "First"
		local best, bestScore = nil, -math.huge
		for _, e in ipairs(enemies) do
			local s = getProgressScore(e)
			if s > bestScore then bestScore = s; best = e end
		end
		return best
	end
end

local function findNearestEnemy(pos: Vector3, range: number, searchFolder: Folder?): Model?
	return findTargetByMode(pos, range, "First", searchFolder)
end

local function findTarget(tower: Model): Model?
	local torso = tower.PrimaryPart
	if not torso then return nil end
	local range = tower:GetAttribute("RNG") or 8
	local pos   = torso.Position
	local mode  = tower:GetAttribute("TargetMode") or "First"

	local aggroed = aggroMap[tower]
	if aggroed and aggroed.Parent and aggroed.PrimaryPart then
		if (aggroed:GetAttribute("HP") or 0) > 0
			and (aggroed.PrimaryPart.Position - pos).Magnitude <= range
		then
			return aggroed
		end
	end

	return findTargetByMode(pos, range, mode)
end

local function isTowerInAttackRange(tower: Model, enemy: Model): boolean
	local torso = tower.PrimaryPart
	if not torso or not enemy.PrimaryPart then return false end
	return (enemy.PrimaryPart.Position - torso.Position).Magnitude
		<= (tower:GetAttribute("RNG") or 8)
end

-- ============================================================
-- HEADHUNTER TARGET HELPER
-- Finds the highest-MaxHP enemy in range (mirrors Deadeye.DoAttack logic).
-- ============================================================

local function findHeadhunterTarget(tower: Model, fallback: Model): Model
	local torso = tower.PrimaryPart
	if not torso then return fallback end
	local range   = tower:GetAttribute("RNG") or 22
	local best    = fallback
	local bestMax = -math.huge
	for _, e in ipairs(enemiesFolder:GetChildren()) do
		if e:IsA("Model") and e.PrimaryPart and (e:GetAttribute("HP") or 0) > 0 then
			local d  = (e.PrimaryPart.Position - torso.Position).Magnitude
			local mx = e:GetAttribute("MaxHP") or e:GetAttribute("HP") or 0
			if d <= range and mx > bestMax then
				bestMax = mx
				best    = e
			end
		end
	end
	return best
end

-- Per-tower locked Headhunter aim target.
-- Cleared as soon as the shot fires or the tower loses its target.
local hhLockedTarget = {}   -- tower -> Model

-- ============================================================
-- VITALIST ALLY-HEAL TARGET HELPER
-- Finds the nearest ally tower (lowest HP ratio) in range.
-- ============================================================

local function findAllyToHeal(tower: Model): Model?
	local torso = tower.PrimaryPart
	if not torso then return nil end
	local pos   = torso.Position
	local range = tower:GetAttribute("RNG") or 20
	local best, bestRatio = nil, math.huge
	for _, t in ipairs(towersFolder:GetChildren()) do
		if t:IsA("Model") and t ~= tower and t.PrimaryPart then
			local hp    = t:GetAttribute("HP")    or 0
			local maxHP = t:GetAttribute("MaxHP") or 1
			local d     = (t.PrimaryPart.Position - pos).Magnitude
			if d <= range and hp > 0 then
				local ratio = hp / maxHP
				if ratio < bestRatio then
					bestRatio = ratio
					best      = t
				end
			end
		end
	end
	return best
end

-- ============================================================
-- CIRCLE POSITION HELPER
-- ============================================================

local function updateCirclePositions(tower: Model, pos: Vector3)
	local circle = tower:FindFirstChild("RangeCircle")
	if circle and circle.Parent then
		circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
	local leapCircle = tower:FindFirstChild("LeapRangeCircle")
	if leapCircle and leapCircle.Parent then
		leapCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
	local moveCircle = tower:FindFirstChild("MoveRangeCircle")
	if moveCircle and moveCircle.Parent then
		moveCircle.CFrame = CFrame.new(pos.X, pos.Y - 2.6, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
end

-- ============================================================
-- TOWER MOVEMENT + RELENTLESS ADVANCE
-- ============================================================

local TOWER_MOVE_COOLDOWN = 3  -- seconds after a tower moves before it can move again
local MOVE_ARRIVE_TOLERANCE = 0.2 -- tighter threshold for snappier move completion
local MOVE_ROTATION_LERP_SPEED = 16 -- faster facing updates for more responsive movement
local moveIndicators  = {}  -- tower -> Part

local function createMoveIndicator(dest: Vector3): Part
	local ind        = Instance.new("Part")
	ind.Name         = "MoveIndicator"
	ind.Shape        = Enum.PartType.Cylinder
	ind.Size         = Vector3.new(0.1, 3, 3)
	ind.Color        = Color3.fromRGB(80, 180, 255)
	ind.Material     = Enum.Material.Neon
	ind.Transparency = 0.4
	ind.Anchored     = true
	ind.CanCollide   = false
	ind.CFrame       = CFrame.new(dest.X, dest.Y - 3.3, dest.Z) * CFrame.Angles(0, 0, math.rad(90))
	ind.Parent       = Workspace
	return ind
end

local function destroyMoveIndicator(tower: Model)
	local ind = moveIndicators[tower]
	if ind and ind.Parent then ind:Destroy() end
	moveIndicators[tower] = nil
end

local function moveTower(tower: Model, dest: Vector3)
	local torso = tower.PrimaryPart
	if not torso then return end

	if activeMovements[tower] then
		activeMovements[tower]:Disconnect()
		activeMovements[tower] = nil
	end
	destroyMoveIndicator(tower)
	releaseAggro(tower)

	-- Clear any locked HH target when the tower moves
	hhLockedTarget[tower] = nil

	local startPos  = torso.Position
	local range     = tower:GetAttribute("RNG") or 8
	local flatDist  = (Vector3.new(dest.X, 0, dest.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude
	local towerType = tower:GetAttribute("TowerType") or "Warrior"

	if towerType == "Warrior"
		and flatDist <= range * Warrior.LEAP_RANGE_MULT
		and Warrior.IsLeapSlashReady(tower)
	then
		Warrior.StopWalk(tower)
		tower:SetAttribute("State", "Leaping")
		Warrior.PlayLeapAnimation(tower, dest, function()
			tower:SetAttribute("State", "Idle")
			if torso and torso.Parent then
				updateCirclePositions(tower, torso.Position)
			end
		end, findNearestEnemy, enemiesFolder)
		return
	end

	-- Vitalist: if destination is within protocol-switch range, toggle protocol
	if towerType == "Vitalist" and flatDist <= Vitalist.PROTOCOL_SWITCH_RANGE then
		task.spawn(function() Vitalist.TriggerProtocolSwitch(tower) end)
	end

	local mod = getTowerModule(tower)
	tower:SetAttribute("State", "Moving")
	tower:SetAttribute("MoveCooldownEnd", tick() + TOWER_MOVE_COOLDOWN)
	tower:SetAttribute("MoveCooldownMax", TOWER_MOVE_COOLDOWN)
	mod.StartWalk(tower)
	moveIndicators[tower] = createMoveIndicator(dest)

	local speed = tower:GetAttribute("MOVE_SPD") or 16
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if not torso or not torso.Parent then
			conn:Disconnect(); activeMovements[tower] = nil
			destroyMoveIndicator(tower); return
		end

		local cur  = torso.Position
		local flat = Vector3.new(dest.X - cur.X, 0, dest.Z - cur.Z)
		local dist = flat.Magnitude

		if dist < MOVE_ARRIVE_TOLERANCE then
			conn:Disconnect(); activeMovements[tower] = nil
			tower:SetAttribute("State", "Idle")
			mod.StopWalk(tower)
			destroyMoveIndicator(tower)
			updateCirclePositions(tower, cur)
			return
		end

		local moveDir = flat.Unit
		local step    = moveDir * speed * dt
		if step.Magnitude > dist then step = moveDir * dist end
		local newPos = cur + step

		local tCF    = CFrame.new(newPos, newPos + moveDir)
		local curRot = torso.CFrame - torso.CFrame.Position
		local tRot   = tCF - tCF.Position
		torso.CFrame = curRot:Lerp(tRot, math.clamp(dt * MOVE_ROTATION_LERP_SPEED, 0, 1)) + newPos

		updateCirclePositions(tower, newPos)
	end)
	activeMovements[tower] = conn
end

-- ============================================================
-- ON PLACEMENT
-- ============================================================

local function onTowerPlaced(tower: Model)
	if (tower:GetAttribute("TowerType") or "Warrior") ~= "Warrior" then return end
	local torso = tower.PrimaryPart
	if not torso then return end
	local range   = tower:GetAttribute("RNG") or 8
	local nearest = findNearestEnemy(torso.Position, range)
	if nearest and nearest.PrimaryPart then
		Warrior.PerformLeapingSlash(tower, nearest.PrimaryPart.Position, enemiesFolder, Warrior.StartLeapSlashCooldown)
	end
end

-- ============================================================
-- DYNAMITE EXPLOSION HELPER
-- ============================================================

local function triggerDynamiteExplosion(tower: Model, dynamiteModel: Model)
	local torso = tower.PrimaryPart
	if not torso then return end

	local atk = tower:GetAttribute("ATK") or 12
	local ap  = tower:GetAttribute("AP")  or 15
	local multi = tower:GetAttribute("DamageMulti") or 1.0

	local aoeDamage = atk * multi * 0.6
	local burnDPS   = ap  * multi * 0.2
	local explodePos = dynamiteModel.PrimaryPart and dynamiteModel.PrimaryPart.Position or torso.Position

	Deadeye.SpawnExplosionVFX(explodePos)

	local radius = Deadeye.DYNAMITE_EXPLOSION_RADIUS
	local now    = tick()

	for _, enemy in ipairs(enemiesFolder:GetChildren()) do
		if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0 then
			local dist = (enemy.PrimaryPart.Position - explodePos).Magnitude
			if dist <= radius then
				-- AoE damage
				local dealt, newHP = applyDamageToModel(enemy, aoeDamage)
				damageIndicatorRemote:FireAllClients(enemy.PrimaryPart.Position, dealt, "Critical")
				-- Apply / refresh burn
				burnMap[enemy] = {
					burnUntil = now + Deadeye.DYNAMITE_BURN_DURATION,
					burnDPS   = burnDPS,
					lastTick  = now,
				}
				if newHP <= 0 then
					burnMap[enemy] = nil
				end
			end
		end
	end
end

local function setNumericAttribute(model: Model, attrName: string, value: number)
	if value ~= value then value = 0 end
	model:SetAttribute(attrName, value)
end

local function applyStatDelta(model: Model, statName: string, delta: number)
	local current = tonumber(model:GetAttribute(statName)) or 0
	local nextVal = current + delta
	if statName == "ATK_SPD" then
		nextVal = math.max(0.2, nextVal)
	elseif statName == "HP" then
		nextVal = math.max(1, nextVal)
	elseif statName == "MaxHP" then
		nextVal = math.max(1, nextVal)
	else
		nextVal = math.max(0, nextVal)
	end
	setNumericAttribute(model, statName, nextVal)
end

local function refreshEquipmentDerivedStats(tower: Model)
	local baseAtk = tonumber(tower:GetAttribute("BaseATK")) or tonumber(tower:GetAttribute("ATK")) or 0
	local baseAtkSpd = tonumber(tower:GetAttribute("BaseATK_SPD")) or tonumber(tower:GetAttribute("ATK_SPD")) or 1

	local condAtkAdd = tonumber(tower:GetAttribute("EqCondAtkAdd")) or 0
	local condAtkThreshold = tonumber(tower:GetAttribute("EqCondAtkThreshold")) or 0
	local hp = tonumber(tower:GetAttribute("HP")) or 0
	local maxHP = tonumber(tower:GetAttribute("MaxHP")) or 1
	local hpRatio = maxHP > 0 and (hp / maxHP) or 0
	local atk = baseAtk + ((hpRatio >= condAtkThreshold) and condAtkAdd or 0)

	local moveAtkSpdDelta = tonumber(tower:GetAttribute("EqMoveAtkSpdDelta")) or 0
	local moveBuffUntil = tonumber(tower:GetAttribute("EqMoveBuffUntil")) or 0
	local atkSpd = baseAtkSpd + ((tick() <= moveBuffUntil) and moveAtkSpdDelta or 0)

	setNumericAttribute(tower, "ATK", math.max(0, atk))
	setNumericAttribute(tower, "ATK_SPD", math.max(0.2, atkSpd))
end

local function applyEquipmentToTower(player: Player, towerModel: Model, towerType: string)
	local equippedKeys = CurrencyManager.GetEquippedForTower(player, towerType)
	local appliedNames = {}

	setNumericAttribute(towerModel, "EqCondAtkAdd", 0)
	setNumericAttribute(towerModel, "EqCondAtkThreshold", 0)
	setNumericAttribute(towerModel, "EqMoveAtkSpdDelta", 0)
	setNumericAttribute(towerModel, "EqMoveBuffDuration", 0)
	setNumericAttribute(towerModel, "EqMoveBuffUntil", 0)

	for _, eqKey in ipairs(equippedKeys) do
		local eqData = TowerData.Equipment[eqKey]
		if eqData then
			table.insert(appliedNames, eqKey)
			for _, effect in ipairs(eqData.effects or {}) do
				if effect.trigger == "OnMove" and effect.stat == "ATK_SPD" then
					setNumericAttribute(towerModel, "EqMoveAtkSpdDelta", tonumber(effect.add) or 0)
					setNumericAttribute(towerModel, "EqMoveBuffDuration", tonumber(effect.duration) or 0)
				elseif effect.condition == "AboveHpPercent" and effect.stat == "ATK" then
					setNumericAttribute(towerModel, "EqCondAtkAdd", tonumber(effect.add) or 0)
					setNumericAttribute(towerModel, "EqCondAtkThreshold", tonumber(effect.threshold) or 0.5)
				elseif effect.stat and effect.add then
					applyStatDelta(towerModel, effect.stat, tonumber(effect.add) or 0)
					if effect.stat == "HP" then
						local maxHP = tonumber(towerModel:GetAttribute("MaxHP")) or 1
						local hp = tonumber(towerModel:GetAttribute("HP")) or maxHP
						setNumericAttribute(towerModel, "HP", math.min(hp, maxHP))
					end
				end
			end
		end
	end

	setNumericAttribute(towerModel, "BaseATK", tonumber(towerModel:GetAttribute("ATK")) or 0)
	setNumericAttribute(towerModel, "BaseATK_SPD", tonumber(towerModel:GetAttribute("ATK_SPD")) or 1)
	towerModel:SetAttribute("EquipmentKeys", table.concat(appliedNames, ","))
	refreshEquipmentDerivedStats(towerModel)
end

local function triggerMoveEquipmentBuff(towerModel: Model)
	local delta = tonumber(towerModel:GetAttribute("EqMoveAtkSpdDelta")) or 0
	local duration = tonumber(towerModel:GetAttribute("EqMoveBuffDuration")) or 0
	if delta == 0 or duration <= 0 then return end
	setNumericAttribute(towerModel, "EqMoveBuffUntil", tick() + duration)
	refreshEquipmentDerivedStats(towerModel)
end

-- ============================================================
-- TOWER AI LOOP + SURVIVOR PASSIVE
-- ============================================================

local activeTowers = {}  -- tower -> { lastAttackTime }

local function registerTower(towerModel: Model)
	local mod = getTowerModule(towerModel)
	mod.StoreBaseC0s(towerModel)
	local tt = towerModel:GetAttribute("TowerType")
	if tt == "Deadeye" then
		Deadeye.InitTower(towerModel)
	elseif tt == "Vitalist" then
		Vitalist.InitTower(towerModel)
	elseif tt == "Wanderer" then
		Wanderer.InitTower(towerModel)
	elseif tt == "Pathfinder" then
		Pathfinder.InitTower(towerModel)
	end
	activeTowers[towerModel] = { lastAttackTime = 0 }
end

RunService.Heartbeat:Connect(function()
	local now = tick()

	-- === TOWER COMBAT ===
	for tower, data in pairs(activeTowers) do
		if not tower or not tower.Parent then
			activeTowers[tower] = nil
			hhLockedTarget[tower] = nil
			releaseAggro(tower)
			continue
		end

		local state     = tower:GetAttribute("State")     or "Idle"
		local towerType = tower:GetAttribute("TowerType") or "Warrior"
		refreshEquipmentDerivedStats(tower)

		-- ── Warrior: Survivor passive ──
		if towerType == "Warrior" then
			local hp           = tower:GetAttribute("HP")             or 0
			local maxHp        = tower:GetAttribute("MaxHP")          or 1
			local lastCombat   = tower:GetAttribute("LastCombatTime") or now
			local lastHealTick = tower:GetAttribute("LastHealTick")   or 0

			if hp > 0 and hp < maxHp and (now - lastCombat) >= Warrior.SURVIVOR_OOC_TIME then
				if (now - lastHealTick) >= Warrior.SURVIVOR_HEAL_INTERVAL then
					local heal = math.ceil(maxHp * Warrior.SURVIVOR_HEAL_PERCENT)
					tower:SetAttribute("HP",           math.min(hp + heal, maxHp))
					tower:SetAttribute("LastHealTick", now)
					Warrior.SpawnHealParticles(tower)
				end
			end
		end

		if state == "Moving" or state == "Leaping" then continue end

		-- Validate / drop stale aggro
		local curAggro = aggroMap[tower]
		if curAggro then
			if not curAggro.Parent or (curAggro:GetAttribute("HP") or 0) <= 0 then
				releaseAggro(tower); curAggro = nil
			elseif not isTowerInAttackRange(tower, curAggro) then
				releaseAggro(tower); curAggro = nil
			end
		end

		-- Find nearest target in range
		local target = findTarget(tower)

		-- ══════════════════════════════════════════════════════
		-- VITALIST combat branch (handles both SUPP and ATK)
		-- Vitalist in SUPP mode doesn't need an enemy target.
		-- ══════════════════════════════════════════════════════
		if towerType == "Vitalist" then
			local protocol = tower:GetAttribute("Protocol") or "ATK"
			local atkSpd   = math.max(1, math.floor((tower:GetAttribute("ATK_SPD") or 1) + 0.5))

			if protocol == "SUPP" then
				-- SUPP mode: heal the nearest injured ally tower
				local healTarget = findAllyToHeal(tower)
				if healTarget then
					Vitalist.UpdateCombatState(tower, true, healTarget)
					if Vitalist.IsReadyToFire(tower)
						and (now - data.lastAttackTime) >= atkSpd
					then
						tower:SetAttribute("State", "Attacking")
						data.lastAttackTime = now
						Vitalist.DoAttack(tower, healTarget, enemiesFolder, towersFolder)
					end
				else
					Vitalist.UpdateCombatState(tower, false, nil)
					tower:SetAttribute("State", "Idle")
				end
				continue
			else
				-- ATK mode: attack the nearest enemy
				if not target then
					Vitalist.UpdateCombatState(tower, false, nil)
					tower:SetAttribute("State", "Idle")
					continue
				end

				Vitalist.UpdateCombatState(tower, true, target)
				if Vitalist.IsReadyToFire(tower)
					and (now - data.lastAttackTime) >= atkSpd
				then
					tower:SetAttribute("State", "Attacking")
					data.lastAttackTime = now
					Vitalist.DoAttack(tower, target, enemiesFolder, towersFolder)
				end
				continue
			end
		end

		-- ══════════════════════════════════════════════════════
		-- WANDERER combat branch
		-- Uses the Drone's position for targeting.  All logic is
		-- self-contained so the shared `target` variable is not used.
		-- ══════════════════════════════════════════════════════
		if towerType == "Wanderer" then
			-- Tick passive systems
			Wanderer.TickDroneRespawn(tower)
			Wanderer.TickReconnaissance(tower)
			Wanderer.TickSuppressingFire(tower, enemiesFolder, damageIndicatorRemote)

			local dronePos = Wanderer.GetDronePosition(tower)
			if not dronePos then
				-- Drone is respawning – idle animation
				Wanderer.UpdateCombatState(tower, false, nil)
				tower:SetAttribute("State", "Idle")
				continue
			end

			-- Find nearest enemy using the Drone's position
			local rng             = tower:GetAttribute("RNG")     or 60
			local wandererAtkSpd  = math.max(1, math.floor((tower:GetAttribute("ATK_SPD") or 2) + 0.5))
			local droneTarget     = findNearestEnemy(dronePos, rng)

			if not droneTarget then
				Wanderer.UpdateCombatState(tower, false, nil)
				tower:SetAttribute("State", "Idle")
				continue
			end

			Wanderer.UpdateCombatState(tower, true, droneTarget)

			if not Wanderer.IsReadyToFire(tower) then continue end
			if now - data.lastAttackTime < wandererAtkSpd then continue end

			tower:SetAttribute("State", "Attacking")
			data.lastAttackTime = now
			Wanderer.DoAttack(tower, droneTarget, enemiesFolder)
			continue
		end

		-- ══════════════════════════════════════════════════════
		-- PATHFINDER combat branch  (no normal attacks)
		-- ══════════════════════════════════════════════════════
		if towerType == "Pathfinder" then
			Pathfinder.TickSouls(tower, enemiesFolder)
			Pathfinder.TickReclamation(tower, enemiesFolder)
			Pathfinder.UpdateCombatState(tower, false, nil)
			continue
		end

		if not target then
			-- No target: clear locked HH target, hide aim laser, and tick Deadeye animation
			if towerType == "Deadeye" then
				-- Exception: if Deadeye has a dynamite placed and in range, auto-fire it.
				-- No enhancement required here — the player chose to deploy dynamite.
				local dynaTemp = Deadeye.GetDynamite(tower)
				local torsoT   = tower.PrimaryPart
				if dynaTemp and torsoT then
					local dynRange = tower:GetAttribute("RNG") or 30
					if (dynaTemp.PrimaryPart.Position - torsoT.Position).Magnitude > dynRange then
						dynaTemp = nil
					end
				end

				if dynaTemp then
					-- Drive toward the dynamite instead of idling
					local atkSpd2 = math.max(1, math.floor((tower:GetAttribute("ATK_SPD") or 1) + 0.5))
					hhLockedTarget[tower] = dynaTemp
					Deadeye.UpdateCombatState(tower, true, dynaTemp)
					if Deadeye.IsReadyToFire(tower) and (now - data.lastAttackTime) >= atkSpd2 then
						if Deadeye.TickHeadhunterAim(tower, dynaTemp) then
							hhLockedTarget[tower] = nil
							tower:SetAttribute("State", "Attacking")
							data.lastAttackTime = now
							Deadeye.DoAttackDynamite(tower, dynaTemp)
							triggerDynamiteExplosion(tower, dynaTemp)
							Deadeye.RemoveDynamite(tower)
						end
					end
				else
					hhLockedTarget[tower] = nil
					Deadeye.HideAimLaser(tower)
					Deadeye.UpdateCombatState(tower, false, nil)
				end
			end
			tower:SetAttribute("State", "Idle")
			continue
		end

		-- Establish aggro
		if not curAggro then
			local torso      = tower.PrimaryPart
			local enemyTorso = target.PrimaryPart
			if torso and enemyTorso then
				local dist       = (torso.Position - enemyTorso.Position).Magnitude
				local enemyRange = target:GetAttribute("RangeStuds") or target:GetAttribute("RNG") or 5
				if dist <= enemyRange then
					setAggro(tower, target)
				end
			end
		end

		local atkSpd = math.max(1, math.floor((tower:GetAttribute("ATK_SPD") or 1) + 0.5))

		-- ══════════════════════════════════════════════════════
		-- DEADEYE combat branch
		-- ══════════════════════════════════════════════════════
		if towerType == "Deadeye" then

			local count      = tower:GetAttribute("BasicAttackCount") or 0
			local isEnhanced = count >= Deadeye.ENHANCE_AFTER

			if isEnhanced then
				local torso2 = tower.PrimaryPart
				local range  = tower:GetAttribute("RNG") or 30

				-- Strike Skill: Dynamite takes priority over normal Headhunter targets.
				local dynamite = Deadeye.GetDynamite(tower)
				if dynamite and dynamite.Parent and dynamite.PrimaryPart and torso2 then
					local dynDist = (dynamite.PrimaryPart.Position - torso2.Position).Magnitude
					if dynDist <= range then
						hhLockedTarget[tower] = dynamite
					end
				end

				-- Lock onto the Headhunter target once and keep it until the shot fires.
				-- Re-evaluate only if the locked target is dead/gone.
				local locked = hhLockedTarget[tower]
				if not locked or not locked.Parent or
					(not locked:GetAttribute("IsDynamite") and (locked:GetAttribute("HP") or 0) <= 0)
				then
					locked = findHeadhunterTarget(tower, target)
					hhLockedTarget[tower] = locked
				end

				-- Drive the animation state machine toward the LOCKED target so the
				-- gun raises and faces the correct enemy during the full aim window.
				Deadeye.UpdateCombatState(tower, true, locked)

				-- Wait for the gun to finish raising before we start the aim timer.
				if not Deadeye.IsReadyToFire(tower) then continue end

				-- Cooldown between shots still applies.
				if now - data.lastAttackTime < atkSpd then continue end

				-- Show crosshair/laser and block until aim delay has elapsed.
				if not Deadeye.TickHeadhunterAim(tower, locked) then
					continue  -- still aiming
				end

				-- Aim delay elapsed — fire!
				local firedAtDynamite = locked and locked:GetAttribute("IsDynamite")
				hhLockedTarget[tower] = nil
				tower:SetAttribute("State", "Attacking")
				data.lastAttackTime = now

				if firedAtDynamite then
					-- Shoot the dynamite → explosion
					Deadeye.DoAttackDynamite(tower, locked)
					triggerDynamiteExplosion(tower, locked)
					Deadeye.RemoveDynamite(tower)
				else
					Deadeye.DoAttack(tower, locked, enemiesFolder)
				end

			else
				-- Normal Revolver shot — no aim VFX, no extra delay.
				Deadeye.UpdateCombatState(tower, true, target)

				if not Deadeye.IsReadyToFire(tower) then continue end
				if now - data.lastAttackTime < atkSpd then continue end

				tower:SetAttribute("State", "Attacking")
				data.lastAttackTime = now
				Deadeye.DoAttack(tower, target, enemiesFolder)
			end

			-- ══════════════════════════════════════════════════════
			-- WARRIOR combat branch
			-- ══════════════════════════════════════════════════════
		else
			if now - data.lastAttackTime < atkSpd then continue end

			tower:SetAttribute("State",          "Attacking")
			tower:SetAttribute("LastCombatTime", now)
			data.lastAttackTime = now

			local atk    = tower:GetAttribute("ATK") or 10
			local multi  = tower:GetAttribute("DamageMulti") or 1.0
			local damage = atk * multi

			local dealt, newHP = applyDamageToModel(target, damage)
			Warrior.PlayAttackAnimation(tower, target)

			-- After: target:SetAttribute("HP", enemyHP - damage)
			damageIndicatorRemote:FireAllClients(
				target.PrimaryPart.Position,
				dealt,
				"Normal"
			)

			if target.PrimaryPart then
				Warrior.SpawnHitParticles(target.PrimaryPart.Position, Color3.fromRGB(255, 80, 80))
			end

		end
		
		
	end

	-- === SCAN FOR NEW AGGRO ===
	for tower, _ in pairs(activeTowers) do
		if not tower or not tower.Parent then continue end
		if tower:GetAttribute("Ghosted") == true then continue end  -- Pathfinder passive
		local towerState = tower:GetAttribute("State") or "Idle"
		if towerState == "Moving" or towerState == "Leaping" then continue end

		local torso = tower.PrimaryPart
		if not torso or aggroMap[tower] then continue end

		for _, enemy in ipairs(enemiesFolder:GetChildren()) do
			if enemy:IsA("Model") and enemy.PrimaryPart and (enemy:GetAttribute("HP") or 0) > 0
				and not enemyAggroBy[enemy]
			then
				local dist       = (torso.Position - enemy.PrimaryPart.Position).Magnitude
				local enemyRange = enemy:GetAttribute("RangeStuds") or enemy:GetAttribute("RNG") or 5
				local towerRange = tower:GetAttribute("RNG") or 8
				if dist <= towerRange and dist <= enemyRange then
					setAggro(tower, enemy)
					break
				end
			end
		end
	end

	-- === AGGROED ENEMIES ATTACK TOWERS ===
	for enemy, tower in pairs(enemyAggroBy) do
		if not enemy or not enemy.Parent then continue end
		if not tower or not tower.Parent then
			enemyAggroBy[enemy] = nil
			if enemy and enemy.Parent then
				enemy:SetAttribute("Aggroed",     false)
				enemy:SetAttribute("AggroTarget", "")
				enemy:SetAttribute("WalkStopped", false)
			end
			continue
		end
		-- Release aggro on ghosted towers (Pathfinder passive)
		if tower:GetAttribute("Ghosted") == true then
			releaseAggro(tower)
			continue
		end
		if (enemy:GetAttribute("HP") or 0) <= 0 then continue end

		local er = enemy.PrimaryPart
		local tr = tower.PrimaryPart
		if not er or not tr then continue end

		local dist       = (tr.Position - er.Position).Magnitude
		local enemyRange = enemy:GetAttribute("RangeStuds") or enemy:GetAttribute("RNG") or 5

		if dist <= enemyRange then
			local dir = Vector3.new(tr.Position.X - er.Position.X, 0, tr.Position.Z - er.Position.Z)
			if dir.Magnitude > 0.1 then
				er.CFrame = CFrame.new(er.Position, er.Position + dir.Unit)
			end
			local mod = getTowerModule(tower)
			BasicZombie.AttackTower(enemy, tower, playEnemyPunchRemote, mod.SpawnHitParticles)
		else
			releaseAggro(tower)
		end
	end

	-- === BURN DAMAGE TICK (from Dynamite fire) ===
	for enemy, burnData in pairs(burnMap) do
		if not enemy or not enemy.Parent or (enemy:GetAttribute("HP") or 0) <= 0 then
			burnMap[enemy] = nil
			continue
		end
		if now >= burnData.burnUntil then
			burnMap[enemy] = nil
			continue
		end
		if (now - burnData.lastTick) >= 1.0 then
			local dealt, newHP = applyDamageToModel(enemy, burnData.burnDPS)
			burnData.lastTick = now
			damageIndicatorRemote:FireAllClients(enemy.PrimaryPart and enemy.PrimaryPart.Position or Vector3.zero, dealt, "Normal")
			if newHP <= 0 then
				burnMap[enemy] = nil
			end
		end
	end
end)

-- ============================================================
-- CLEANUP: enemy removed
-- ============================================================

enemiesFolder.ChildRemoved:Connect(function(enemy)
	local tower = enemyAggroBy[enemy]
	if tower then
		aggroMap[tower]     = nil
		enemyAggroBy[enemy] = nil
		-- If this enemy was a locked HH target, clear it so a new one is picked next frame
		if hhLockedTarget[tower] == enemy then
			hhLockedTarget[tower] = nil
		end
	end
	BasicZombie.CleanupEnemy(enemy)
	if activePushes[enemy] then
		activePushes[enemy]:Disconnect()
		activePushes[enemy] = nil
	end
	burnMap[enemy] = nil
end)

-- ============================================================
-- REMOTES
-- ============================================================

placeRemote.OnServerEvent:Connect(function(player: Player, templateName: string, position: Vector3)
	if typeof(position)   ~= "Vector3" then return end
	if type(templateName) ~= "string"  then return end
	if not TowerStats.Templates[templateName] then return end

	local profile = CurrencyManager.GetData(player)
	if not profile.unlocked[templateName] then
		return
	end
	local isInLoadout = table.find(profile.loadout or {}, templateName) ~= nil
	if not isInLoadout then
		return
	end

	local towerModel
	if templateName == "Deadeye" then
		towerModel = Deadeye.CreateModel(position, TowerStats)
	elseif templateName == "Vitalist" then
		towerModel = Vitalist.CreateModel(position, TowerStats)
	elseif templateName == "Wanderer" then
		towerModel = Wanderer.CreateModel(position, TowerStats)
	elseif templateName == "Pathfinder" then
		towerModel = Pathfinder.CreateModel(position, TowerStats)
	else
		towerModel = Warrior.CreateModel(position, TowerStats, Warrior.LEAP_RANGE_MULT, Warrior.LEAP_SLASH_COOLDOWN)
	end

	if towerModel then
		towerModel.Parent = towersFolder
		towerModel:SetAttribute("Owner", player.Name)
		applyEquipmentToTower(player, towerModel, templateName)
		registerTower(towerModel)
		onTowerPlaced(towerModel)
	end
end)

moveRemote.OnServerEvent:Connect(function(player: Player, tower: Model, dest: Vector3)
	if typeof(dest) ~= "Vector3"  then return end
	if not tower or not tower:IsA("Model") then return end
	if tower.Parent ~= towersFolder then return end
	if (tower:GetAttribute("Owner") or "") ~= player.Name then return end
	if (tower:GetAttribute("State") or "Idle") == "Leaping" then return end

	local towerType = tower:GetAttribute("TowerType")
	triggerMoveEquipmentBuff(tower)
	if towerType == "Wanderer" then
		-- For Wanderer: move the Drone, not the tower itself
		Wanderer.MoveDrone(tower, dest)
	elseif towerType == "Pathfinder" then
		-- Pathfinder handles its own move (dash + ghost + waypoints)
		Pathfinder.HandleMove(tower, dest, function(t, pos)
			local circle = t:FindFirstChild("RangeCircle")
			if circle then
				circle.CFrame = CFrame.new(pos.X, pos.Y - 2.5, pos.Z)
					* CFrame.Angles(0, 0, math.rad(90))
			end
		end)
	else
		moveTower(tower, dest)
	end
end)

-- ============================================================
-- STRIKE SKILL REMOTE
-- ============================================================

local DYNAMITE_RANGE_TOLERANCE = 0.5   -- studs of extra leeway for server-side range check
local DYNAMITE_GROUND_OFFSET   = -2.3  -- Y offset from torso to place dynamite on the ground

strikeSkillRemote.OnServerEvent:Connect(function(player: Player, tower: Model, skillName: string, position)
	if type(skillName) ~= "string"           then return end
	if not tower or not tower:IsA("Model")   then return end
	if tower.Parent ~= towersFolder          then return end
	if (tower:GetAttribute("Owner") or "") ~= player.Name then return end

	local towerType = tower:GetAttribute("TowerType")

	if skillName == "Dynamite" and towerType == "Deadeye" then
		if typeof(position) ~= "Vector3" then return end
		local torso = tower.PrimaryPart
		if not torso then return end
		local flatDist = Vector3.new(position.X - torso.Position.X, 0, position.Z - torso.Position.Z).Magnitude
		if flatDist > Deadeye.DYNAMITE_RANGE + DYNAMITE_RANGE_TOLERANCE then return end
		-- Snap dynamite Y to ground level near the tower base
		local snapPos = Vector3.new(position.X, torso.Position.Y + DYNAMITE_GROUND_OFFSET, position.Z)
		Deadeye.PlaceDynamite(tower, snapPos)

	elseif skillName == "NanoBlast" and towerType == "Vitalist" then
		if not Vitalist.IsNanoBlastReady(tower) then return end
		-- Charge gate: only fire when fully charged
		if (tower:GetAttribute("Charge") or 0) < Vitalist.MAX_CHARGE then return end
		local inputDirection = typeof(position) == "Vector3" and position or nil
		local flatDir: Vector3 = Vector3.new(0, 0, 1)
		if inputDirection then
			local d = Vector3.new(inputDirection.X, 0, inputDirection.Z)
			if d.Magnitude >= 0.5 then
				flatDir = d.Unit
			end
		end
		Vitalist.FireNanoBlast(tower, flatDir, enemiesFolder, towersFolder)

	elseif skillName == "Reconnaissance" and towerType == "Wanderer" then
		if not Wanderer.IsReconReady(tower) then return end
		Wanderer.ActivateReconnaissance(tower)

	elseif skillName == "Soulbind" and towerType == "Pathfinder" then
		if typeof(position) ~= "Vector3" then return end
		if not Pathfinder.IsSoulbindReady(tower) then return end
		Pathfinder.FireSoulbind(tower, position, enemiesFolder, damageIndicatorRemote)
	end
end)

towersFolder.ChildRemoved:Connect(function(child)
	activeTowers[child]   = nil
	hhLockedTarget[child] = nil
	getTowerModule(child).CleanupTower(child)
	releaseAggro(child)
	if activeMovements[child] then
		activeMovements[child]:Disconnect()
		activeMovements[child] = nil
	end
	destroyMoveIndicator(child)
end)

-- ============================================================
-- SELL TOWER REMOTE
-- ============================================================

sellTowerRemote.OnServerEvent:Connect(function(player: Player, tower: Model)
	if not tower or not tower:IsA("Model")   then return end
	if tower.Parent ~= towersFolder          then return end
	if (tower:GetAttribute("Owner") or "") ~= player.Name then return end
	local state = tower:GetAttribute("State") or "Idle"
	if state == "Leaping" or state == "Moving" then return end

	-- Reward sell value
	local towerType = tower:GetAttribute("TowerType") or "Warrior"
	local sellValues = {
		Warrior  = 130,
		Deadeye  = 165,
		Vitalist = 155,
		Wanderer = 250,
	}
	local coinsObj = ReplicatedStorage:FindFirstChild("Coins") or ReplicatedStorage:FindFirstChild("Gold")
	if coinsObj and coinsObj:IsA("ValueBase") then
		coinsObj.Value = (coinsObj.Value or 0) + (sellValues[towerType] or 0)
	end

	tower:Destroy()
end)

-- ============================================================
-- SET TARGET MODE REMOTE
-- ============================================================

setTargetModeRemote.OnServerEvent:Connect(function(player: Player, tower: Model, mode: string)
	if not tower or not tower:IsA("Model")   then return end
	if tower.Parent ~= towersFolder          then return end
	if (tower:GetAttribute("Owner") or "") ~= player.Name then return end
	local valid = { First = true, Last = true, Strongest = true, Weakest = true, Random = true }
	if not valid[mode] then return end
	tower:SetAttribute("TargetMode", mode)
end)
