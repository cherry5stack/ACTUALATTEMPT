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

-- Tracks consecutive path failures per NPC so we know when to try door opening
local pathFailCount = {}

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

-- Raycasts from NPC toward target and walks up the hit instance's ancestry
-- looking for a door with an Open BoolValue. If found and closed, opens it.
-- Returns true if a door was found and opened.
local function tryOpenBlockingDoor(npc, target)
	if not target or not target.Character then return false end

	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	local targetRoot = target.Character:FindFirstChild("HumanoidRootPart")
	if not npcRoot or not targetRoot then return false end

	local origin    = npcRoot.Position + Vector3.new(0, 1, 0) -- slight upward offset so we don't hit the floor
	local direction = targetRoot.Position - origin

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { npc, target.Character }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(origin, direction, params)
	if not result then return false end

	-- Walk up ancestry up to 5 levels looking for a door Open value
	local inst = result.Instance
	for _ = 1, 5 do
		if not inst then break end

		-- Pattern 1: Open BoolValue directly on this instance
		local openVal = inst:FindFirstChild("Open")
		if openVal and openVal:IsA("BoolValue") and openVal.Value == false then
			if DEBUG then
				print(string.format("[%s] tryOpenBlockingDoor: opening door via direct Open on '%s'", npc.Name, inst:GetFullName()))
			end
			openVal.Value = true
			return true
		end

		-- Pattern 2: Door script child containing Open (matches your DoorOpener structure)
		local doorScript = inst:FindFirstChild("Door")
		if doorScript then
			local openVal2 = doorScript:FindFirstChild("Open")
			if openVal2 and openVal2:IsA("BoolValue") and openVal2.Value == false then
				if DEBUG then
					print(string.format("[%s] tryOpenBlockingDoor: opening door via Door.Open on '%s'", npc.Name, inst:GetFullName()))
				end
				openVal2.Value = true
				return true
			end
		end

		inst = inst.Parent
	end

	return false
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

			-- Count consecutive failures so the door opener knows when to kick in
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
	config.AgentInfo.Costs                        = data.AgentCosts or { Obstacle = math.huge }
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
		local lastDoorOpenAttempt = 0
		-- How many consecutive path failures before we try the door raycast.
		-- 3 is enough to avoid false-positives from momentary map jitter.
		local DOOR_OPEN_FAIL_THRESHOLD = 3
		-- Cooldown so we don't hammer the door open logic every tick.
		local DOOR_OPEN_COOLDOWN = 2

		local stuck = StuckRecovery()

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
					pathFailCount[npc] = 0 -- reset failure counter on target change

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
					pathFailCount[npc] = 0 -- in range and has LOS, path is clearly fine

					if attackStandPos then
						humanoid:MoveTo(attackStandPos)
					end

					CombatManager.tryAttack(npc, currentTarget, data)
				else
					stuck.update(npc)

					-- Check if we've been failing to path long enough that a door
					-- is probably the culprit, and try to open it proactively.
					local failures = pathFailCount[npc] or 0
					local now      = os.clock()
					if failures >= DOOR_OPEN_FAIL_THRESHOLD
						and now - lastDoorOpenAttempt >= DOOR_OPEN_COOLDOWN
					then
						lastDoorOpenAttempt = now
						local opened = tryOpenBlockingDoor(npc, currentTarget)
						if opened then
							if DEBUG then
								print(string.format("[%s] Proactively opened blocking door, repathing.", npc.Name))
							end
							pathFailCount[npc] = 0
							-- Give the door a moment to physically open before repathing
							task.delay(0.5, function()
								if currentTarget and humanoid.Health > 0 then
									AI.Stop(npc)
									AI.SmartPathfind(npc, currentTarget)
									rePathTimer = os.clock()
								end
							end)
						end
					end

					if not isAttacking and stuck.isStuck() then
						if stuck.shouldEscalateToRepath() then
							stuck.resetUnstuckAttempts()
							forceRepath()
						else
							stuck.attemptUnstuck(npc, currentTarget, AI)
						end
					else
						local shouldRepath = isAttacking
							or (now - rePathTimer >= REPATH_INTERVAL)

						if shouldRepath then
							resetAttackState()
							rePathTimer = now
							AI.SmartPathfind(npc, currentTarget)
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
