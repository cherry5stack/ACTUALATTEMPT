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

local enemiesFolder = workspace:WaitForChild("Enemies")

local DEBUG              = false
local DEBUG_PRINT_DIST   = false
local DEBUG_PRINT_GROUND = false

local REPATH_INTERVAL    = 0.5
local lastFootstep       = {}

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

	CombatManager.registerSpawnTime(npc) -- NEW: starts the unlock timer right here, at setup

	humanoid.MaxHealth = data.Health
	humanoid.Health    = data.Health
	humanoid.WalkSpeed = data.WalkSpeed


	local config = AI.GetConfig(npc)
	config.Tracking.Enabled                      = true
	config.Tracking.CollinearTargetPositionOffset = 0
	config.AgentInfo.AgentRadius                 = data.AgentRadius
	config.AgentInfo.AgentHeight                 = data.AgentHeight
	config.AgentInfo.Costs                       = data.AgentCosts or { Obstacle = math.huge }
	config.DirectMoveTo.Enabled                  = false

	config.Hooks.PathingFailed = function(npc, reason)
		if DEBUG then
			print(string.format("[%s] Pathing failed — %s", npc.Name, reason))
		end
	end

	AI.InsertAntiLag(npc)

	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if npcRoot then
		SoundManager.play(data.Sounds and data.Sounds.Spawn, npcRoot.Position)
	end

	humanoid.Died:Connect(function()
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			SoundManager.play(data.Sounds and data.Sounds.Death, root.Position)
		end
		lastFootstep[npc] = nil
		-- Clean up AI and combat state immediately on death
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
		local currentTarget  = nil
		local isAttacking    = false
		local attackStandPos = nil
		local swapTimer      = 0
		local rePathTimer    = 0
		local SWAP_DELAY     = 1

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
				if DEBUG then
					print(string.format("[%s] STUCK RECOVERY — forced Stop + SmartPathfind", npc.Name))
				end
			end
			stuck.reset(npc)
		end

		while #Players:GetPlayers() == 0 do task.wait(1) end
		task.wait(2)

		stuck.reset(npc)

		while npc.Parent ~= nil and humanoid.Health > 0 do
			task.wait(0.1)

			-- Race condition guard: recheck health after the yield
			if humanoid.Health <= 0 then break end

			debugGroundCheck(npc, config.AgentInfo.Costs)

			local newTarget = TargetingManager.getTarget(npc, data)

			if newTarget ~= currentTarget then
				if newTarget == nil or os.clock() - swapTimer >= SWAP_DELAY then
					currentTarget = newTarget
					swapTimer     = os.clock()
					rePathTimer   = 0
					resetAttackState()
					stuck.reset(npc)

					if currentTarget then
						AI.SmartPathfind(npc, currentTarget)
					else
						AI.Stop(npc)
						VisionSystem.stopFacing(npc)
					end
				end
			end

			if currentTarget then
				local dist = DistanceManager.getDistance(npc, currentTarget)

				if DEBUG_PRINT_DIST then
					print(string.format(
						"[%s] Distance to %s: %.2f | AttackRange: %.2f",
						npc.Name, currentTarget.Name, dist, data.AttackDistance
						))
				end

				local inRange = DistanceManager.isInRange(npc, currentTarget, data)
				local los     = inRange and VisionSystem.hasLineOfSight(npc, currentTarget)

				if los then
					if not isAttacking then
						AI.Stop(npc)
						isAttacking = true
						local root = npc:FindFirstChild("HumanoidRootPart")
						attackStandPos = root and root.Position or nil
					end

					rePathTimer = os.clock()
					stuck.suppress()

					if attackStandPos then
						humanoid:MoveTo(attackStandPos)
					end

					VisionSystem.faceTarget(npc, currentTarget)
					CombatManager.tryAttack(npc, currentTarget, data)
				else
					VisionSystem.stopFacing(npc)
					stuck.update(npc)

					if not isAttacking and stuck.isStuck() then
						forceRepath()
					else
						local now = os.clock()
						local shouldRepath = isAttacking
							or (now - rePathTimer >= REPATH_INTERVAL)

						if shouldRepath then
							resetAttackState()
							rePathTimer = now
							AI.SmartPathfind(npc, currentTarget)

							if DEBUG then
								print(string.format(
									"[%s] Resuming pathfind — inRange=%s los=%s dist=%.2f",
									npc.Name, tostring(inRange), tostring(los), dist
									))
							end
						end
					end
				end
			end
		end

		-- Loop exited cleanly (health hit 0 or npc removed)
		-- Died handler covers the humanoid.Died case,
		-- but if npc.Parent became nil we still need cleanup here
		if npc.Parent == nil then
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
