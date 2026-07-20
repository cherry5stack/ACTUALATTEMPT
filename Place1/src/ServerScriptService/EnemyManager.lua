-- EnemyManager.lua
local rs = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local VisionSystem     = require(rs.VisionSystem)
local AI               = require(rs.Forbidden.AI)
local EnemyData        = require(rs.EnemyData)
local TargetingManager = require(rs.TargetingManager)
local DistanceManager  = require(rs.DistanceManager)
local CombatManager    = require(rs.CombatManager)
local StuckRecovery    = require(rs.StuckRecovery)
local SoundManager     = require(rs.SoundManager)
local SmartWanderCtor  = require(rs.SmartWander)
local PhaseManager     = require(rs.PhaseManager)
local DoorOpener       = require(rs.DoorOpener)

local stuck = StuckRecovery()
local enemiesFolder = workspace:WaitForChild("Enemies")
local escapingFromImpassable = {}
local DEBUG              = true
local DEBUG_PRINT_DIST   = false
local DEBUG_PRINT_GROUND = false
local DEBUG_PRINT_FACE   = false

local REPATH_INTERVAL    = 0.5
local lastFootstep       = {}
local pathFailCount      = {}
local PATHFAIL_WANDER_THRESHOLD = 4
local recentlyDroppedTarget = {}

local function debugGroundCheck(npc, agentCosts)
	if not DEBUG_PRINT_GROUND then return end

	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { npc }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(npcRoot.Position, Vector3.new(0, -5, 0), params)
	if not result then return end

	local part     = result.Instance
	local modifier = part:FindFirstChildOfClass("PathfindingModifier")

	if modifier then
		local label = modifier.Label
		local cost  = agentCosts[label]
		if label and label ~= "" then
			if cost then
				print(string.format(
					"[%s] STANDING ON labelled part '%s' | Label='%s' | Cost=%s",
					npc.Name, part.Name, label,
					cost == math.huge and "math.huge (impassable)" or tostring(cost)
					))
			else
				print(string.format(
					"[%s] STANDING ON labelled part '%s' | Label='%s' | Cost=NOT IN AGENT COSTS (treated as 1)",
					npc.Name, part.Name, label
					))
			end
		end
	end
end


local function setupEnemy(npc)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local enemyTypeValue = npc:FindFirstChild("EnemyType")

	if not humanoid or not enemyTypeValue then
		warn("Enemy " .. npc.Name .. " is missing Humanoid or EnemyType")
		return
	end

	local data = EnemyData[enemyTypeValue.Value]
	if not data then
		warn("No data found for enemy type: " .. enemyTypeValue.Value)
		return
	end

	CombatManager.registerSpawnTime(npc)
	PhaseManager.registerPhases(npc, data.PhaseTransitions, data.PhaseCooldown)

	humanoid.MaxHealth = data.Health
	humanoid.Health    = data.Health
	humanoid.WalkSpeed = data.WalkSpeed

	local config = AI.GetConfig(npc)

	-- NEW: updated every tick in the main loop below. Read by the
	-- PathingFailed hook so it can tell the difference between "failed to
	-- find an initial path to the target" (should count toward giving up)
	-- and "failed to find a path to get CLOSER while already fighting"
	-- (harmless -- attacking doesn't require a path at all).
	local currentLOS = false

	local function defaultPathingFailed(npc, reason)
		if DEBUG then
			print(string.format("[%s] Pathing failed — %s", npc.Name, reason))
		end
	end

	local function applyCombatConfig(currentTarget)
		config.Tracking.Enabled = true
		config.DirectMoveTo.Enabled = false
		config.Hooks.GoalReached = nil
		config.Hooks.PathfindingLinkReached = function(NPC, WP)
			if not WP.Label or not string.find(string.lower(WP.Label), "door") then
				return true
			end
			if data.BreaksDoors then
				AI.Stop(NPC)
				return true
			end
			return DoorOpener.onPathfindingLinkReached(NPC, WP)
		end
		config.Hooks.PathingFailed = function(npc, reason)
			defaultPathingFailed(npc, reason)

			-- Failed APPROACH pathfinds while we already have LOS on the
			-- target are harmless -- we're already able to fight, we just
			-- can't get physically closer (e.g. target is on an unreachable
			-- ledge, or wedged somewhere the navmesh can't route to). Don't
			-- count these toward the give-up threshold, or a legitimate
			-- ongoing fight gets aborted into wander the moment repath
			-- attempts start failing while combat is working fine.
			if currentLOS then return end

			pathFailCount[npc] = (pathFailCount[npc] or 0) + 1
			if pathFailCount[npc] >= PATHFAIL_WANDER_THRESHOLD then
				return
			end
			task.delay(0.6, function()
				if currentTarget and humanoid.Health > 0 then
					AI.SmartPathfind(npc, currentTarget)
				end
			end)
		end
	end

	config.Tracking.Enabled                       = true
	config.Tracking.CollinearTargetPositionOffset  = 0 -- unused: distance-holding is handled per-tick in the loop below, not via DirectMoveTo offset
	config.AgentInfo.AgentRadius                  = data.AgentRadius
	config.AgentInfo.AgentHeight                  = data.AgentHeight
	config.AgentInfo.Costs = data.AgentCosts or { Obstacle = math.huge, Door = 1 }
	config.DirectMoveTo.Enabled                   = false
	config.Hooks.PathingFailed                    = defaultPathingFailed

	AI.InsertAntiLag(npc)

	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if npcRoot then
		SoundManager.play(data.Sounds and data.Sounds.Spawn, npcRoot.Position)
	end

	local wander = nil
	local lastCombatEndTime = 0

	if data.Wander and data.Wander.Enabled then
		wander = SmartWanderCtor()
		wander.updateSettings({
			BreaksDoors       = data.Wander.BreaksDoors or false,
			MinWanderWait     = data.Wander.MinWanderWait or 4,
			MaxWanderWait     = data.Wander.MaxWanderWait or 10,
			MinWanderDistance = data.Wander.MinWanderDistance or 10,
			MaxWanderDistance = data.Wander.MaxWanderDistance or 25,
			AgentRadius       = data.AgentRadius,
			AgentHeight       = data.AgentHeight,
			AgentCosts        = data.AgentCosts,
		})
	end

	humanoid.Died:Connect(function()
		humanoid.AutoRotate = true
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			SoundManager.play(data.Sounds and data.Sounds.Death, root.Position)
		end
		lastFootstep[npc] = nil
		pathFailCount[npc] = nil
		recentlyDroppedTarget[npc] = nil
		if wander then wander.stopWandering(npc, AI) end
		AI.Stop(npc)
		CombatManager.cleanup(npc)
		VisionSystem.stopFacing(npc)
	end)

	humanoid.Running:Connect(function(speed)
		if speed <= 0 then return end
		if humanoid.Health <= 0 then return end
		local root = npc:FindFirstChild("HumanoidRootPart")
		if not root then return end
		local footstepInterval = 0.7 / (humanoid.WalkSpeed / 16)
		local now = os.clock()
		if now - (lastFootstep[npc] or 0) >= footstepInterval then
			lastFootstep[npc] = now
			SoundManager.play(data.Sounds and data.Sounds.Footstep, root.Position)
		end
	end)

	task.spawn(function()
		local currentTarget      = nil
		local swapTimer          = 0
		local rePathTimer        = 0
		local SWAP_DELAY         = 1
		local pursuitActiveUntil = 0
		local seekingEdge        = false

		local lastDoorCheckTime = 0
		local DOOR_CHECK_INTERVAL = 1

		local function resetAttackState()
			seekingEdge = false
		end

		local function forceRepath()
			AI.Stop(npc)
			task.wait()
			if currentTarget and humanoid.Health > 0 then
				AI.SmartPathfind(npc, currentTarget)
				rePathTimer = os.clock()
			end
			stuck.reset(npc)
		end

		while #Players:GetPlayers() == 0 do task.wait(1) end
		task.wait(2)

		stuck.reset(npc)

		while npc.Parent ~= nil and humanoid.Health > 0 do
			task.wait(0.1)

			if DoorOpener.IsBreaking(npc) then
				continue
			end

			if humanoid.Health <= 0 then break end

			if not npc:FindFirstChild("HumanoidRootPart") then
				break
			end

			debugGroundCheck(npc, config.AgentInfo.Costs)

			PhaseManager.update(npc, humanoid, AI)

			if PhaseManager.isTransitioning(npc) then
				stuck.suppress()
				continue
			end

			-- ── NPC ON IMPASSABLE: escape first ──────────────────────────
			if stuck.isNPCOnImpassableSurface(npc, config.AgentInfo.Costs) then
				stuck.suppress()
				pathFailCount[npc] = 0

				local root = npc:FindFirstChild("HumanoidRootPart")
				if root and stuck.canAttemptEscape() then
					stuck.recordEscapeAttempt()

					local floorParams = RaycastParams.new()
					floorParams.FilterDescendantsInstances = { npc }
					floorParams.FilterType = Enum.RaycastFilterType.Exclude

					local foundEscape = false
					local angles = {0, 45, 90, 135, 180, 225, 270, 315}
					local distances = {2, 3, 5, 8}

					for _, dist in ipairs(distances) do
						if foundEscape then break end
						for _, deg in ipairs(angles) do
							local rad = math.rad(deg)
							local dir = Vector3.new(math.cos(rad), 0, math.sin(rad))
							local testPos = root.Position + dir * dist

							local floorResult = workspace:Raycast(
								testPos + Vector3.new(0, 3, 0),
								Vector3.new(0, -8, 0),
								floorParams
							)

							if floorResult then
								local mod = floorResult.Instance:FindFirstChildOfClass("PathfindingModifier")
								local isImpassable = false
								if mod and mod.Label and mod.Label ~= "" then
									local c = config.AgentInfo.Costs[mod.Label]
									if c == math.huge then isImpassable = true end
								end

								if not isImpassable then
									local escapePos = floorResult.Position + Vector3.new(0, 3, 0)

									escapingFromImpassable[npc] = true

									local originalCost = config.AgentInfo.Costs["CrackedLava"]
									config.AgentInfo.Costs["CrackedLava"] = 1
									config:ApplyNow()

									AI.SmartPathfind(npc, escapePos)

									task.spawn(function()
										local r = npc:FindFirstChild("HumanoidRootPart")
										local deadline = os.clock() + 5
										while os.clock() < deadline do
											task.wait(0.2)
											if not r or not r.Parent then break end
											local p = RaycastParams.new()
											p.FilterDescendantsInstances = { npc }
											p.FilterType = Enum.RaycastFilterType.Exclude
											local res = workspace:Raycast(r.Position, Vector3.new(0, -5, 0), p)
											if res then
												local m = res.Instance:FindFirstChildOfClass("PathfindingModifier")
												if not m or not m.Label or m.Label == "" then break end
												if originalCost ~= math.huge or m.Label ~= "CrackedLava" then break end
											else
												break
											end
										end
										config.AgentInfo.Costs["CrackedLava"] = originalCost
										config:ApplyNow()
										escapingFromImpassable[npc] = nil
									end)

									foundEscape = true
									break
								end
							end
						end
					end

					if not foundEscape then
						AI.Stop(npc)
					end
				end

				continue
			end

			-- ── TARGET DETECTION ─────────────────────────────────────────
			local inPursuitWindow   = os.clock() < pursuitActiveUntil
			local searchRange       = inPursuitWindow and (data.PursueRange or data.DetectionRange) or data.DetectionRange
			local searchHeightLimit = inPursuitWindow and (data.PursueHeightLimit or data.DetectionHeightLimit) or data.DetectionHeightLimit

			-- If the current target is still alive, within weapon range, and visible,
			-- keep it as-is this tick without re-running target search. This is what
			-- stops the NPC from reverting to wander mid-fight just because a barrier
			-- or missing navmesh made pathing fail -- attacking doesn't need a path.
			local keepCurrentTarget = false
			if currentTarget then
				local targetChar = currentTarget.Character
				local targetHum   = targetChar and targetChar:FindFirstChildOfClass("Humanoid")
				if targetChar and targetHum and targetHum.Health > 0 then
					local liveDist = DistanceManager.getDistance(npc, currentTarget)
					local liveLOS  = VisionSystem.hasLineOfSight(npc, currentTarget)
					if liveDist <= data.AttackDistance and liveLOS then
						keepCurrentTarget = true
					end
				end
			end

			local newTarget
			if keepCurrentTarget then
				newTarget = currentTarget
			else
				newTarget = TargetingManager.getTarget(npc, data, searchRange, searchHeightLimit, config.AgentInfo.Costs, config.AgentInfo, data.AttackDistance)

				if newTarget and recentlyDroppedTarget[npc]
					and recentlyDroppedTarget[npc].player == newTarget
					and os.clock() < recentlyDroppedTarget[npc].until_ then

					-- The drop-cooldown exists to stop a rapid drop/reacquire
					-- thrash loop when a target is genuinely unreachable. But
					-- if the target is ALREADY within weapon range and
					-- visible right now, there's no thrash risk -- it's
					-- simply attackable, so let it back in immediately
					-- instead of waiting out the fixed cooldown window.
					local liveDist = DistanceManager.getDistance(npc, newTarget)
					local liveLOS  = VisionSystem.hasLineOfSight(npc, newTarget)

					if liveDist <= data.AttackDistance and liveLOS then
						recentlyDroppedTarget[npc] = nil -- situation has changed, clear the cooldown
					else
						newTarget = nil
					end
				end
			end

			if newTarget ~= currentTarget then
				if newTarget == nil or os.clock() - swapTimer >= SWAP_DELAY then
					local hadTarget = currentTarget ~= nil

					currentTarget = newTarget
					swapTimer     = os.clock()
					rePathTimer   = 0
					resetAttackState()
					stuck.reset(npc)
					pathFailCount[npc] = 0

					if currentTarget then
						if wander and wander.isWandering() then
							wander.stopWandering(npc, AI)
						end
						if wander then wander.cleanupBodyGyro(npc) end
						applyCombatConfig(currentTarget)
						AI.SmartPathfind(npc, currentTarget)
						pursuitActiveUntil = os.clock() + (data.PursueLingerTime or 0)
					else
						AI.Stop(npc)
						VisionSystem.stopFacing(npc)
						humanoid.AutoRotate = true
						if hadTarget then
							lastCombatEndTime = os.clock()
						end
						pursuitActiveUntil = 0
					end
				end
			end

			if currentTarget then
				pursuitActiveUntil = os.clock() + (data.PursueLingerTime or 0)

				if DoorOpener.IsBreaking(npc) then
					stuck.suppress()
				end

				local hasLOS = VisionSystem.hasLineOfSight(npc, currentTarget)
				currentLOS = hasLOS -- NEW: keep the PathingFailed hook's view of LOS current

				-- Seeing the target at all means we're not "lost" -- reset
				-- the give-up counter here (not just inside the stricter
				-- `los` branch below, which also requires being in
				-- AttackDistance and the target not being on impassable
				-- ground). Without this, brief LOS flicker near geometry
				-- (visible as alternating LOS CLEAR/BLOCKED in logs) could
				-- let pathFailCount silently climb during an otherwise fine
				-- fight and eventually trigger a false "dropping target".
				if hasLOS then
					pathFailCount[npc] = 0
				end

				-- ── DOOR CHECK ───────────────────────────────────────────
				if not DoorOpener.IsBreaking(npc)
					and not CombatManager.isStandingStill(npc)
					and not escapingFromImpassable[npc]
					and os.clock() - lastDoorCheckTime >= DOOR_CHECK_INTERVAL then

					lastDoorCheckTime = os.clock()

					local targetChar = currentTarget.Character
					local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
					if targetRoot then
						-- Door search/approach range is intentionally separate from
						-- AttackDistance (weapon reach) -- they're unrelated concepts
						-- and AttackDistance can be large (e.g. long-range attacks),
						-- which would otherwise make the NPC search for and "approach"
						-- doors from way too far out.
						local doorSearchRange = data.DoorInteractionRange or 8
						local blockingDoor = DoorOpener.FindBlockingDoor(npc, targetRoot.Position, config.AgentInfo, doorSearchRange)
						if blockingDoor then
							if data.BreaksDoors then
								if DEBUG then
									print(string.format("[%s] Door '%s' is blocking — attacking it.", npc.Name, blockingDoor:GetFullName()))
								end
								AI.Stop(npc)
								DoorOpener.AttackDoor(npc, blockingDoor, {
									AnimationName  = data.DoorAttack and data.DoorAttack.AnimationName or "Punch",
									AttackSpeed    = data.DoorAttack and data.DoorAttack.AttackSpeed or 1,
									Cooldown       = data.DoorAttack and data.DoorAttack.Cooldown or 1,
									Damage         = data.DoorDamage or 10,
									AttackRange    = (data.DoorAttack and data.DoorAttack.AttackRange) or 5,
									MaxHeightDiff  = data.DoorAttackHeight or 5,
								}, function()
									if currentTarget and humanoid.Health > 0 then
										task.wait(0.2)
										AI.SmartPathfind(npc, currentTarget)
										rePathTimer = os.clock()
									end
								end)
							else
								if DEBUG then
									print(string.format("[%s] Door '%s' is blocking — opening it.", npc.Name, blockingDoor:GetFullName()))
								end
								DoorOpener.RequestOpen(npc, blockingDoor, data.DoorInteractionRange or 8, data.DoorAttackHeight or 5)
							end
						end
					end
				end

				-- ── DISTANCE / LOS ───────────────────────────────────────
				local dist    = DistanceManager.getDistance(npc, currentTarget)
				local inRange = DistanceManager.isInRange(npc, currentTarget, data)

				local targetOnImpassable = stuck.isTargetOnImpassableSurface(currentTarget, config.AgentInfo.Costs)

				local los = inRange and hasLOS and not targetOnImpassable

				local faceRange       = data.FaceTargetRange or data.AttackDistance
				local withinFaceRange = dist <= faceRange
				local faceLos         = withinFaceRange and hasLOS

				if DEBUG_PRINT_DIST then
					print(string.format(
						"[%s] Distance to %s: %.2f | AttackRange: %.2f",
						npc.Name, currentTarget.Name, dist, data.AttackDistance
						))
				end

				if DEBUG_PRINT_FACE then
					print(string.format(
						"[%s] dist=%.1f faceRange=%.1f within=%s hasLOS=%s faceLos=%s autoRotate=%s targetOnImpassable=%s",
						npc.Name, dist, faceRange, tostring(withinFaceRange), tostring(hasLOS),
						tostring(faceLos), tostring(humanoid.AutoRotate), tostring(targetOnImpassable)
						))
				end

				if faceLos then
					humanoid.AutoRotate = false
					VisionSystem.faceTarget(npc, currentTarget)
				else
					humanoid.AutoRotate = true
					VisionSystem.stopFacing(npc)
				end

				-- ── ATTACK ───────────────────────────────────────────────
				-- Distance-holding is checked FRESH every tick here, fully
				-- decoupled from Tracking's internal retrack timer. This is
				-- what prevents the "sniping from max range and never
				-- closing to ComfortDistance" bug: we don't wait for
				-- Tracking's DynamicRetrack timer or distance-moved
				-- threshold to decide whether to keep approaching.
				if los then
					stuck.suppress()
					pathFailCount[npc] = 0

					local comfortDist = data.ComfortDistance or data.AttackDistance or 4

					if dist <= comfortDist then
						-- Close enough — hold position and fight.
						AI.Stop(npc)
						rePathTimer = os.clock() -- avoid an immediate repath the instant we drift back out
					else
						-- Within AttackDistance (so an attack could technically
						-- reach) but still farther than we want to stand —
						-- keep closing the gap, throttled by REPATH_INTERVAL.
						if os.clock() - rePathTimer >= REPATH_INTERVAL then
							-- NEW: path to a point short of the target's exact
							-- position (pulled back toward the NPC by
							-- comfortDist) instead of the raw player instance.
							-- Without this, SmartPathfind aims at the player's
							-- exact root position, so if they're hugging a
							-- wall/corner the NPC walks right up against that
							-- same geometry instead of stopping at comfortDist.
							local targetChar = currentTarget.Character
							local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
							local npcRootPart = npc:FindFirstChild("HumanoidRootPart")

							if targetRoot and npcRootPart then
								local delta = targetRoot.Position - npcRootPart.Position
								local flatDelta = Vector3.new(delta.X, 0, delta.Z)
								if flatDelta.Magnitude > comfortDist then
									local standPos = targetRoot.Position - flatDelta.Unit * comfortDist
									AI.SmartPathfind(npc, standPos)
								end
							end

							rePathTimer = os.clock()
						end
					end

					if CombatManager.isStandingStill(npc) then
						AI.Stop(npc)
					end

					CombatManager.tryAttack(npc, currentTarget, data)

				else
					if CombatManager.isStandingStill(npc) then
						stuck.suppress()
						AI.Stop(npc)
						if DEBUG then
							print(string.format(
								"[%s] StandStillAfter active — suppressing movement. inRange=%s",
								npc.Name, tostring(inRange)
								))
						end
						if inRange then
							CombatManager.tryAttack(npc, currentTarget, data)
						end
					else
						-- ── STUCK TRACKING ───────────────────────────────
						if npc:GetAttribute("CrossingDoor") then
							stuck.suppress()
							pathFailCount[npc] = 0
						elseif DoorOpener.IsBreaking(npc) then
							stuck.suppress()
						else
							stuck.update(npc)
						end

						local pathGivenUp = (pathFailCount[npc] or 0) >= PATHFAIL_WANDER_THRESHOLD
						local pathBlockedByImpassable = stuck.isPathBlockedByImpassable(npc, currentTarget, config.AgentInfo.Costs)

						if targetOnImpassable then
							AI.Stop(npc)
							currentTarget = nil
							resetAttackState()
							stuck.resetUnstuckAttempts()
							stuck.suppress()
							VisionSystem.stopFacing(npc)
							humanoid.AutoRotate = true
							lastCombatEndTime = os.clock()
							pursuitActiveUntil = 0

						elseif not DoorOpener.IsBreaking(npc) and stuck.isStuck() then
							if pathGivenUp or pathBlockedByImpassable then
								if DEBUG then
									print(string.format("[%s] Dropping target — %d consecutive path failures.", npc.Name, pathFailCount[npc]))
								end
								AI.Stop(npc)
								recentlyDroppedTarget[npc] = { player = currentTarget, until_ = os.clock() + 8 }
								currentTarget = nil
								resetAttackState()
								stuck.resetUnstuckAttempts()
								stuck.suppress()
								VisionSystem.stopFacing(npc)
								humanoid.AutoRotate = true
								lastCombatEndTime = os.clock()
								pathFailCount[npc] = 0
								pursuitActiveUntil = 0
							elseif stuck.shouldEscalateToRepath() then
								stuck.resetUnstuckAttempts()
								forceRepath()
							else
								stuck.attemptUnstuck(npc, currentTarget, AI)
							end
						else
							if DoorOpener.IsBreaking(npc) then
								stuck.suppress()
								AI.Stop(npc)
								rePathTimer = os.clock()
							else
								local now = os.clock()
								local shouldRepath = (now - rePathTimer >= REPATH_INTERVAL)
								if shouldRepath then
									rePathTimer = now
									AI.SmartPathfind(npc, currentTarget)
								end
							end
						end
					end
				end
			else
				currentLOS = false -- NEW: no target, nothing to see
				-- ── WANDER ───────────────────────────────────────────────
				local postCombatDelay = (data.Wander and data.Wander.PostCombatDelay) or 0
				local delayElapsed    = os.clock() - lastCombatEndTime >= postCombatDelay

				if wander and not wander.isWandering() and delayElapsed and wander.shouldCheckForWander() then
					wander.startWandering(npc, AI)
				end
			end
		end

		if npc.Parent == nil or not npc:FindFirstChild("HumanoidRootPart") then
			if wander then wander.stopWandering(npc, AI) end
			CombatManager.cleanup(npc)
			VisionSystem.stopFacing(npc)
			pathFailCount[npc] = nil
			recentlyDroppedTarget[npc] = nil
			lastFootstep[npc] = nil
			TargetingManager.clearReachabilityCache(npc)
		end
	end)
end

for _, npc in enemiesFolder:GetChildren() do
	setupEnemy(npc)
end

enemiesFolder.ChildAdded:Connect(function(npc)
	task.wait()
	setupEnemy(npc)
end)
