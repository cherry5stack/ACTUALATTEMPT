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
	task.spawn(function()
		local currentTarget = nil

		-- wait for at least one player
		while #Players:GetPlayers() == 0 do task.wait(1) end
		task.wait(2)

		while npc.Parent ~= nil and humanoid.Health > 0 do
			task.wait(0.1)

			local newTarget = TargetingManager.getTarget(npc, data)

			-- target changed, update pathfinding
			if newTarget ~= currentTarget then
				currentTarget = newTarget
				if currentTarget then
					AI.SmartPathfind(npc, currentTarget)
				else
					AI.Stop(npc)
				end
			end

			if currentTarget then
				local dist = DistanceManager.getDistance(npc, currentTarget)
				print(string.format("[%s] Distance to %s: %.2f | AttackRange: %.2f", npc.Name, currentTarget.Name, dist, data.AttackDistance))

				if DistanceManager.isInRange(npc, currentTarget, data) then
					AI.Stop(npc)
					VisionSystem.faceTarget(npc, currentTarget) -- face the player while attacking
					CombatManager.tryAttack(npc, currentTarget, data)
				else
					VisionSystem.stopFacing(npc) -- stop forcing rotation when chasing
					AI.SmartPathfind(npc, currentTarget)
				end
			end
		end

		-- cleanup when dead
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
