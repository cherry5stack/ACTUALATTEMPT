local rs = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")


local VisionSystem = require(rs.VisionSystem)
local AI = require(rs.Forbidden.AI)
local EnemyData = require(rs.EnemyData)
local TargetingManager = require(rs.TargetingManager)
local DistanceManager = require(rs.DistanceManager)
local CombatManager = require(rs.CombatManager)

local enemiesFolder = workspace:WaitForChild("Enemies")

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

	-- apply stats
	humanoid.MaxHealth = data.Health
	humanoid.Health = data.Health
	humanoid.WalkSpeed = data.WalkSpeed

	-- setup AI
	local config = AI.GetConfig(npc)
	config.Tracking.Enabled = true
	config.Tracking.CollinearTargetPositionOffset = 0
	config.AgentInfo.AgentRadius = data.AgentRadius
	config.AgentInfo.AgentHeight = data.AgentHeight
	AI.InsertAntiLag(npc)

	-- run enemy loop in its own thread
	-- replace your current loop with this
	-- replace your current loop with this
	task.spawn(function()
		local currentTarget = nil
		local isPathfinding = false
		local swapTimer = 0
		local SWAP_DELAY = 1

		while #Players:GetPlayers() == 0 do task.wait(1) end
		task.wait(2)

		while npc.Parent ~= nil and humanoid.Health > 0 do
			task.wait(0.1)

			local newTarget = TargetingManager.getTarget(npc, data)

			-- mimic SwapTargetTimer, don't instantly swap
			if newTarget ~= currentTarget then
				if newTarget == nil or os.clock() - swapTimer >= SWAP_DELAY then
					currentTarget = newTarget
					swapTimer = os.clock()
					isPathfinding = false
					if currentTarget then
						AI.SmartPathfind(npc, currentTarget)
						isPathfinding = true
					else
						AI.Stop(npc)
					end
				end
			end

			if currentTarget then
				local dist = DistanceManager.getDistance(npc, currentTarget)
				print(string.format("[%s] Distance to %s: %.2f | AttackRange: %.2f",
					npc.Name, currentTarget.Name, dist, data.AttackDistance))

				if DistanceManager.isInRange(npc, currentTarget, data) then
					if isPathfinding then
						AI.Stop(npc)
						isPathfinding = false
					end
					-- call this every tick, not just on transition
					humanoid:Move(Vector3.zero, false)
					VisionSystem.faceTarget(npc, currentTarget)
					CombatManager.tryAttack(npc, currentTarget, data)
				else
					VisionSystem.stopFacing(npc)
					if not isPathfinding then
						AI.SmartPathfind(npc, currentTarget)
						isPathfinding = true
					end
				end
			end
		end

		AI.Stop(npc)
		CombatManager.cleanup(npc)
	end)
end

-- setup all existing enemies
for _, npc in enemiesFolder:GetChildren() do
	setupEnemy(npc)
end

-- setup enemies added later
enemiesFolder.ChildAdded:Connect(function(npc)
	task.wait()
	setupEnemy(npc)
end)
