return function()
	local SmartWander = {}
	local rs = game:GetService("ReplicatedStorage")
	local DoorOpener = require(rs.DoorOpener)

	local isWandering      = false
	local wanderGeneration  = 0
	local wanderCoroutine   = nil
	local lastWanderCheck   = os.clock()
	local wanderPathFailCount = 0
	local lastWanderDoorAttempt = 0
	local WANDER_DOOR_COOLDOWN = 2

	local defaultSettings = {
		WANDER_CHECK_INTERVAL = 3,
		DoorsFolder           = workspace:FindFirstChild("Doors"),
		BreaksDoors           = false,
		MinWanderWait         = 4,
		MaxWanderWait         = 10,
		MinWanderDistance     = 10,
		MaxWanderDistance     = 25,
		debugPrint            = function(...) print("[Wander]", ...) end,
	}

	-- ─────────────────────────────────────────────────────────────
	-- HELPERS
	-- ─────────────────────────────────────────────────────────────

	function SmartWander.faceRandomDirection(enemyChar)
		local humanoid = enemyChar:FindFirstChild("Humanoid")
		local hrp      = enemyChar:FindFirstChild("HumanoidRootPart")
		if not humanoid or not hrp then return end

		SmartWander.cleanupBodyGyro(enemyChar)

		local randomAngle = math.random() * math.pi * 2
		local lookVector  = Vector3.new(math.cos(randomAngle), 0, math.sin(randomAngle))

		local bodyGyro      = Instance.new("BodyGyro")
		bodyGyro.Name       = "WanderBodyGyro"
		bodyGyro.MaxTorque  = Vector3.new(4000, 4000, 4000)
		bodyGyro.P          = 1000
		bodyGyro.D          = 50
		bodyGyro.CFrame     = CFrame.new(hrp.Position, hrp.Position + lookVector)
		bodyGyro.Parent     = hrp

		return bodyGyro, randomAngle
	end

	function SmartWander.cleanupBodyGyro(enemyChar)
		if not enemyChar then return end
		local hrp = enemyChar:FindFirstChild("HumanoidRootPart")
		if hrp then
			local bodyGyro = hrp:FindFirstChild("WanderBodyGyro")
			if bodyGyro then bodyGyro:Destroy() end
		end
	end

	-- Raycasts from NPC toward a wander target position looking for a
	-- closed door in the way. If found, opens it via DoorOpener's
	-- Open.Value — the single authoritative place that sets it.
	-- Returns true if a door was found and opened (or was already open).
	local function tryOpenDoorTowardWanderTarget(enemyChar, targetPos, settings)
		local hrp = enemyChar:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end

		local now = os.clock()
		if now - lastWanderDoorAttempt < WANDER_DOOR_COOLDOWN then return false end

		local origin    = hrp.Position + Vector3.new(0, 1, 0)
		local direction = targetPos - origin

		local params = RaycastParams.new()
		params.FilterDescendantsInstances = { enemyChar }
		params.FilterType = Enum.RaycastFilterType.Exclude

		local result = workspace:Raycast(origin, direction, params)
		if not result then return false end

		-- Only consider geometry that is close to the NPC — a door
		-- the NPC would actually need to walk through should be nearby,
		-- not 20+ studs away across the map.
		local hitDist = (result.Position - hrp.Position).Magnitude
		if hitDist > 8 then
			if settings.debugPrint then
				settings.debugPrint(string.format(
					"[%s] Wander raycast hit '%s' but it's %.1f studs away — too far to be a blocking door, ignoring.",
					enemyChar.Name, result.Instance:GetFullName(), hitDist
					))
			end
			return false
		end

		if settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] Wander raycast hit '%s' at %.1f studs (ancestor check for door)",
				enemyChar.Name, result.Instance:GetFullName(), hitDist
				))
		end

		-- Walk up ancestry but stop at Workspace — never treat Workspace
		-- itself or its direct non-door children as a door
		local inst = result.Instance
		local depth = 0
		while inst and inst ~= workspace and depth < 5 do
			depth += 1

			-- Pattern 1: Open BoolValue directly on instance
			-- but only if the instance name suggests it's a door
			local openVal = inst:FindFirstChild("Open")
			if openVal and openVal:IsA("BoolValue") and openVal.Value == false then
				-- Extra safety: make sure the parent looks like a door model
				-- by checking the instance or its parent has "door" in the name
				local nameToCheck = string.lower(inst.Name .. (inst.Parent and inst.Parent.Name or ""))
				if string.find(nameToCheck, "door") then
					lastWanderDoorAttempt = now
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Wander door found (direct Open) on '%s' — opening.",
							enemyChar.Name, inst:GetFullName()
							))
					end
					openVal.Value = true
					return true
				end
			end

			-- Pattern 2: Door script child containing Open
			local doorScript = inst:FindFirstChild("Door")
			if doorScript then
				local openVal2 = doorScript:FindFirstChild("Open")
				if openVal2 and openVal2:IsA("BoolValue") and openVal2.Value == false then
					lastWanderDoorAttempt = now
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Wander door found (Door.Open) on '%s' — opening.",
							enemyChar.Name, inst:GetFullName()
							))
					end
					openVal2.Value = true
					return true
				end
			end

			inst = inst.Parent
		end

		return false
	end

	-- ─────────────────────────────────────────────────────────────
	-- WANDER POSITION FINDING
	-- ─────────────────────────────────────────────────────────────

	function SmartWander.findValidWanderPosition(enemyChar, maxAttempts, options, settings)
		local enemyHRT = enemyChar:FindFirstChild("HumanoidRootPart")
		if not enemyHRT then return nil end

		local startPosition = enemyHRT.Position
		local isDoorBreaker  = settings and settings.BreaksDoors

		local opts              = options or {}
		local biasAngle         = opts.biasAngle
		local biasSpread        = opts.biasSpread or math.pi / 2
		local minDist           = opts.minDist    or (settings and settings.MinWanderDistance) or 10
		local maxDist           = opts.maxDist    or (settings and settings.MaxWanderDistance) or 25
		local avoidPositions    = opts.avoidPositions or {}
		local avoidRadius       = opts.avoidRadius    or 0
		local avoidDoorsInPath  = opts.avoidDoorsInPath or false

		local floorParams = RaycastParams.new()
		floorParams.FilterType = Enum.RaycastFilterType.Exclude
		floorParams.FilterDescendantsInstances = {enemyChar}

		local pathParams = RaycastParams.new()
		pathParams.FilterType = Enum.RaycastFilterType.Exclude
		pathParams.FilterDescendantsInstances = {enemyChar}

		local attemptsLog = {}

		for attempt = 1, (maxAttempts or 10) do
			local angle
			if biasAngle ~= nil then
				angle = biasAngle + (math.random() - 0.5) * 2 * biasSpread
			else
				angle = math.random() * math.pi * 2
			end

			local distance  = minDist + math.random() * (maxDist - minDist)
			local candidate = startPosition + Vector3.new(
				math.cos(angle) * distance, 0, math.sin(angle) * distance
			)

			local floorResult = workspace:Raycast(
				candidate + Vector3.new(0, 10, 0),
				Vector3.new(0, -20, 0),
				floorParams
			)

			if not floorResult then
				table.insert(attemptsLog, string.format("  Attempt %d: no floor found at candidate", attempt))
				continue
			end

			local material   = floorResult.Material
			local isWalkable = material ~= Enum.Material.Water and material ~= Enum.Material.Ice

			if not isWalkable then
				table.insert(attemptsLog, string.format(
					"  Attempt %d: unwalkable material (%s)", attempt, tostring(material)
					))
				continue
			end

			local finalPos = floorResult.Position + Vector3.new(0, 3, 0)

			if avoidRadius > 0 then
				local tooClose = false
				for _, avoidPos in ipairs(avoidPositions) do
					if (finalPos - avoidPos).Magnitude < avoidRadius then
						tooClose = true; break
					end
				end
				if tooClose then
					table.insert(attemptsLog, string.format("  Attempt %d: too close to avoid position", attempt))
					continue
				end
			end

			if avoidDoorsInPath and settings and settings.DoorsFolder then
				local pfs  = game:GetService("PathfindingService")
				local path = pfs:CreatePath({ AgentRadius = 2.5, AgentCanJump = true })
				local ok   = pcall(function() path:ComputeAsync(startPosition, finalPos) end)
				if not ok or path.Status ~= Enum.PathStatus.Success then
					table.insert(attemptsLog, string.format("  Attempt %d: path failed (avoidDoorsInPath check)", attempt))
					continue
				end
				local hasDoor = false
				for _, wp in ipairs(path:GetWaypoints()) do
					if wp.Label and string.find(wp.Label:lower(), "door") then
						local door       = settings.DoorsFolder:FindFirstChild(wp.Label)
						local doorScript = door and door:FindFirstChild("Door")
						local openVal    = doorScript and doorScript:FindFirstChild("Open")
						if openVal and openVal.Value == false then
							hasDoor = true; break
						end
					end
				end
				if hasDoor then
					table.insert(attemptsLog, string.format("  Attempt %d: rejected — path goes through closed door", attempt))
					continue
				end
			elseif isDoorBreaker and settings and settings.DoorsFolder then
				local pathResult = workspace:Raycast(startPosition, finalPos - startPosition, pathParams)
				if pathResult and pathResult.Instance then
					local isDoor = pathResult.Instance:IsDescendantOf(settings.DoorsFolder)
						or string.find(pathResult.Instance.Name, "Door")
					if isDoor then
						local doorModel = pathResult.Instance:FindFirstAncestor("Door") or pathResult.Instance.Parent
						local openValue  = doorModel and doorModel:FindFirstChild("Open", true)
						if openValue and openValue.Value == false then
							table.insert(attemptsLog, string.format("  Attempt %d: rejected — closed door in way (door breaker)", attempt))
							continue
						end
					end
				end
			end

			if settings and settings.debugPrint then
				settings.debugPrint(string.format(
					"Found valid wander position on attempt %d: %.0f studs away",
					attempt, distance
					))
			end
			return finalPos
		end

		-- All attempts failed — log why
		if settings and settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] All %d wander position attempts failed. Reasons:",
				enemyChar.Name, maxAttempts or 10
				))
			for _, line in ipairs(attemptsLog) do
				settings.debugPrint(line)
			end
			settings.debugPrint("Falling back to nearby random offset.")
		end

		return startPosition + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))
	end

	-- ─────────────────────────────────────────────────────────────
	-- PATHFIND TO WANDER POSITION
	-- ─────────────────────────────────────────────────────────────

	function SmartWander.wanderToPosition(enemyChar, ai, targetPosition, settings, myGen)
		if not isWandering or wanderGeneration ~= myGen or not enemyChar or not enemyChar.Parent then return false end
		if not targetPosition then return false end

		SmartWander.cleanupBodyGyro(enemyChar)

		local config = ai.GetConfig(enemyChar)

		config.Tracking.Enabled      = false
		config.Visualization.Enabled = settings.visualize or false

		local reachedGoal = false
		local pathFailed  = false

		config.Hooks.PathfindingLinkReached = function(NPC, WP)
			if wanderGeneration ~= myGen then return true end

			if settings.BreaksDoors then
				local human = NPC:FindFirstChild("Humanoid")
				if human then human:Move(Vector3.zero) end
				SmartWander.faceRandomDirection(NPC)
				return false
			end

			return DoorOpener.onPathfindingLinkReached(NPC, WP)
		end

		config.Hooks.PathingFailed = function(NPC, reason)
			if wanderGeneration ~= myGen then return false end

			wanderPathFailCount += 1
			pathFailed = true

			if settings.debugPrint then
				settings.debugPrint(string.format(
					"[%s] Could not pathfind to wander target (fail #%d) — reason: %s | target: (%.1f, %.1f, %.1f)",
					NPC.Name, wanderPathFailCount, tostring(reason),
					targetPosition.X, targetPosition.Y, targetPosition.Z
					))
			end

			-- Proactively try to open a blocking door toward the wander target
			if wanderPathFailCount >= 1
				and os.clock() - lastWanderDoorAttempt >= WANDER_DOOR_COOLDOWN
			then
				local opened = tryOpenDoorTowardWanderTarget(NPC, targetPosition, settings)
				if opened then
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Opened blocking door toward wander target — retrying pathfind.",
							NPC.Name
							))
					end
					wanderPathFailCount = 0
					pathFailed = false -- allow the wait loop to keep going
					task.delay(0.5, function()
						if isWandering and wanderGeneration == myGen and NPC and NPC.Parent then
							ai.SmartPathfind(NPC, targetPosition)
						end
					end)
				else
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] No door found toward wander target — giving up on this point.",
							NPC.Name
							))
					end
				end
			end

			return false
		end

		config.Hooks.GoalReached = function(NPC, Target)
			if wanderGeneration ~= myGen then return true end

			reachedGoal = true
			wanderPathFailCount = 0

			if settings.debugPrint then
				settings.debugPrint(string.format(
					"[%s] Reached wander point at (%.1f, %.1f, %.1f)",
					NPC.Name, targetPosition.X, targetPosition.Y, targetPosition.Z
					))
			end

			if isWandering and wanderGeneration == myGen and enemyChar and enemyChar.Parent then
				SmartWander.faceRandomDirection(enemyChar)
			end
			return true
		end

		if settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] Pathing to wander target at (%.1f, %.1f, %.1f)",
				enemyChar.Name, targetPosition.X, targetPosition.Y, targetPosition.Z
				))
		end

		ai.SmartPathfind(enemyChar, targetPosition)

		local startTime = os.clock()
		while isWandering and wanderGeneration == myGen and not reachedGoal and not pathFailed and os.clock() - startTime < 12 do
			task.wait(0.1)
		end

		if settings.debugPrint then
			if reachedGoal then
				settings.debugPrint(string.format("[%s] Wander trip complete — goal reached.", enemyChar.Name))
			elseif pathFailed then
				settings.debugPrint(string.format("[%s] Wander trip ended — path failed.", enemyChar.Name))
			elseif os.clock() - startTime >= 12 then
				settings.debugPrint(string.format("[%s] Wander trip timed out after 12s.", enemyChar.Name))
			else
				settings.debugPrint(string.format("[%s] Wander trip ended — generation changed (combat started).", enemyChar.Name))
			end
		end

		if isWandering and wanderGeneration == myGen and not reachedGoal then
			ai.Stop(enemyChar)
		end

		return reachedGoal and wanderGeneration == myGen
	end

	-- ─────────────────────────────────────────────────────────────
	-- PUBLIC: START / STOP
	-- ─────────────────────────────────────────────────────────────

	function SmartWander.startWandering(enemyChar, ai, customSettings)
		if isWandering then return end

		local settings = {}
		for k, v in pairs(defaultSettings) do settings[k] = v end
		if customSettings then
			for k, v in pairs(customSettings) do settings[k] = v end
		end

		isWandering = true
		wanderGeneration += 1
		wanderPathFailCount = 0
		local myGen = wanderGeneration

		if settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] No targets found — beginning wander (gen %d).",
				enemyChar.Name, myGen
				))
		end
		ai.Stop(enemyChar)

		wanderCoroutine = task.spawn(function()
			while isWandering and wanderGeneration == myGen and enemyChar and enemyChar.Parent do
				local wanderTarget = SmartWander.findValidWanderPosition(enemyChar, 8, {
					minDist = settings.MinWanderDistance,
					maxDist = settings.MaxWanderDistance,
				}, settings)
				SmartWander.cleanupBodyGyro(enemyChar)

				if settings.debugPrint then
					settings.debugPrint(string.format(
						"[%s] Selected wander target: (%.1f, %.1f, %.1f)",
						enemyChar.Name,
						wanderTarget and wanderTarget.X or 0,
						wanderTarget and wanderTarget.Y or 0,
						wanderTarget and wanderTarget.Z or 0
						))
				end

				local success = SmartWander.wanderToPosition(enemyChar, ai, wanderTarget, settings, myGen)

				if wanderGeneration ~= myGen then break end

				if success then
					local minWait   = settings.MinWanderWait or 4
					local maxWait   = settings.MaxWanderWait or 10
					local waitTime  = math.random(minWait, maxWait)

					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Idling for %ds (range %d-%d).",
							enemyChar.Name, waitTime, minWait, maxWait
							))
					end

					local waitStart = os.clock()
					while isWandering and wanderGeneration == myGen and os.clock() - waitStart < waitTime do
						task.wait(1)
					end
					if isWandering and wanderGeneration == myGen and enemyChar and enemyChar.Parent then
						SmartWander.faceRandomDirection(enemyChar)
					end
				else
					-- Failed trip — short pause before trying a new point so we
					-- don't spin at full speed picking and failing endlessly
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Wander trip failed — waiting 1s before next attempt.",
							enemyChar.Name
							))
					end
					task.wait(1)
				end
			end

			if wanderGeneration == myGen and enemyChar and enemyChar.Parent then
				ai.Stop(enemyChar)
				SmartWander.cleanupBodyGyro(enemyChar)
			end
			if settings.debugPrint then
				settings.debugPrint(string.format(
					"[%s] Wander loop exited (gen %d).",
					enemyChar.Name, myGen
					))
			end
		end)
	end

	function SmartWander.stopWandering(enemyChar, ai)
		if not isWandering then return end

		isWandering = false
		wanderGeneration += 1

		if wanderCoroutine then
			task.cancel(wanderCoroutine)
			wanderCoroutine = nil
		end
		if enemyChar and enemyChar.Parent then
			ai.Stop(enemyChar)
			SmartWander.cleanupBodyGyro(enemyChar)
		end
		defaultSettings.debugPrint(string.format(
			"[%s] Wander stopped — target detected.",
			enemyChar and enemyChar.Name or "?"
			))
	end

	-- ─────────────────────────────────────────────────────────────
	-- PUBLIC: STATE / SETTINGS
	-- ─────────────────────────────────────────────────────────────

	function SmartWander.isWandering()
		return isWandering
	end

	function SmartWander.shouldCheckForWander()
		if os.clock() - lastWanderCheck > defaultSettings.WANDER_CHECK_INTERVAL then
			lastWanderCheck = os.clock()
			return true
		end
		return false
	end

	function SmartWander.updateSettings(newSettings)
		for k, v in pairs(newSettings) do defaultSettings[k] = v end
	end

	return SmartWander
end
