-- StuckRecovery.lua in ReplicatedStorage
return function()
	local StuckRecovery = {}

	local STUCK_DIST_THRESHOLD  = 0.3
	local STUCK_TIME            = 1.5
	local UNSTUCK_COOLDOWN      = 0.75 -- min time between sidestep attempts
	local UNSTUCK_SIDESTEP_DIST = 4    -- studs to sidestep
	local MAX_UNSTUCK_ATTEMPTS  = 3    -- after this many failed sidesteps, escalate to full repath

	local lastPos             = Vector3.new(0, 0, 0)
	local lastMovedTime       = os.clock()
	local lastUnstuckAttempt  = 0
	local unstuckAttemptCount = 0

	local function getNpcPos(npc)
		local root = npc:FindFirstChild("HumanoidRootPart")
		return root and root.Position or Vector3.new(0, 0, 0)
	end

	function StuckRecovery.reset(npc)
		lastPos              = getNpcPos(npc)
		lastMovedTime         = os.clock()
		unstuckAttemptCount   = 0
	end

	function StuckRecovery.update(npc)
		local pos   = getNpcPos(npc)
		local moved = (pos - lastPos).Magnitude
		if moved > STUCK_DIST_THRESHOLD then
			lastPos       = pos
			lastMovedTime = os.clock()
		end
	end

	function StuckRecovery.isStuck()
		return os.clock() - lastMovedTime >= STUCK_TIME
	end

	function StuckRecovery.suppress()
		-- call this when the NPC is intentionally standing still (attacking)
		-- so it doesn't false-trigger
		lastMovedTime = os.clock()
	end

	-- ─────────────────────────────────────────────────────────────
	-- SIDESTEP UNSTUCK
	-- ─────────────────────────────────────────────────────────────

	function StuckRecovery.canAttemptUnstuck()
		return os.clock() - lastUnstuckAttempt >= UNSTUCK_COOLDOWN
	end

	-- Jumps the NPC perpendicular to the direction toward target, to try
	-- to free a part of its body snagged on geometry (e.g. a wall edge).
	-- Alternates left/right across consecutive attempts so it doesn't
	-- repeatedly try the same (possibly blocked) side.
	function StuckRecovery.attemptUnstuck(npc, target, ai)
		if not StuckRecovery.canAttemptUnstuck() then return false end

		local root      = npc:FindFirstChild("HumanoidRootPart")
		local humanoid  = npc:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return false end

		-- Stop the active Forbidden pathfind so it doesn't race our MoveTo
		if ai then
			ai.Stop(npc)
		end

		local targetRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")

		local toTarget = nil
		if targetRoot then
			local diff = targetRoot.Position - root.Position
			local flat = Vector3.new(diff.X, 0, diff.Z)
			if flat.Magnitude > 0.1 then
				toTarget = flat.Unit
			end
		end

		if not toTarget then
			-- no target info, just pick a direction
			local angle = math.random() * math.pi * 2
			toTarget = Vector3.new(math.cos(angle), 0, math.sin(angle))
		end

		-- perpendicular direction on the horizontal plane
		local sideDir = Vector3.new(-toTarget.Z, 0, toTarget.X)

		-- alternate sides across attempts instead of random, so two jams
		-- in a row are guaranteed to try both directions
		if unstuckAttemptCount % 2 == 1 then
			sideDir = -sideDir
		end

		local sideTarget = root.Position + sideDir * UNSTUCK_SIDESTEP_DIST

		humanoid.Jump = true
		humanoid:MoveTo(sideTarget)

		lastUnstuckAttempt = os.clock()
		unstuckAttemptCount += 1

		StuckRecovery.suppress() -- reset stuck timer so isStuck() doesn't
		-- immediately re-fire before the jump plays out

		return true
	end
	
	function StuckRecovery.isTargetOnImpassableSurface(target, agentCosts)
		if not target or not target.Character then return false end

		local targetRoot = target.Character:FindFirstChild("HumanoidRootPart")
		if not targetRoot then return false end

		local params = RaycastParams.new()
		params.FilterDescendantsInstances = { target.Character }
		params.FilterType = Enum.RaycastFilterType.Exclude

		local result = workspace:Raycast(targetRoot.Position, Vector3.new(0, -5, 0), params)
		if not result then return false end

		local modifier = result.Instance:FindFirstChildOfClass("PathfindingModifier")
		if not modifier then return false end

		local label = modifier.Label
		if not label or label == "" then return false end

		local cost = agentCosts[label]
		return cost == math.huge
	end

	function StuckRecovery.shouldEscalateToRepath()
		return unstuckAttemptCount >= MAX_UNSTUCK_ATTEMPTS
	end

	function StuckRecovery.resetUnstuckAttempts()
		unstuckAttemptCount = 0
	end

	function StuckRecovery.updateSettings(newSettings)
		for k, v in pairs(newSettings) do
			if k == "DistThreshold"        then STUCK_DIST_THRESHOLD  = v end
			if k == "StuckTime"            then STUCK_TIME            = v end
			if k == "UnstuckCooldown"      then UNSTUCK_COOLDOWN      = v end
			if k == "UnstuckSidestepDist"  then UNSTUCK_SIDESTEP_DIST = v end
			if k == "MaxUnstuckAttempts"   then MAX_UNSTUCK_ATTEMPTS  = v end
		end
	end

	return StuckRecovery
end
