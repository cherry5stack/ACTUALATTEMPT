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

-- Tracks failures while trying to APPROACH a target we already have LOS on
-- (i.e. trying to close to ComfortDistance). Separate from pathFailCount
-- (which tracks "can't find target at all" failures) because an approach
-- failure just means "can't get any closer right now," not "lost them."
--
-- knownUnreachable[npc] holds an os.clock() EXPIRY timestamp, not a plain
-- boolean -- it's a temporary "stop trying to close distance" cooldown, not
-- a permanent verdict. Without an expiry, an NPC that gave up approaching
-- (e.g. you were on an unreachable ledge) would never retry even after you
-- moved somewhere reachable mid-fight, since nothing else clears the flag
-- while the same target is still active. Expiring it means it periodically
-- re-attempts the approach -- cheap to re-fail if still unreachable, but
-- correctly recovers if the situation changed.
local approachFailCount = {}
local knownUnreachable  = {}
local UNREACHABLE_APPROACH_THRESHOLD = 3
local UNREACHABLE_RETRY_COOLDOWN = 5 -- seconds before re-attempting a closer approach

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

	-- Updated every tick in the main loop below. Read by the PathingFailed
	-- hook so it can tell the difference between "failed to find an initial
	-- path to the target" (should count toward giving up) and "failed to
	-- find a path to get CLOSER while already fighting" (harmless --
	-- attacking doesn't require a path at all, it just means we can't
	-- close the gap any further).
	local currentLOS = false

	-- Shared with the PathingFailed hook below: a failed no-LOS pathfind is
	-- resetting this to force an immediate door check on the very next loop
	-- tick, instead of waiting for the normal 1s DOOR_CHECK_INTERVAL. This
	-- collapses the "combat pathfind fails -> up to 1s wasted -> door check
	-- finally runs" delay that was visible as a stall before the NPC went
	-- for a blocking door.
	local lastDoorCheckTime = 0

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
			--
			-- Instead, track them separately: once we've failed to approach
			-- enough times in a row, mark the target as "known unreachable"
			-- so we stop retrying the comfort-distance chase and just fight
			-- from wherever we currently are.
			if currentLOS then
				approachFailCount[npc] = (approachFailCount[npc] or 0) + 1
				if approachFailCount[npc] >= UNREACHABLE_APPROACH_THRESHOLD then
					if not knownUnreachable[npc] and DEBUG then
						print(string.format(
							"[%s] Marking target unreachable after %d failed approach attempts — will hold and fight from current position for %ds.",
							npc.Name, approachFailCount[npc], UNREACHABLE_RETRY_COOLDOWN
							))
					end
					knownUnreachable[npc] = os.clock() + UNREACHABLE_RETRY_COOLDOWN
				end
				return
			end

			pathFailCount[npc] = (pathFailCount[npc] or 0) + 1
			if pathFailCount[npc] >= PATHFAIL_WANDER_THRESHOLD then
				return
			end

			-- A failed no-LOS pathfind is the earliest real signal that
			-- something (very likely a door) is blocking the route to the
			-- target. Force the next loop tick to run a door check
			-- immediately instead of waiting out the rest of the normal
			-- 1s DOOR_CHECK_INTERVAL.
			lastDoorCheckTime = 0

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
		approachFailCount[npc] = nil
		knownUnreachable[npc] = nil
		recentlyDroppedTarget[npc] = nil
		if wander then wander.stopWandering(npc, AI) end
		AI.Stop(npc)
		DoorOpener.CancelBreak(npc) -- the humanoid.Health check inside AttackDoor
		-- would catch this too, but this makes it
		-- immediate instead of waiting up to one
		-- 0.1s tick for the loop to notice.
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
		local closestPersistTarget = nil -- the candidate that's currently the closest OTHER than currentTarget
		local closestPersistSince  = os.clock() -- when it first became the closest, continuously
		local RETARGET_PERSIST_TIME = 0.2  -- seconds a different candidate must remain continuously closest before we actually swap to it (matches the reference TargetManager's SwapTargetTimer)
		local pursuitActiveUntil = 0
		local seekingEdge        = false

		local DOOR_CHECK_INTERVAL = 1
		local previousHasLOS      = true -- tracks LOS transitions, see below

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

			-- BUG FIX: keepCurrentTarget being true used to mean
			-- TargetingManager.getTarget was never called at all, so the NPC
			-- would only ever re-evaluate targets once the current one died,
			-- left range, or lost LOS -- never simply because a CLOSER
			-- target showed up while still fighting a farther one.
			--
			-- This checks every tick (matching the reference TargetManager's
			-- getClosestPlayer, which also has no interval throttle) which
			-- player is CURRENTLY closest. But it only actually swaps once a
			-- DIFFERENT player has been continuously closest for
			-- RETARGET_PERSIST_TIME straight -- the instant currentTarget
			-- reclaims "closest" (even briefly), the persistence timer
			-- resets. This is a duration check, not a distance-margin check:
			-- it doesn't matter how much closer the candidate is, only
			-- whether the ranking has been stable long enough to trust.
			-- Two players briefly crossing paths won't cause a swap; one
			-- player genuinely staying closer will, after the full
			-- persistence window.
			local closerCandidate = nil
			if keepCurrentTarget then
				local candidate = TargetingManager.getTarget(npc, data, searchRange, searchHeightLimit, config.AgentInfo.Costs, config.AgentInfo, data.AttackDistance)

				if candidate == nil or candidate == currentTarget then
					-- currentTarget is still the closest valid candidate (or
					-- nobody else qualifies) -- reset persistence tracking.
					closestPersistTarget = nil
					closestPersistSince = os.clock()
				else
					if closestPersistTarget ~= candidate then
						-- A different player just became the closest --
						-- start tracking it fresh.
						closestPersistTarget = candidate
						closestPersistSince = os.clock()
					end

					if os.clock() - closestPersistSince >= RETARGET_PERSIST_TIME then
						closerCandidate = candidate
					end
				end
			end

			local newTarget
			if closerCandidate then
				newTarget = closerCandidate
			elseif keepCurrentTarget then
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
					approachFailCount[npc] = 0
					knownUnreachable[npc] = nil
					closestPersistTarget = nil
					closestPersistSince = os.clock()

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
				currentLOS = hasLOS -- keep the PathingFailed hook's view of LOS current

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

				-- The instant LOS is actually LOST (true -> false transition,
				-- not just "still blocked from last tick"), force the door
				-- check below to run this very tick instead of waiting on
				-- either DOOR_CHECK_INTERVAL's own clock or a subsequent
				-- failed repath to reset it (that path was too slow -- a
				-- repath might not even fire for up to REPATH_INTERVAL after
				-- LOS drops, since rePathTimer can still be fresh from a
				-- moment earlier). Losing LOS while still in combat is
				-- itself the strongest, earliest signal something (very
				-- likely a door) just got in the way.
				if previousHasLOS and not hasLOS then
					lastDoorCheckTime = 0
				end
				previousHasLOS = hasLOS

				-- ── DOOR CHECK ───────────────────────────────────────────
				-- No interval throttle here (deliberately, matching the
				-- reference pattern): gate purely on "don't have LOS right
				-- now" and check every tick. A periodic 1s-interval version
				-- of this introduced a visible stall between losing LOS and
				-- actually detecting the blocking door.
				--
				-- isStandingStill is NOT checked here (removed) -- that flag
				-- is about combat-swing recovery (e.g. HeavySlam's
				-- StandStillAfter), which is unrelated to door detection.
				-- Gating on it meant the NPC couldn't even notice a blocking
				-- door for up to a full second after a swing, which was the
				-- cause of a visible stall before it went for the door.
				if not DoorOpener.IsBreaking(npc)
					and not escapingFromImpassable[npc]
					and not hasLOS then

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
									print(string.format("[%s] Door '%s' is blocking — walking to it to break it down.", npc.Name, blockingDoor:GetFullName()))
								end
								AI.Stop(npc)
								DoorOpener.AttackDoor(npc, blockingDoor, {
									AnimationName  = data.DoorAttack and data.DoorAttack.AnimationName or "Punch",
									AttackSpeed    = data.DoorAttack and data.DoorAttack.AttackSpeed or 1,
									Cooldown       = data.DoorAttack and data.DoorAttack.Cooldown or 1,
									Damage         = data.DoorDamage or 10,
									AttackRange    = (data.DoorAttack and data.DoorAttack.AttackRange) or 5,
									MaxHeightDiff  = data.DoorAttackHeight or 5,
								}, currentTarget, config.AgentInfo, function()
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

					local stillMarkedUnreachable = knownUnreachable[npc] and os.clock() < knownUnreachable[npc]

					if dist <= comfortDist or stillMarkedUnreachable then
						-- Close enough, OR we've recently learned (via
						-- repeated approach failures) that we can't path any
						-- closer -- e.g. target is on an unreachable ledge.
						-- Hold and fight from here instead of endlessly
						-- retrying a doomed approach. This expires after
						-- UNREACHABLE_RETRY_COOLDOWN so it periodically
						-- re-attempts in case the situation changed.
						AI.Stop(npc)
						rePathTimer = os.clock() -- avoid an immediate repath the instant we drift back out
					else
						-- Cooldown lapsed (or we were never marked) -- clear
						-- stale state so approach failures are counted fresh.
						if knownUnreachable[npc] and not stillMarkedUnreachable then
							knownUnreachable[npc] = nil
							approachFailCount[npc] = 0
						end

						-- Within AttackDistance (so an attack could technically
						-- reach) but still farther than we want to stand, and
						-- we haven't yet learned this target is unreachable --
						-- keep closing the gap, throttled by REPATH_INTERVAL.
						if os.clock() - rePathTimer >= REPATH_INTERVAL then
							-- Path to a point short of the target's exact
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
						-- Reached whenever we don't have a clean LOS on the
						-- target, regardless of range. If the target is
						-- actually reachable, the repath branch below (and
						-- the DOOR_CHECK block above, which runs every tick
						-- independent of LOS) will path us toward them and
						-- open/break doors as needed. If it's genuinely
						-- unreachable -- on impassable ground, or repath
						-- keeps failing -- this is what drops the target
						-- and hands off to wander.
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
				currentLOS = false -- no target, nothing to see
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
			approachFailCount[npc] = nil
			knownUnreachable[npc] = nil
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
