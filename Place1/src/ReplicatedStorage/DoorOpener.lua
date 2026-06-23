local DoorOpener = {}
local CollectionService = game:GetService("CollectionService")

local DOOR_TAG = "Door"
local OPEN_WAIT = 0.5 -- matches the door's 0.4s tween + a small margin

-- Finds the closest CollectionService-tagged door Model to a world position.
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

-- Matches Forbidden's config.Hooks.PathfindingLinkReached signature:
-- (NPC: Instance, Waypoint: PathWaypoint) -> boolean
function DoorOpener.onPathfindingLinkReached(NPC: Instance, Waypoint: PathWaypoint): boolean
	if not Waypoint.Label or not string.find(string.lower(Waypoint.Label), "door") then
		return true -- not a door link, nothing to do
	end

	local doorModel = DoorOpener.findNearestDoor(Waypoint.Position)
	if not doorModel then
		return true -- couldn't find it; don't permanently block the NPC
	end

	local openValue = doorModel:FindFirstChild("Open")
	if not openValue then
		return true
	end

	if openValue.Value == true then
		return true -- already open, just walk through
	end

	openValue.Value = true
	task.wait(OPEN_WAIT) -- give the tween time to finish before continuing

	return true
end

return DoorOpener