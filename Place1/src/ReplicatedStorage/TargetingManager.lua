local TargetingManager = {}

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local StuckRecovery = require(game.ReplicatedStorage.StuckRecovery)()

-- Cache: [npc][player] = { result = bool, time = os.clock() }
local reachabilityCache = {}
local REACHABILITY_CACHE_TIME = 3 -- seconds before re-checking the same npc/player pair

local function isTargetReachable(npc, char, agentInfo)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	local targetRoot = char:FindFirstChild("HumanoidRootPart")
	if not npcRoot or not targetRoot then return false end

	reachabilityCache[npc] = reachabilityCache[npc] or {}
	local cached = reachabilityCache[npc][char]
	if cached and os.clock() - cached.time < REACHABILITY_CACHE_TIME then
		return cached.result
	end

	local path = PathfindingService:CreatePath(agentInfo)
	local ok = pcall(function()
		path:ComputeAsync(npcRoot.Position, targetRoot.Position)
	end)

	local result = ok and path.Status == Enum.PathStatus.Success
	reachabilityCache[npc][char] = { result = result, time = os.clock() }
	return result
end

function TargetingManager.clearReachabilityCache(npc)
	reachabilityCache[npc] = nil
end

-- overrideAgentCosts (optional): pass config.AgentInfo.Costs to make this
-- NPC skip past players standing on terrain that's impassable for it,
-- instead of fixating on an unreachable target.
-- overrideAgentInfo (optional): pass config.AgentInfo (the full table, not
-- just Costs) to enable a real pathfind reachability check on top of the
-- cheap impassable-tile check. Skipped entirely if nil.
-- guaranteedEngageRange (optional): typically data.AttackDistance. A
-- candidate already within this distance doesn't need a walkable path to be
-- engageable at all -- attacking doesn't require pathfinding (see
-- EnemyManager.tryAttack / CombatManager). Without this bypass, an NPC
-- standing near but not navmesh-reachable (elevated ledge, thin gap, across
-- a barrier, etc.) would never even be OFFERED as a target despite being
-- fully attackable right now, since the reachability/impassable checks
-- below would always reject it first.
function TargetingManager.getTarget(npc, data, overrideRange, overrideHeightLimit, overrideAgentCosts, overrideAgentInfo, guaranteedEngageRange)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return nil end

	local searchRange = overrideRange or data.DetectionRange
	local heightLimit = overrideHeightLimit or data.DetectionHeightLimit
	local agentCosts  = overrideAgentCosts
	local agentInfo   = overrideAgentInfo

	local candidates = {}

	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then continue end
		local root = char:FindFirstChild("HumanoidRootPart")
		if not root then continue end
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then continue end

		if heightLimit then
			local heightDiff = math.abs(root.Position.Y - npcRoot.Position.Y)
			if heightDiff > heightLimit then continue end
		end

		local horizontalDist = Vector3.new(
			root.Position.X - npcRoot.Position.X,
			0,
			root.Position.Z - npcRoot.Position.Z
		).Magnitude

		if horizontalDist < searchRange then
			table.insert(candidates, { player = player, dist = horizontalDist, root = root, char = char })
		end
	end

	table.sort(candidates, function(a, b) return a.dist < b.dist end)

	for _, candidate in ipairs(candidates) do
		local guaranteedEngage = guaranteedEngageRange and candidate.dist <= guaranteedEngageRange

		if not guaranteedEngage and agentCosts and StuckRecovery.isPositionOnImpassableSurface(candidate.root.Position, agentCosts, { candidate.char }) then
			continue -- cheap check: skip lava/impassable-tile standers
		end

		if not guaranteedEngage and agentInfo and not isTargetReachable(npc, candidate.char, agentInfo) then
			continue -- expensive check: skip actually-unreachable candidates (cached)
		end

		return candidate.player
	end

	return nil
end

return TargetingManager
