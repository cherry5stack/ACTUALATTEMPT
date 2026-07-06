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


local enemiesFolder = workspace:WaitForChild("Enemies")

local DEBUG              = true
local DEBUG_PRINT_DIST   = true
local DEBUG_PRINT_GROUND = true
local DEBUG_PRINT_FACE   = true

local REPATH_INTERVAL    = 0.5
local lastFootstep       = {}
local pathFailCount      = {}

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

	local function defaultPathingFailed(npc, reason)
		if DEBUG then
			print(string.format("[%s] Pathing failed — %s", npc.Name, reason))
		end
	end

	local function applyCombatConfig(currentTarget)
		config.Tracking.Enabled = true
		config.DirectMoveTo.Enabled = false
		config.Hooks.GoalReached = nil
		config.Hooks.PathfindingLinkReached = DoorOpener.onPathfindingLinkReached
		config.Hooks.PathingFailed = function(npc, reason)
			defaultPathingFailed(npc, reason)
			pathFailCount[npc] = (pathFailCount[npc] or 0) + 1
			task.delay(0.6, function()
				if currentTarget and humanoid.Health > 0 then
					AI.SmartPathfind(npc, currentTarget)
				end
			end)
		end
	end

	config.Tracking.Enabled                       = true
	config.Tracking.CollinearTargetPositionOffset  = 0
	config.AgentInfo.AgentRadius                  = data.AgentRadius
	config.AgentInfo.AgentHeight                  = data.AgentHeight
	config.AgentInfo.Costs = data.AgentCosts or { Obstacle = math.huge, Door = 5 }
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
		local isAttacking        = false
		local attackStandPos     = nil
		local swapTimer          = 0
		local rePathTimer        = 0
		local SWAP_DELAY         = 1
		local pursuitActiveUntil = 0

		local stuck = StuckRecovery()

		local lastDoorCheckTime = 0
		local DOOR_CHECK_INTERVAL = 1 -- seconds; ComputeAsync is too heavy for every 0.1s tick

		local function resetAttackState()
			isAttacking    = false
			attackStandPos = nil
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

			local inPursuitWindow   = os.clock() < pursuitActiveUntil
			local searchRange       = inPursuitWindow and (data.PursueRange or data.DetectionRange) or data.DetectionRange
			local searchHeightLimit = inPursuitWindow and (data.PursueHeightLimit or data.DetectionHeightLimit) or data.DetectionHeightLimit

			local newTarget = TargetingManager.getTarget(npc, data, searchRange, searchHeightLimit)

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
					end
				end
			end

			if currentTarget then
				pursuitActiveUntil = os.clock() + (data.PursueLingerTime or 0)

				-- Suppress stuck recovery while actively breaking a door
				if DoorOpener.IsBreaking(npc) then
					stuck.suppress()
				end

				-- Path-aware door handling for all enemy types, throttled since
				-- FindBlockingDoor runs a real ComputeAsync. Breakers attack the
				-- door; non-breakers simply request it open. Both only act on doors
				-- that are actually on the computed route to the target, avoiding
				-- the "opens every nearby door" problem of proximity-based openers.
				-- Skip door check during StandStillAfter — the NPC is frozen in place
				-- and should not start a door break until it's free to move again.
				if not DoorOpener.IsBreaking(npc) and not CombatManager.isStandingStill(npc) and os.clock() - lastDoorCheckTime >= DOOR_CHECK_INTERVAL then
					lastDoorCheckTime = os.clock()

					local targetChar = currentTarget.Character
					local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
					if targetRoot then
						local blockingDoor = DoorOpener.FindBlockingDoor(npc, targetRoot.Position, config.AgentInfo)
						if blockingDoor then
							if data.BreaksDoors then
								if DEBUG then
									print(string.format("[%s] Door '%s' is blocking — attacking it.", npc.Name, blockingDoor:GetFullName()))
								end
								AI.Stop(npc)
								DoorOpener.AttackDoor(npc, blockingDoor, {
									AnimationName = data.DoorAttack and data.DoorAttack.AnimationName or "Punch",
									AttackSpeed   = data.DoorAttack and data.DoorAttack.AttackSpeed or 1,
									Cooldown      = data.DoorAttack and data.DoorAttack.Cooldown or 1,
									Damage        = data.DoorDamage or 10,
									AttackRange   = data.DoorAttackRange or data.AttackDistance or 5,
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
								DoorOpener.RequestOpen(npc, blockingDoor, data.DoorAttackRange or data.AttackDistance or 5)
							end
						end
					end
				end

				local dist = DistanceManager.getDistance(npc, currentTarget)

				if DEBUG_PRINT_DIST then
					print(string.format(
						"[%s] Distance to %s: %.2f | AttackRange: %.2f",
						npc.Name, currentTarget.Name, dist, data.AttackDistance
						))
				end

				local inRange = DistanceManager.isInRange(npc, currentTarget, data)
				local hasLOS  = VisionSystem.hasLineOfSight(npc, currentTarget)
				local los     = inRange and hasLOS

				local faceRange       = data.FaceTargetRange or data.AttackDistance
				local withinFaceRange = dist <= faceRange
				local faceLos         = withinFaceRange and hasLOS

				if DEBUG_PRINT_FACE then
					print(string.format(
						"[%s] dist=%.1f faceRange=%.1f within=%s hasLOS=%s faceLos=%s autoRotate=%s",
						npc.Name, dist, faceRange, tostring(withinFaceRange), tostring(hasLOS), tostring(faceLos), tostring(humanoid.AutoRotate)
						))
				end

				if faceLos then
					humanoid.AutoRotate = false
					VisionSystem.faceTarget(npc, currentTarget)
				else
					humanoid.AutoRotate = true
					VisionSystem.stopFacing(npc)
				end

				if los then
					if not isAttacking then
						AI.Stop(npc)
						isAttacking = true
						local root = npc:FindFirstChild("HumanoidRootPart")
						attackStandPos = root and root.Position or nil
					end

					rePathTimer = os.clock()
					stuck.suppress()
					pathFailCount[npc] = 0

					if attackStandPos then
						humanoid:MoveTo(attackStandPos)
					end

					CombatManager.tryAttack(npc, currentTarget, data)

				else
					-- StandStillAfter: NPC just cast an attack and is frozen in place.
					-- Suppress all movement and stuck checks for the duration.
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
						if npc:GetAttribute("CrossingDoor") then
							stuck.suppress()
							pathFailCount[npc] = 0
						elseif DoorOpener.IsBreaking(npc) then
							stuck.suppress()
						else
							stuck.update(npc)
						end

						local targetOnImpassable = stuck.isTargetOnImpassableSurface(currentTarget, config.AgentInfo.Costs)

						if not isAttacking and not DoorOpener.IsBreaking(npc) and stuck.isStuck() then
							if targetOnImpassable then
								stuck.suppress()
								if DEBUG then
									print(string.format(
										"[%s] Target is on impassable surface — suppressing stuck recovery.",
										npc.Name
										))
								end
							elseif stuck.shouldEscalateToRepath() then
								stuck.resetUnstuckAttempts()
								forceRepath()
							else
								stuck.attemptUnstuck(npc, currentTarget, AI)
							end
						else
							-- Suppress all movement logic while actively breaking a door.
							-- DoorOpener.AttackDoor manages its own MoveTo calls during this time
							-- and AI.SmartPathfind would fight them directly via Forbidden's waypoint loop.
							if DoorOpener.IsBreaking(npc) then
								stuck.suppress()
								rePathTimer = os.clock() -- reset so it doesn't immediately repath when break ends
							else
								local now = os.clock()
								local shouldRepath = isAttacking
									or (now - rePathTimer >= REPATH_INTERVAL)

								if shouldRepath then
									resetAttackState()
									rePathTimer = now
									AI.SmartPathfind(npc, currentTarget)
								end
							end
						end
					end
				end
			else
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
			lastFootstep[npc] = nil
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
