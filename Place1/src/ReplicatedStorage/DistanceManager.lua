local DistanceManager = {}

function DistanceManager.getDistance(npc, target)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return math.huge end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return math.huge end

	return (npcRoot.Position - targetRoot.Position).Magnitude
end

function DistanceManager.isInRange(npc, target, data)
	local dist = DistanceManager.getDistance(npc, target)
	if dist > data.AttackDistance then return false end

	-- mimic the LOS check with NPC/player filtering
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not npcRoot or not targetRoot then return false end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local filter = {npc}
	-- filter out all other NPCs so they don't block the check
	for _, enemy in workspace.Enemies:GetChildren() do
		table.insert(filter, enemy)
	end
	if target.Character then
		table.insert(filter, target.Character)
	end
	params.FilterDescendantsInstances = filter

	local direction = targetRoot.Position - npcRoot.Position
	local result = workspace:Raycast(npcRoot.Position, direction, params)

	-- no hit means clear LOS to target
	return result == nil
end

return DistanceManager
