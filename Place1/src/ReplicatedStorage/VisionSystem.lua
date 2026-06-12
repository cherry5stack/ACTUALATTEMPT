local VisionSystem = {}

function VisionSystem.faceTarget(npc, target)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end

	local direction = (targetRoot.Position - npcRoot.Position)
	local lookVector = Vector3.new(direction.X, 0, direction.Z).Unit
	if lookVector.Magnitude < 0.1 then return end

	local bodyGyro = npcRoot:FindFirstChild("FaceTargetGyro")
	if not bodyGyro then
		bodyGyro = Instance.new("BodyGyro")
		bodyGyro.Name = "FaceTargetGyro"
		bodyGyro.P = 8000
		bodyGyro.D = 400
		bodyGyro.MaxTorque = Vector3.new(0, 100000, 0)
		bodyGyro.Parent = npcRoot
	end

	bodyGyro.CFrame = CFrame.lookAt(npcRoot.Position, npcRoot.Position + lookVector)
end

function VisionSystem.stopFacing(npc)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end
	local bodyGyro = npcRoot:FindFirstChild("FaceTargetGyro")
	if bodyGyro then bodyGyro:Destroy() end
end

return VisionSystem