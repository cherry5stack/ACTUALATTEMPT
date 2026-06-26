local DoorOpener = {}
local CollectionService = game:GetService("CollectionService")

local DOOR_TAG = "Door"
local OPEN_WAIT = 0.5 

local DEBUG = true

local function dbg(npcName: string, msg: string)
	if DEBUG then print(string.format("[DoorOpener][%s] %s", npcName, msg)) end
end

local function warn_dbg(npcName: string, msg: string)
	if DEBUG then warn(string.format("[DoorOpener][%s] %s", npcName, msg)) end
end

function DoorOpener.findNearestDoor(position: Vector3): Model?
	local best, bestDist = nil, math.huge
	for _, doorModel in ipairs(CollectionService:GetTagged(DOOR_TAG)) do
		if doorModel:IsA("Model") then
			local cf = doorModel:GetPivot()
			local dist = (cf.Position - position).Magnitude
			if dist < bestDist then
				bestDist = dist
				best = doorModel
			end
		end
	end
	return best
end

local function monitorPassthrough(NPC: Instance, doorModel: Model)
	local openValue = doorModel:FindFirstChild("Open")
	if not openValue then return end

	if NPC:GetAttribute("CrossingDoor") then return end
	NPC:SetAttribute("CrossingDoor", true)

	task.spawn(function()
		local root = NPC:FindFirstChild("HumanoidRootPart")
		if not root then NPC:SetAttribute("CrossingDoor", nil) return end

		local npcName   = NPC.Name
		local deadline  = os.clock() + 4.0 

		while os.clock() < deadline do
			task.wait(0.1)

			if not NPC.Parent or not root or not root.Parent then break end

			-- Abort pathing wait instantly if someone slams it shut
			if openValue.Value == false then
				warn_dbg(npcName, "Door closed during transit. Aborting.")
				break
			end

			local distFromDoor = (doorModel:GetPivot().Position - root.Position).Magnitude
			if distFromDoor > 7.5 then break end
		end

		NPC:SetAttribute("CrossingDoor", nil)

		local human = NPC:FindFirstChildOfClass("Humanoid")
		if human and root and NPC.Parent then
			human:MoveTo(root.Position)
		end
	end)
end

function DoorOpener.onPathfindingLinkReached(NPC: Instance, Waypoint: PathWaypoint): boolean
	if not Waypoint.Label or not string.find(string.lower(Waypoint.Label), "door") then
		return true
	end

	local npcName = NPC.Name
	local doorModel = DoorOpener.findNearestDoor(Waypoint.Position)
	if not doorModel then return true end

	local openValue = doorModel:FindFirstChild("Open")
	if not openValue then return true end

	if openValue.Value == true then
		monitorPassthrough(NPC, doorModel)
		return true
	end

	-- 🌟 Invocate single authority pattern
	local secureToggleFunc = _G["SecureToggleDoor_" .. doorModel:GetFullName()]
	if secureToggleFunc then
		secureToggleFunc(true)
	else
		openValue.Value = true
	end

	task.wait(OPEN_WAIT)
	monitorPassthrough(NPC, doorModel)
	return true
end

return DoorOpener
