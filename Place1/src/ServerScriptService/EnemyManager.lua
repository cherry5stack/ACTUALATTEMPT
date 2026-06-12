-- EnemyManager Script in ServerScriptService

local rs = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local AI = require(rs.Forbidden.AI)
local EnemyData = require(rs.EnemyData)

local enemiesFolder = workspace:WaitForChild("Enemies") -- put all your NPCs in a folder

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
	config.AgentInfo.AgentRadius = data.AgentRadius
	config.AgentInfo.AgentHeight = data.AgentHeight
	AI.InsertAntiLag(npc)

	-- run this enemy in its own thread so it doesnt block others
	task.spawn(function()
		local lastAttack = 0
		local currentTarget = nil

		local function getClosestPlayer()
			local npcRoot = npc:FindFirstChild("HumanoidRootPart")
			if not npcRoot then return nil end

			local closest, closestDist = nil, math.huge
			for _, player in Players:GetPlayers() do
				local char = player.Character
				if not char then continue end
				local root = char:FindFirstChild("HumanoidRootPart")
				if not root then continue end
				local dist = (root.Position - npcRoot.Position).Magnitude
				if dist < closestDist and dist < data.DetectionRange then
					closest = player
					closestDist = dist
				end
			end
			return closest
		end

		local function tryAttack(target)
			local npcRoot = npc:FindFirstChild("HumanoidRootPart")
			if not npcRoot then return end
			local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			if not targetRoot then return end

			local dist = (npcRoot.Position - targetRoot.Position).Magnitude
			if dist <= data.AttackDistance and os.clock() - lastAttack >= data.AttackCooldown then
				lastAttack = os.clock()

				local params = OverlapParams.new()
				params.FilterDescendantsInstances = {npc}
				params.FilterType = Enum.RaycastFilterType.Exclude

				local hits = workspace:GetPartBoundsInBox(
					npcRoot.CFrame,
					data.AttackHitboxSize,
					params
				)

				local alreadyHit = {} -- track who we already damaged this attack

				for _, hit in hits do
					local character = hit.Parent
					local hitHumanoid = character:FindFirstChildOfClass("Humanoid")

					-- only damage each character once per attack
					if hitHumanoid and character ~= npc and not alreadyHit[character] then
						alreadyHit[character] = true
						hitHumanoid:TakeDamage(data.Damage)
						print("Hit: " .. character.Name .. " for " .. data.Damage .. " damage")
					end
				end
			end
		end

		-- wait until at least one player is in
		while #Players:GetPlayers() == 0 do task.wait(1) end
		task.wait(2) -- give characters time to load

		while npc.Parent ~= nil and humanoid.Health > 0 do
			task.wait(0.1)

			local newTarget = getClosestPlayer()
			if newTarget ~= currentTarget then
				currentTarget = newTarget
				if currentTarget then
					AI.SmartPathfind(npc, currentTarget)
				else
					AI.Stop(npc)
				end
			end
			if currentTarget then

				tryAttack(currentTarget)
			end
		end

		-- cleanup when dead
		AI.Stop(npc)
	end)
end

-- setup all existing enemies
for _, npc in enemiesFolder:GetChildren() do
	setupEnemy(npc)
end

-- setup any enemies added later (for spawning systems)
enemiesFolder.ChildAdded:Connect(function(npc)
	task.wait() -- wait a frame for the model to fully load
	setupEnemy(npc)
end)