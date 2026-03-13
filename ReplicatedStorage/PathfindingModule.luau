local PathfindingModule = {}

local RunService = game:GetService("RunService")


function PathfindingModule.BuildWaypoints(pathFolder: Folder): {Vector3}
	local raw = {}

	for _, part in ipairs(pathFolder:GetChildren()) do
		if part:IsA("BasePart") then
			local order = part:GetAttribute("PathOrder")
			if order then
				table.insert(raw, {
					Position = part.Position,
					Order    = order,
				})
			end
		end
	end

	table.sort(raw, function(a, b)
		return a.Order < b.Order
	end)

	local waypoints = {}
	for _, entry in ipairs(raw) do
		table.insert(waypoints, entry.Position)
	end

	return waypoints
end


function PathfindingModule.FindClosestWaypoint(waypoints: {Vector3}, position: Vector3): (number, number)
	local bestIndex = 1
	local bestDist  = math.huge

	for i, wp in ipairs(waypoints) do
		local dist = (wp - position).Magnitude
		if dist < bestDist then
			bestDist  = dist
			bestIndex = i
		end
	end

	return bestIndex, bestDist
end


function PathfindingModule.StartMoving(
	enemyModel: Model,
	waypoints: {Vector3},
	moveSpeed: number,
	onReachedEnd: () -> ()
): () -> ()

	local root: BasePart = enemyModel.PrimaryPart
	if not root then
		warn("[PathfindingModule] Enemy model has no PrimaryPart")
		return function() end
	end

	if #waypoints == 0 then
		warn("[PathfindingModule] No waypoints to follow")
		return function() end
	end

	local currentIndex = 1
	local running = true
	local ARRIVE_THRESHOLD = 0.5
	local TURN_SPEED = 8

	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		if not running then return end
		if not root or not root.Parent then
			running = false
			if connection then connection:Disconnect() end
			return
		end

		-- If aggroed, stop moving and face the tower
		local aggroed = enemyModel:GetAttribute("Aggroed")
		if aggroed then
			-- Don't move, just wait
			return
		end

		if currentIndex > #waypoints then
			running = false
			if connection then connection:Disconnect() end
			if onReachedEnd then onReachedEnd() end
			return
		end

		local targetPos = waypoints[currentIndex]
		local currentPos = root.Position

		local flatDir = Vector3.new(targetPos.X - currentPos.X, 0, targetPos.Z - currentPos.Z)
		local distance = flatDir.Magnitude

		if distance < ARRIVE_THRESHOLD then
			currentIndex = currentIndex + 1
			-- After incrementing, (currentIndex - 1) is the waypoint we just arrived at –
			-- store it as PathIndex so targeting can score enemies by path progress.
			local lastPassed = currentIndex - 1
			if lastPassed >= 1 then
				enemyModel:SetAttribute("PathIndex", lastPassed)
			end
			-- Distance to next waypoint (for tie-breaking in First/Last targeting)
			if currentIndex <= #waypoints then
				local nextWp  = waypoints[currentIndex]
				local nextFlat = Vector3.new(nextWp.X - currentPos.X, 0, nextWp.Z - currentPos.Z)
				enemyModel:SetAttribute("PathNextDist", nextFlat.Magnitude)
			end
			return
		end

		-- Update PathNextDist continuously (distance to next waypoint)
		enemyModel:SetAttribute("PathNextDist", distance)

		local moveDir = flatDir.Unit
		local step = moveDir * moveSpeed * dt

		if step.Magnitude > distance then
			step = moveDir * distance
		end

		local newPos = currentPos + step

		-- Smooth rotation
		local targetCFrame = CFrame.new(newPos, newPos + moveDir)
		local currentRot = root.CFrame - root.CFrame.Position
		local targetRot = targetCFrame - targetCFrame.Position
		local alpha = math.clamp(dt * TURN_SPEED, 0, 1)
		local smoothedRot = currentRot:Lerp(targetRot, alpha)

		root.CFrame = smoothedRot + newPos
	end)

	return function()
		running = false
		if connection then
			connection:Disconnect()
		end
	end
end

return PathfindingModule