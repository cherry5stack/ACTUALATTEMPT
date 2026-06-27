local VisionSystem = {}
local RunService = game:GetService("RunService")
local activeFaceData: {[Model]: {target: any, connection: RBXScriptConnection}} = {}

local RESPONSIVENESS = 2500 -- higher = snappier turning, tune by feel (try 5-12)
-- ─────────────────────────────────────────────
-- DEBUG CONFIG
-- ─────────────────────────────────────────────
local DEBUG              = false
local DEBUG_RAY_LIFETIME = 0.15
local DEBUG_PRINT_LOS    = false

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
	params.FilterType = Enum.RaycastFilterType.Exclude

	local filterList = { npc, targetChar }
	local Players = game:GetService("Players")
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(filterList, player.Character)
		end
	end
	params.FilterDescendantsInstances = filterList

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

function VisionSystem.faceTarget(npc: Model, target: Player)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	if activeFaceData[npc] then
		activeFaceData[npc].target = target
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "FaceTargetAttachment"
	attachment.Parent = npcRoot

	local align = Instance.new("AlignOrientation")
	align.Name = "FaceTargetAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	
	align.Responsiveness = RESPONSIVENESS
	--align.Responsiveness = lerp(maxResp, minResp, dist / faceRange)
	--this line is to turn speed to scale with distance (e.g. snap faster when close, slower when far) is needed
	
	align.MaxTorque = math.huge
	align.MaxAngularVelocity = math.huge
	align.Parent = npcRoot

	local data = {target = target, align = align, connection = nil}
	activeFaceData[npc] = data

	data.connection = RunService.Heartbeat:Connect(function()
		local root = npc:FindFirstChild("HumanoidRootPart")
		local targetChar = data.target and data.target.Character
		local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
		if not root or not targetRoot then return end

		local direction = targetRoot.Position - root.Position
		local flat = Vector3.new(direction.X, 0, direction.Z)
		if flat.Magnitude < 0.1 then return end

		-- AlignOrientation.CFrame is the GOAL orientation in world space
		align.CFrame = CFrame.lookAt(Vector3.new(), flat.Unit)
	end)
end

function VisionSystem.stopFacing(npc: Model)
	local data = activeFaceData[npc]
	if data then
		if data.connection then data.connection:Disconnect() end
		if data.align then data.align:Destroy() end
		activeFaceData[npc] = nil
	end
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if npcRoot then
		local attachment = npcRoot:FindFirstChild("FaceTargetAttachment")
		if attachment then attachment:Destroy() end
	end
end
return VisionSystem
