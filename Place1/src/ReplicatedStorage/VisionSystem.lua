local VisionSystem = {}

-- ─────────────────────────────────────────────
-- DEBUG CONFIG
-- ─────────────────────────────────────────────
local DEBUG              = true
local DEBUG_RAY_LIFETIME = 0.15
local DEBUG_PRINT_LOS    = true

-- ─────────────────────────────────────────────
-- Internal helpers
-- ─────────────────────────────────────────────

local function drawDebugRay(origin, direction, color)
	if not DEBUG then return end
	local len = direction.Magnitude
	if len < 0.01 then return end
	local midpoint = origin + direction * 0.5
	local part = Instance.new("Part")
	part.Anchored    = true
	part.CanCollide  = false
	part.CanQuery    = false
	part.CastShadow  = false
	part.Size        = Vector3.new(0.05, 0.05, len)
	part.CFrame      = CFrame.lookAt(midpoint, origin + direction)
	part.Color       = color
	part.Material    = Enum.Material.Neon
	part.Parent      = workspace
	game:GetService("Debris"):AddItem(part, DEBUG_RAY_LIFETIME)
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function VisionSystem.hasLineOfSight(npc, target)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return false end

	local targetChar = target.Character
	if not targetChar then return false end

	local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return false end

	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { npc, targetChar }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local npcEye = npcRoot.Position + Vector3.new(0, 1.5, 0)

	local targetPoints = {
		targetRoot.Position + Vector3.new(0, 1.5, 0), -- head
		targetRoot.Position,                            -- torso
		targetRoot.Position + Vector3.new(0, -2, 0),  -- legs
	}

	local hasLOS = false

	for _, point in targetPoints do
		local direction = point - npcEye
		local result = workspace:Raycast(npcEye, direction, params)

		if result == nil then
			-- clear
			drawDebugRay(npcEye, direction, Color3.fromRGB(60, 255, 60))
			hasLOS = true
		else
			-- blocked
			drawDebugRay(npcEye, direction, Color3.fromRGB(255, 60, 60))
			if DEBUG_PRINT_LOS then
				print(string.format(
					"[%s] LOS BLOCKED by '%s' at %.2f studs (target %.2f studs away)",
					npc.Name, result.Instance:GetFullName(),
					(result.Position - npcEye).Magnitude, direction.Magnitude
					))
			end
		end
	end

	if DEBUG_PRINT_LOS and hasLOS then
		local npcRoot2 = npc:FindFirstChild("HumanoidRootPart")
		print(string.format(
			"[%s] LOS CLEAR to %s",
			npc.Name, target.Name
			))
	end

	return hasLOS
end

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
