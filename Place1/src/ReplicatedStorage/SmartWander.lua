return function()
	local SmartWander = {}
	local rs = game:GetService("ReplicatedStorage")
	local DoorOpener = require(rs.DoorOpener)
	local CollectionService = game:GetService("CollectionService")
	local pfs  = game:GetService("PathfindingService")
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
	-- closed door in the way. Opens it via SecureToggleDoor_ global —
	-- the single authoritative writer for openValue.
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

		local hitDist = (result.Position - hrp.Position).Magnitude
		if hitDist > 15 then
			if settings.debugPrint then
				settings.debugPrint(string.format(
					"[%s] Wander raycast hit '%s' but it's %.1f studs away — too far, ignoring.",
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

		-- Walk up ancestry looking for a CollectionService-tagged Door model
		local inst = result.Instance
		while inst and inst ~= workspace do
			if CollectionService:HasTag(inst, "Door") then
				local openVal = inst:FindFirstChild("Open")
				if openVal and openVal:IsA("BoolValue") and openVal.Value == false then
					local secureToggle = _G["SecureToggleDoor_" .. inst:GetFullName()]
					if secureToggle then
						lastWanderDoorAttempt = now
						if settings.debugPrint then
							settings.debugPrint(string.format(
								"[%s] Wander opened door '%s' via SecureToggle.",
								enemyChar.Name, inst:GetFullName()
								))
						end
						secureToggle(true)
						return true
					else
						if settings.debugPrint then
							settings.debugPrint(string.format(
								"[%s] Wander: found door '%s' but no SecureToggle global found.",
								enemyChar.Name, inst:GetFullName()
								))
						end
					end
				end
				break
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

		local floorParams = RaycastParams.new()
		floorParams.FilterType = Enum.RaycastFilterType.Exclude
		floorParams.FilterDescendantsInstances = {enemyChar}

		local doorRayParams = RaycastParams.new()
		doorRayParams.FilterType = Enum.RaycastFilterType.Exclude
		doorRayParams.FilterDescendantsInstances = {enemyChar}

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

			-- Check if a door is in the path via raycast
			local doorRay = workspace:Raycast(startPosition, finalPos - startPosition, doorRayParams)
			local doorInPath = false

			if doorRay then
				if settings and settings.debugPrint then
					settings.debugPrint(string.format(
						"[%s] Attempt %d door-check ray hit '%s' at %.1f studs",
						enemyChar.Name, attempt, doorRay.Instance:GetFullName(),
						(doorRay.Position - startPosition).Magnitude
						))
				end

				local inst = doorRay.Instance
				while inst and inst ~= workspace do
					if CollectionService:HasTag(inst, "Door") then
						doorInPath = true
						local openVal = inst:FindFirstChild("Open")
						local isOpen  = openVal and openVal.Value == true
						if settings and settings.debugPrint then
							settings.debugPrint(string.format(
								"[%s] Attempt %d: ray hit door model '%s' (Open=%s) — %s.",
								enemyChar.Name, attempt, inst:GetFullName(), tostring(isOpen),
								isOpen and "door already open, still accepting" or "accepting position"
								))
						end
						break
					end
					inst = inst.Parent
				end
			else
				if settings and settings.debugPrint then
					settings.debugPrint(string.format(
						"[%s] Attempt %d door-check ray hit nothing — target may be in same room.",
						enemyChar.Name, attempt
						))
				end
			end

			if doorInPath then
				if isDoorBreaker then
					table.insert(attemptsLog, string.format(
						"  Attempt %d: rejected — door in path and BreaksDoors=true", attempt
						))
					continue
				end
				-- Door in path and non-breaker — verify destination is reachable
				-- (door may be open already, or we'll open it on path failure)
				
				local path = pfs:CreatePath({
					AgentRadius  = (settings and settings.AgentRadius)  or 2.5,
					AgentHeight  = (settings and settings.AgentHeight)  or 5,
					AgentCanJump = true,
					Costs        = (settings and settings.AgentCosts)   or {},
				})
				local ok = false
				pcall(function() path:ComputeAsync(startPosition, finalPos) end)
				ok = path.Status == Enum.PathStatus.Success
				if not ok then
					table.insert(attemptsLog, string.format(
						"  Attempt %d: door in path but destination unreachable even with door open", attempt
						))
					continue
				end
				-- Non-breakers accept the position; they open the door on path failure
			else
				-- No door in path — verify the position is actually reachable
				local agentParams = {
					AgentRadius  = (settings and settings.AgentRadius)  or 2.5,
					AgentHeight  = (settings and settings.AgentHeight)  or 5,
					AgentCanJump = true,
					Costs        = (settings and settings.AgentCosts)   or {},
				}
				local path = pfs:CreatePath(agentParams)
				local ok   = pcall(function() path:ComputeAsync(startPosition, finalPos) end)
				if not ok or path.Status ~= Enum.PathStatus.Success then
					if settings and settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] Attempt %d: pre-path verify failed (unreachable, no door)",
							enemyChar.Name, attempt
							))
					end
					table.insert(attemptsLog, string.format(
						"  Attempt %d: pre-path verify failed (unreachable, no door)", attempt
						))
					continue
				end

				-- For door-breakers, also reject if the computed path goes through a door link
				if isDoorBreaker then
					local waypoints = path:GetWaypoints()
					local pathHasDoor = false
					for _, wp in ipairs(waypoints) do
						if wp.Action == Enum.PathWaypointAction.Custom
							and wp.Label and string.find(string.lower(wp.Label), "door")
						then
							pathHasDoor = true
							break
						end
					end
					if pathHasDoor then
						if settings and settings.debugPrint then
							settings.debugPrint(string.format(
								"[%s] Attempt %d: rejected — path goes through door link (BreaksDoors=true)",
								enemyChar.Name, attempt
								))
						end
						table.insert(attemptsLog, string.format(
							"  Attempt %d: rejected — path goes through door link (BreaksDoors=true)", attempt
							))
						continue
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

		-- All attempts failed
		if settings and settings.debugPrint then
			settings.debugPrint(string.format(
				"[%s] All %d wander position attempts failed:",
				enemyChar.Name, maxAttempts or 10
				))
			for _, line in ipairs(attemptsLog) do
				settings.debugPrint(line)
			end
		end

		return nil  -- caller handles this by standing still
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

			if settings.BreaksDoors ~= true then
				return DoorOpener.onPathfindingLinkReached(NPC, WP)
			end

			-- BreaksDoors = true: should never reach a door link during wander,
			-- but if somehow triggered, stop movement and return true to avoid WaypointLooper error
			local human = NPC:FindFirstChild("Humanoid")
			if human then human:Move(Vector3.zero) end
			SmartWander.faceRandomDirection(NPC)
			return true
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

			-- Only non-breakers try to open doors during wander
			if settings.BreaksDoors ~= true
				and wanderPathFailCount >= 1
				and os.clock() - lastWanderDoorAttempt >= WANDER_DOOR_COOLDOWN
			then
				local opened = tryOpenDoorTowardWanderTarget(NPC, targetPosition, settings)
				if opened then
					-- Wait for door to open then verify path is actually usable
					task.delay(1.2, function()
						if not (isWandering and wanderGeneration == myGen and NPC and NPC.Parent) then return end

						local pfs = game:GetService("PathfindingService")
						local path = pfs:CreatePath({
							AgentRadius  = settings.AgentRadius or 2.5,
							AgentHeight  = settings.AgentHeight or 5,
							AgentCanJump = true,
							Costs        = settings.AgentCosts or {},
						})
						local npcRoot = NPC:FindFirstChild("HumanoidRootPart")
						local ok = false
						if npcRoot then
							pcall(function() path:ComputeAsync(npcRoot.Position, targetPosition) end)
							ok = path.Status == Enum.PathStatus.Success
						end

						if ok then
							wanderPathFailCount = 0
							pathFailed = false
							ai.SmartPathfind(NPC, targetPosition)
						else
							if settings.debugPrint then
								settings.debugPrint(string.format(
									"[%s] Door opened but destination still unreachable — abandoning point.",
									NPC.Name
									))
							end
							-- pathFailed is already true, loop will exit naturally
						end
					end)
				else
					-- no door found, already giving up
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
				local wanderTarget = SmartWander.findValidWanderPosition(enemyChar, 4, {
					minDist = settings.MinWanderDistance,
					maxDist = settings.MaxWanderDistance,
				}, settings)
				SmartWander.cleanupBodyGyro(enemyChar)

				if not wanderTarget then
					-- No valid position found — stand still and idle before trying again
					if settings.debugPrint then
						settings.debugPrint(string.format(
							"[%s] No valid wander position found — standing still.",
							enemyChar.Name
							))
					end
					local waitTime = math.random(settings.MinWanderWait or 4, settings.MaxWanderWait or 10)
					local waitStart = os.clock()
					while isWandering and wanderGeneration == myGen and os.clock() - waitStart < waitTime do
						task.wait(1)
					end
					continue
				end

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
