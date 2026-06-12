local TargetingManager = {}

local Players = game:GetService("Players")

function TargetingManager.getTarget(npc, data)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return nil end

	local closest, closestDist = nil, math.huge

	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then continue end
		local root = char:FindFirstChild("HumanoidRootPart")
		if not root then continue end
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then continue end

		local dist = (root.Position - npcRoot.Position).Magnitude
		if dist < closestDist and dist < data.DetectionRange then
			closest = player
			closestDist = dist
		end
	end

	return closest
end

return TargetingManager