local TargetingManager = {}

local Players = game:GetService("Players")

function TargetingManager.getTarget(npc, data, overrideRange, overrideHeightLimit)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return nil end

	local searchRange = overrideRange or data.DetectionRange
	local heightLimit = overrideHeightLimit or data.DetectionHeightLimit -- nil = no height restriction

	local closest, closestDist = nil, math.huge

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

		if horizontalDist < closestDist and horizontalDist < searchRange then
			closest = player
			closestDist = horizontalDist
		end
	end

	return closest
end

return TargetingManager
