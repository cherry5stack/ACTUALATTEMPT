local DistanceManager = {}

--function DistanceManager.getDistance(npc, target)
--	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
--	if not npcRoot then return math.huge end

--	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
--	if not targetRoot then return math.huge end

--	local npcPos    = npcRoot.Position
--	local targetPos = targetRoot.Position

--	-- ignore Y axis so jumping doesn't affect distance check
--	return Vector3.new(
--		npcPos.X - targetPos.X,
--		0,
--		npcPos.Z - targetPos.Z
--	).Magnitude
--end


function DistanceManager.getDistance(npc, target)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return math.huge end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return math.huge end

	-- use full 3D distance instead of horizontal-only
	return (npcRoot.Position - targetRoot.Position).Magnitude
end


function DistanceManager.isInAttackBubble(npc, target, data)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not npcRoot or not targetRoot then return false end

	local horizontalDist = Vector3.new(
		npcRoot.Position.X - targetRoot.Position.X, 0,
		npcRoot.Position.Z - targetRoot.Position.Z
	).Magnitude
	local heightDiff = math.abs(npcRoot.Position.Y - targetRoot.Position.Y)

	if horizontalDist > (data.AttackDistance or 5) then return false end
	if data.AttackHeight and heightDiff > data.AttackHeight then return false end
	return true
end

function DistanceManager.isAtComfortDistance(npc, target, data)
	local dist = DistanceManager.getDistance(npc, target) -- existing full-3D
	return dist <= (data.ComfortDistance or data.AttackDistance or 5)
end


function DistanceManager.isInRange(npc, target, data)
	local dist = DistanceManager.getDistance(npc, target)
	return dist <= data.AttackDistance
end

return DistanceManager
