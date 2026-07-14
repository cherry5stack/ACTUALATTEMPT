local TargetingManager = {}

local Players = game:GetService("Players")
local StuckRecovery = require(game.ReplicatedStorage.StuckRecovery)() -- adjust path to match your project

-- overrideAgentCosts (optional): pass config.AgentInfo.Costs to make this
-- NPC skip past players standing on terrain that's impassable for it,
-- instead of fixating on an unreachable target.
function TargetingManager.getTarget(npc, data, overrideRange, overrideHeightLimit, overrideAgentCosts)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return nil end

	local searchRange = overrideRange or data.DetectionRange
	local heightLimit = overrideHeightLimit or data.DetectionHeightLimit -- nil = no height restriction
	local agentCosts  = overrideAgentCosts -- nil = skip reachability check entirely

	-- Collect all valid, in-range candidates sorted by distance, so we can
	-- fall through to the next-closest reachable player instead of just
	-- rejecting the single closest one and returning nil.
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
		if not agentCosts
			or not StuckRecovery.isPositionOnImpassableSurface(candidate.root.Position, agentCosts, { candidate.char }) then
			return candidate.player
		end
	end

	return nil
end

return TargetingManager
