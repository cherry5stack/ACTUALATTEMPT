local DistanceManager = {}

function DistanceManager.getDistance(npc, target)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return math.huge end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return math.huge end

	local npcPos    = npcRoot.Position
	local targetPos = targetRoot.Position

	-- ignore Y axis so jumping doesn't affect distance check
	return Vector3.new(
		npcPos.X - targetPos.X,
		0,
		npcPos.Z - targetPos.Z
	).Magnitude
end

function DistanceManager.isInRange(npc, target, data)
	local dist = DistanceManager.getDistance(npc, target)
	return dist <= data.AttackDistance
end

return DistanceManager
