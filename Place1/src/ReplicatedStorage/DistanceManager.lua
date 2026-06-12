local DistanceManager = {}

function DistanceManager.getDistance(npc, target)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return math.huge end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return math.huge end

	return (npcRoot.Position - targetRoot.Position).Magnitude
end

function DistanceManager.isInRange(npc, target, data) --will bypass all things to hit the target for now
    local dist = DistanceManager.getDistance(npc, target)
    return dist <= data.AttackDistance
end

return DistanceManager
