return function()
	local SmartWander = {}

	local isWandering      = false
	local wanderGeneration  = 0 -- invalidates stale hooks/loops from a previous wander run
	local wanderCoroutine   = nil
	local lastWanderCheck   = os.clock() -- ensures first check is delayed by the interval, gives idle beat on spawn

	local defaultSettings = {
		WANDER_CHECK_INTERVAL = 3,
		DoorsFolder           = workspace:FindFirstChild("Doors"), -- optional, fine if nil
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

	-- Rotates the NPC to face a random horizontal direction.
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

	-- Removes the wander rotation gyro if present.
	function SmartWander.cleanupBodyGyro(enemyChar)
		if not enemyChar then return end
		local hrp = enemyChar:FindFirstChild("HumanoidRootPart")
		if hrp then
			local bodyGyro = hrp:FindFirstChild("WanderBodyGyro")
			if bodyGyro then bodyGyro:Destroy() end
		end
	end

	-- ─────────────────────────────────────────────────────────────
	-- WANDER POSITION FINDING
	-- Tries to find a walkable spot that isn't behind a closed door.
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

		for _ = 1, (maxAttempts or 10) do
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

			if floorResult then
				local material   = floorResult.Material
				local isWalkable = material ~= Enum.Material.Water and material ~= Enum.Material.Ice

				if isWalkable then
					local finalPos = floorResult.Position + Vector3.new(0, 3, 0)

					if avoidRadius > 0 then
						local tooClose = false
						for _, avoidPos in ipairs(avoidPositions) do
							if (finalPos - avoidPos).Magnitude < avoidRadius then
								tooClose = true; break
							end
						end
						if tooClose then continue end
					end

					if avoidDoorsInPath and settings and settings.DoorsFolder then
						local pfs  = game:GetService("PathfindingService")
						local path = pfs:CreatePath({ AgentRadius = 2.5, AgentCanJump = true })
						local ok   = pcall(function() path:ComputeAsync(startPosition, finalPos) end)
						if not ok or path.Status ~= Enum.PathStatus.Success then
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
							if settings.debugPrint then
								settings.debugPrint("Rejected wander point: path goes through closed door")
							end
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
									if settings.debugPrint then
										settings.debugPrint("Rejected wander point: closed door in the way")
									end
									continue
								end
							end
						end
					end

					if settings and settings.debugPrint then
						settings.debugPrint("Found valid wander position: " .. math.floor(distance) .. " studs away")
					end
					return finalPos
				end
			end
		end

		return startPosition + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))
	end

	-- ─────────────────────────────────────────────────────────────
	-- PATHFIND TO WANDER POSITION
	--
	-- NOTE: This intentionally does NOT call config:RestoreDefaults() and
	-- does NOT touch AgentRadius / AgentHeight / Costs / WaypointSpacing.
	-- Those are physical/hazard properties of the NPC set once in
	-- EnemyManager.setupEnemy and must persist across both combat and
	-- wander states.
	--
	-- myGen is the generation number captured by startWandering. Every
	-- hook and wait-loop checks wanderGeneration == myGen before acting,
	-- so if stopWandering() is called mid-flight (bumping the generation),
	-- any in-flight hooks fired by Forbidden's internal coroutines become
	-- harmless no-ops instead of corrupting state after combat has begun.
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
			if wanderGeneration ~= myGen then return true end -- stale request, just let it pass through

			if not WP.Label or not string.find(WP.Label, "Door") then return true end
			if not settings.DoorsFolder then return true end

			if settings.BreaksDoors then
				local human = NPC:FindFirstChild("Humanoid")
				if human then human:Move(Vector3.zero) end
				SmartWander.faceRandomDirection(NPC)
				return false
			end

			local door       = settings.DoorsFolder:FindFirstChild(WP.Label)
			local doorScript = door and door:FindFirstChild("Door")
			if doorScript and doorScript:FindFirstChild("Open") then
				if not doorScript.Open.Value then
					doorScript.Open.Value = true
					if settings.debugPrint then
						settings.debugPrint("Opened door during wander: " .. WP.Label)
					end
				end
			end
			return true
		end

		config.Hooks.PathingFailed = function(NPC, Target)
			if wanderGeneration ~= myGen then return false end -- stale, ignore

			pathFailed = true
			if settings.debugPrint then
				settings.debugPrint("Could not pathfind to wander target")
			end
			return false
		end

		config.Hooks.GoalReached = function(NPC, Target)
			if wanderGeneration ~= myGen then return true end -- stale, ignore completely (no print, no facing)

			reachedGoal = true
			if settings.debugPrint then
				settings.debugPrint("Reached wander point")
			end
			if isWandering and wanderGeneration == myGen and enemyChar and enemyChar.Parent then
				SmartWander.faceRandomDirection(enemyChar)
			end
			return true
		end

		ai.SmartPathfind(enemyChar, targetPosition)

		local startTime = os.clock()
		while isWandering and wanderGeneration == myGen and not reachedGoal and not pathFailed and os.clock() - startTime < 12 do
			task.wait(0.1)
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
		local myGen = wanderGeneration

		if settings.debugPrint then
			settings.debugPrint("No targets found, beginning wander...")
		end
		ai.Stop(enemyChar)

		wanderCoroutine = task.spawn(function()
			while isWandering and wanderGeneration == myGen and enemyChar and enemyChar.Parent do
				local wanderTarget = SmartWander.findValidWanderPosition(enemyChar, 8, {
					minDist = settings.MinWanderDistance,
					maxDist = settings.MaxWanderDistance,
				}, settings)
				SmartWander.cleanupBodyGyro(enemyChar)

				local success = SmartWander.wanderToPosition(enemyChar, ai, wanderTarget, settings, myGen)

				if wanderGeneration ~= myGen then break end -- superseded mid-call, bail immediately

				if success then
					local minWait   = settings.MinWanderWait or 4
					local maxWait   = settings.MaxWanderWait or 10
					local waitTime  = math.random(minWait, maxWait)

					if settings.debugPrint then
						settings.debugPrint(string.format(
							"Idling at wander point for %d seconds (range %d-%d)",
							waitTime, minWait, maxWait
							))
					end

					local waitStart = os.clock()
					while isWandering and wanderGeneration == myGen and os.clock() - waitStart < waitTime do
						task.wait(1)
					end
					if isWandering and wanderGeneration == myGen and enemyChar and enemyChar.Parent then
						SmartWander.faceRandomDirection(enemyChar)
					end
				end
			end

			if wanderGeneration == myGen and enemyChar and enemyChar.Parent then
				ai.Stop(enemyChar)
				SmartWander.cleanupBodyGyro(enemyChar)
			end
			if settings.debugPrint then
				settings.debugPrint("Wander stopped")
			end
		end)
	end

	function SmartWander.stopWandering(enemyChar, ai)
		if not isWandering then return end

		isWandering = false
		wanderGeneration += 1 -- invalidates ALL pending hooks/loops from the old run immediately

		if wanderCoroutine then
			task.cancel(wanderCoroutine)
			wanderCoroutine = nil
		end
		if enemyChar and enemyChar.Parent then
			ai.Stop(enemyChar)
			SmartWander.cleanupBodyGyro(enemyChar)
		end
		defaultSettings.debugPrint("Wander stopped — target detected")
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
