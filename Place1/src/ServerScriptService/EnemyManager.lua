local rs = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local VisionSystem = require(rs.VisionSystem)
local AI = require(rs.Forbidden.AI)
local EnemyData = require(rs.EnemyData)
local TargetingManager = require(rs.TargetingManager)
local DistanceManager = require(rs.DistanceManager)
local CombatManager = require(rs.CombatManager)

local enemiesFolder = workspace:WaitForChild("Enemies")

-- ─────────────────────────────────────────────
-- DEBUG CONFIG  (flip to false before shipping)
-- ─────────────────────────────────────────────
local DEBUG = true
local DEBUG_RAY_LIFETIME = 0.15   -- seconds each debug beam stays visible
local DEBUG_PRINT_LOS    = true   -- print LOS result each tick
local DEBUG_PRINT_DIST   = true   -- print distance each tick (you already had this)

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

-- Draws a coloured line in the world for a short time so you can see the ray
local function drawDebugRay(origin, direction, color)
	if not DEBUG then return end
	local len = direction.Magnitude
	if len < 0.01 then return end

	local midpoint = origin + direction * 0.5
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Size = Vector3.new(0.05, 0.05, len)
	part.CFrame = CFrame.lookAt(midpoint, origin + direction)
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Parent = workspace

	game:GetService("Debris"):AddItem(part, DEBUG_RAY_LIFETIME)
end

--[[
	hasLineOfSight
	Returns true if there is an unobstructed straight line between the NPC
	and the target.  Ignores both the NPC model and the target's character
	so we only block on actual geometry.
]]
local function hasLineOfSight(npc, target)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return false end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return false end

	-- Ray from NPC eye height → target eye height (avoids floor false-positives)
	local eyeOffset = Vector3.new(0, 1.5, 0)
	local origin    = npcRoot.Position + eyeOffset
	local goal      = targetRoot.Position + eyeOffset
	local direction = goal - origin

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { npc, target.Character }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(origin, direction, params)

	if DEBUG then
		if result then
			-- RED  = blocked (wall/geometry in the way)
			drawDebugRay(origin, direction, Color3.fromRGB(255, 60, 60))
			if DEBUG_PRINT_LOS then
				print(string.format(
					"[%s] LOS BLOCKED by '%s' at %.2f studs (target %.2f studs away)",
					npc.Name,
					result.Instance:GetFullName(),
					(result.Position - origin).Magnitude,
					direction.Magnitude
					))
			end
		else
			-- GREEN = clear
			drawDebugRay(origin, direction, Color3.fromRGB(60, 255, 60))
			if DEBUG_PRINT_LOS then
				print(string.format(
					"[%s] LOS CLEAR to %s (%.2f studs)",
					npc.Name,
					target.Name,
					direction.Magnitude
					))
			end
		end
	end

	return result == nil  -- nil hit → nothing in the way → clear LOS
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
	config.Tracking.Enabled = true
	config.Tracking.CollinearTargetPositionOffset = 0
	config.AgentInfo.AgentRadius  = data.AgentRadius
	config.AgentInfo.AgentHeight  = data.AgentHeight
	AI.InsertAntiLag(npc)

	task.spawn(function()
		local currentTarget  = nil
		local isPathfinding  = false
		local swapTimer      = 0
		local SWAP_DELAY     = 1

		while #Players:GetPlayers() == 0 do task.wait(1) end
		task.wait(2)

		while npc.Parent ~= nil and humanoid.Health > 0 do
			task.wait(0.1)

			local newTarget = TargetingManager.getTarget(npc, data)

			-- target-swap debounce
			if newTarget ~= currentTarget then
				if newTarget == nil or os.clock() - swapTimer >= SWAP_DELAY then
					currentTarget = newTarget
					swapTimer     = os.clock()
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

				if DEBUG_PRINT_DIST then
					print(string.format(
						"[%s] Distance to %s: %.2f | AttackRange: %.2f",
						npc.Name, currentTarget.Name, dist, data.AttackDistance
						))
				end

				local inRange = DistanceManager.isInRange(npc, currentTarget, data)

				-- ── KEY FIX ──────────────────────────────────────────────────────
				-- Only stop pathfinding and stand still when BOTH conditions are met:
				--   1. Close enough (straight-line distance ≤ AttackDistance)
				--   2. Unobstructed line of sight (no wall/door frame in the way)
				--
				-- If the player is "close" but behind geometry the NPC keeps
				-- pathfinding around the obstacle instead of freezing at the doorway.
				-- ─────────────────────────────────────────────────────────────────
				local los = inRange and hasLineOfSight(npc, currentTarget)

				if los then
					-- Can see AND reach the target — attack!
					if isPathfinding then
						AI.Stop(npc)
						isPathfinding = false
					end
					local npcRoot = npc:FindFirstChild("HumanoidRootPart")
					if npcRoot then
						humanoid:MoveTo(npcRoot.Position)
					end
					VisionSystem.faceTarget(npc, currentTarget)
					CombatManager.tryAttack(npc, currentTarget, data)

				else
					-- Either out of range OR blocked by geometry → keep pathfinding
					VisionSystem.stopFacing(npc)
					if not isPathfinding then
						AI.SmartPathfind(npc, currentTarget)
						isPathfinding = true
						if DEBUG then
							print(string.format(
								"[%s] Resuming pathfind — inRange=%s los=%s dist=%.2f",
								npc.Name,
								tostring(inRange),
								tostring(los),
								dist
								))
						end
					end
				end
			end
		end

		AI.Stop(npc)
		CombatManager.cleanup(npc)
	end)
end

for _, npc in enemiesFolder:GetChildren() do
	setupEnemy(npc)
end

enemiesFolder.ChildAdded:Connect(function(npc)
	task.wait()
	setupEnemy(npc)
end)
