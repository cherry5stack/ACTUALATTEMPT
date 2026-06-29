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

	-- Raycasts toward the wander target and proactively opens a blocking
	-- door via the secure toggle — the single authoritative setter.
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

		-- Only consider geometry close to the NPC — a blocking door
		-- should be nearby, not across the map
		local hitDist = (result.Position - hrp.Position).Magnitude
		if hitDist > 8 then
			if settings.debugPrint then
				settings.debugPrint(string.format(
					"[%s] Wander raycast hit '%s' at %.1f studs — too far to be a blocking door.",
					enemyChar.Name, result.Instance:GetFullName(), hitDist
					))
			end
			return false
		end

		if settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] Wander raycast hit '%s' at %.1f studs — checking ancestry for door.",
				enemyChar.Name, result.Instance:GetFullName(), hitDist
				))
		end

		-- Walk up ancestry, stop before Workspace
		local inst = result.Instance
		local depth = 0
		while inst and inst ~= workspace and depth < 5 do
			depth += 1

			-- Pattern 1: Open BoolValue directly, name must suggest door
			local openVal = inst:FindFirstChild("Open")
			if openVal and openVal:IsA("BoolValue") and openVal.Value == false then
				local nameToCheck = string.lower(inst.Name .. (inst.Parent and inst.Parent.Name or ""))
				if string.find(nameToCheck, "door") then
					lastWanderDoorAttempt = now
					local secureToggle = _G["SecureToggleDoor_" .. inst:GetFullName()]
					if secureToggle then
						secureToggle(true)
					else
						openVal.Value = true
					end
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Wander opened door (direct Open) on '%s'.",
							enemyChar.Name, inst:GetFullName()
							))
					end
					return true
				end
			end

			-- Pattern 2: Door script child containing Open
			local doorScript = inst:FindFirstChild("Door")
			if doorScript then
				local openVal2 = doorScript:FindFirstChild("Open")
				if openVal2 and openVal2:IsA("BoolValue") and openVal2.Value == false then
					lastWanderDoorAttempt = now
					local secureToggle = _G["SecureToggleDoor_" .. inst:GetFullName()]
					if secureToggle then
						secureToggle(true)
					else
						openVal2.Value = true
					end
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Wander opened door (Door.Open) on '%s'.",
							enemyChar.Name, inst:GetFullName()
							))
					end
					return true
				end
			end

			inst = inst.Parent
		end

		if settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] Wander: no door found in ancestry of hit part.",
				enemyChar.Name
				))
		end
		return false
	end

	function SmartWander.findValidWanderPosition(enemyChar, ai, maxAttempts, options, settings)
		local enemyHRT = enemyChar:FindFirstChild("HumanoidRootPart")
		if not enemyHRT then return nil end

		local config = ai.GetConfig(enemyChar)
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
				table.insert(attemptsLog, string.format("  Attempt %d: no floor found", attempt))
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
					table.insert(attemptsLog, string.format("  Attempt %d: path failed (avoidDoorsInPath)", attempt))
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
					table.insert(attemptsLog, string.format("  Attempt %d: path through closed door", attempt))
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
							table.insert(attemptsLog, string.format("  Attempt %d: closed door in way (breaker)", attempt))
							continue
						end
					end
				end
			end

			-- Pre-verify using the NPC's actual agent settings so door
			-- modifiers and PathfindingLinks are respected correctly
			-- Replace the entire pre-verify block with this:
			local pfs = game:GetService("PathfindingService")
			local verifyPath = pfs:CreatePath({
				AgentRadius  = config.AgentInfo.AgentRadius,
				AgentHeight  = config.AgentInfo.AgentHeight,
				AgentCanJump = config.AgentInfo.AgentCanJump,
				Costs        = config.AgentInfo.Costs,
			})
			local ok = pcall(function() verifyPath:ComputeAsync(startPosition, finalPos) end)
			if not ok or verifyPath.Status ~= Enum.PathStatus.Success then
				-- Check if any tagged door lies between the NPC and the candidate
				local CollectionService = game:GetService("CollectionService")
				local hrp = enemyChar:FindFirstChild("HumanoidRootPart")
				local blockedByDoor = false

				if hrp then
					local doorCheckParams = RaycastParams.new()
					doorCheckParams.FilterDescendantsInstances = { enemyChar }
					doorCheckParams.FilterType = Enum.RaycastFilterType.Exclude

					local origin = hrp.Position + Vector3.new(0, 1, 0)
					local direction = finalPos - origin

					local doorRay = workspace:Raycast(origin, direction, doorCheckParams)

					if doorRay then
						local hitDist = (doorRay.Position - hrp.Position).Magnitude
						if settings and settings.debugPrint then
							settings.debugPrint(string.format(
								"[%s] Attempt %d door-check ray hit '%s' at %.1f studs",
								enemyChar.Name, attempt, doorRay.Instance:GetFullName(), hitDist
								))
						end

						if hitDist <= 12 then
							-- Check if the hit part belongs to any tagged door model
							for _, doorModel in ipairs(CollectionService:GetTagged("Door")) do
								if doorRay.Instance:IsDescendantOf(doorModel) then
									local openVal = doorModel:FindFirstChild("Open")
									if openVal and openVal:IsA("BoolValue") then
										blockedByDoor = true
										if settings and settings.debugPrint then
											settings.debugPrint(string.format(
												"[%s] Attempt %d: ray hit door model '%s' (Open=%s) — %s.",
												enemyChar.Name, attempt, doorModel:GetFullName(),
												tostring(openVal.Value),
												openVal.Value == false and "accepting position" or "door already open, still accepting"
												))
										end
									end
									break
								end
							end
						end
					else
						if settings and settings.debugPrint then
							settings.debugPrint(string.format(
								"[%s] Attempt %d door-check ray hit nothing — target may be in same room.",
								enemyChar.Name, attempt
								))
						end
					end
				end

				if not blockedByDoor then
					table.insert(attemptsLog, string.format(
						"  Attempt %d: pre-path verify failed (unreachable, no door)", attempt
						))
					continue
				end
				-- blockedByDoor = true, fall through to return finalPos
			end

			if settings and settings.debugPrint then
				settings.debugPrint(string.format(
					"[%s] Found valid wander position on attempt %d: %.0f studs away",
					enemyChar.Name, attempt, distance
					))
			end
			return finalPos
		end

		if settings and settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] All wander position attempts failed:",
				enemyChar.Name
				))
			for _, line in ipairs(attemptsLog) do
				settings.debugPrint(line)
			end
			settings.debugPrint("Falling back to nearby offset.")
		end

		return startPosition + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))
	end

	function SmartWander.wanderToPosition(enemyChar, ai, targetPosition, settings, myGen)
		if not isWandering or wanderGeneration ~= myGen or not enemyChar or not enemyChar.Parent then return false end
		if not targetPosition then return false end

		SmartWander.cleanupBodyGyro(enemyChar)

		local config = ai.GetConfig(enemyChar)

		config.Tracking.Enabled      = false
		config.Visualization.Enabled = settings.visualize or false

		local reachedGoal = false
		local pathFailed  = false

		-- Delegate entirely to DoorOpener — single authority for Open.Value
		config.Hooks.PathfindingLinkReached = function(NPC, WP)
			if wanderGeneration ~= myGen then return true end

			if settings.BreaksDoors then
				if not WP.Label or not string.find(string.lower(WP.Label), "door") then return true end
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
					"[%s] Could not pathfind to wander target (fail #%d) | target: (%.1f, %.1f, %.1f)",
					NPC.Name, wanderPathFailCount,
					targetPosition.X, targetPosition.Y, targetPosition.Z
					))
			end

			-- Try proactive door open on first failure
			if wanderPathFailCount >= 1 then
				local opened = tryOpenDoorTowardWanderTarget(NPC, targetPosition, settings)
				if opened then
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Opened blocking door — retrying pathfind in 0.5s.",
							NPC.Name
							))
					end
					wanderPathFailCount = 0
					pathFailed = false
					task.delay(0.5, function()
						if isWandering and wanderGeneration == myGen and NPC and NPC.Parent then
							ai.SmartPathfind(NPC, targetPosition)
						end
					end)
				else
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] No door found — giving up on this wander point.",
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
				settings.debugPrint(string.format("[%s] Wander trip complete.", enemyChar.Name))
			elseif pathFailed then
				settings.debugPrint(string.format("[%s] Wander trip ended — path failed.", enemyChar.Name))
			elseif os.clock() - startTime >= 12 then
				settings.debugPrint(string.format("[%s] Wander trip timed out after 12s.", enemyChar.Name))
			else
				settings.debugPrint(string.format("[%s] Wander trip ended — combat started.", enemyChar.Name))
			end
		end

		if isWandering and wanderGeneration == myGen and not reachedGoal then
			ai.Stop(enemyChar)
		end

		return reachedGoal and wanderGeneration == myGen
	end

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
				-- Pass ai so findValidWanderPosition can read AgentInfo
				local wanderTarget = SmartWander.findValidWanderPosition(enemyChar, ai, 8, {
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
