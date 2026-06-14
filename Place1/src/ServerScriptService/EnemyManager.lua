local rs = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local VisionSystem     = require(rs.VisionSystem)
local AI               = require(rs.Forbidden.AI)
local EnemyData        = require(rs.EnemyData)
local TargetingManager = require(rs.TargetingManager)
local DistanceManager  = require(rs.DistanceManager)
local CombatManager    = require(rs.CombatManager)
local StuckRecovery    = require(rs.StuckRecovery)

local enemiesFolder = workspace:WaitForChild("Enemies")

-- ─────────────────────────────────────────────
-- DEBUG CONFIG  (flip to false before shipping)
-- ─────────────────────────────────────────────
local DEBUG              = true
local DEBUG_PRINT_DIST   = true
local DEBUG_PRINT_GROUND = true

local REPATH_INTERVAL    = 0.5

-- ─────────────────────────────────────────────
-- Debug helpers
-- ─────────────────────────────────────────────

local function debugGroundCheck(npc, agentCosts)
	if not DEBUG_PRINT_GROUND then return end

	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { npc }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(
		npcRoot.Position,
		Vector3.new(0, -5, 0),
		params
	)

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

-- ─────────────────────────────────────────────
-- Main setup
-- ─────────────────────────────────────────────

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

	humanoid.MaxHealth = data.Health
	humanoid.Health    = data.Health
	humanoid.WalkSpeed = data.WalkSpeed

	local config = AI.GetConfig(npc)
	config.Tracking.Enabled                     = true
	config.Tracking.CollinearTargetPositionOffset = 0
	config.AgentInfo.AgentRadius                = data.AgentRadius
	config.AgentInfo.AgentHeight                = data.AgentHeight
	config.AgentInfo.Costs                      = data.AgentCosts or { Obstacle = math.huge }
	config.DirectMoveTo.Enabled                 = false
	
	--if cant reach target..
	config.Hooks.PathingFailed = function(npc, reason)
		if DEBUG then
			print(string.format("[%s] Pathing failed — %s", npc.Name, reason))
		end
		-- future: set noPathFlag = true to pause stuck recovery spam
	end
	
	AI.InsertAntiLag(npc)

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
			if currentTarget then
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

			debugGroundCheck(npc, config.AgentInfo.Costs)

			local newTarget = TargetingManager.getTarget(npc, data)

			-- Target-swap debounce
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
					-- ── Clear LOS + in range → attack ────────────────────────────
					if not isAttacking then
						AI.Stop(npc)
						isAttacking = true
						local npcRoot = npc:FindFirstChild("HumanoidRootPart")
						attackStandPos = npcRoot and npcRoot.Position or nil
					end

					rePathTimer = os.clock()
					stuck.suppress()

					if attackStandPos then
						humanoid:MoveTo(attackStandPos)
					end

					VisionSystem.faceTarget(npc, currentTarget)
					CombatManager.tryAttack(npc, currentTarget, data)

				else
					-- ── Out of range OR LOS blocked → pathfind ───────────────────
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

		AI.Stop(npc)
		CombatManager.cleanup(npc)
		VisionSystem.stopFacing(npc)
	end)
end

for _, npc in enemiesFolder:GetChildren() do
	setupEnemy(npc)
end

enemiesFolder.ChildAdded:Connect(function(npc)
	task.wait()
	setupEnemy(npc)
end)
