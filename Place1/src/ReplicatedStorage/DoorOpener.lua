local DoorOpener = {}
local CollectionService = game:GetService("CollectionService")

local DOOR_TAG = "Door"
local OPEN_WAIT = 0.5 -- matches the door's 0.4s tween + a small margin

-- ─────────────────────────────────────────────
-- DEBUG CONFIG  (flip to false to silence logs)
-- ─────────────────────────────────────────────
local DEBUG = true

local function dbg(npcName: string, msg: string)
	if DEBUG then
		print(string.format("[DoorOpener][%s] %s", npcName, msg))
	end
end

local function warn_dbg(npcName: string, msg: string)
	if DEBUG then
		warn(string.format("[DoorOpener][%s] %s", npcName, msg))
	end
end

-- ─────────────────────────────────────────────
-- Finds the closest CollectionService-tagged door Model to a world position.
-- ─────────────────────────────────────────────
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

-- ─────────────────────────────────────────────
-- After the door opens, watch whether the NPC
-- clears the doorway within a timeout window.
-- Detects "stuck on a door part" by checking if
-- the NPC's HumanoidRootPart stops moving while
-- still overlapping / adjacent to door geometry.
-- ─────────────────────────────────────────────
local CLEAR_TIMEOUT   = 4    -- seconds to fully cross the doorway
local STUCK_THRESHOLD = 1.5  -- studs/s below which the NPC is "not moving"
local STUCK_POLL      = 0.3  -- how often to sample position (seconds)

local function monitorPassthrough(NPC: Instance, doorModel: Model)
	task.spawn(function()
		local root = NPC:FindFirstChild("HumanoidRootPart")
		if not root then return end

		local npcName   = NPC.Name
		local doorName  = doorModel.Name
		local deadline  = os.clock() + CLEAR_TIMEOUT
		local lastPos   = root.Position
		local stuckSecs = 0

		dbg(npcName, string.format("Monitoring passthrough of '%s' for up to %.1fs", doorName, CLEAR_TIMEOUT))

		while os.clock() < deadline do
			task.wait(STUCK_POLL)

			if not NPC.Parent or not NPC:FindFirstChild("HumanoidRootPart") then
				dbg(npcName, "NPC removed during door crossing — monitoring stopped.")
				return
			end

			-- If the NPC is far enough from the door, it has clearly passed through
			local distFromDoor = (doorModel:GetPivot().Position - root.Position).Magnitude
			if distFromDoor > 8 then
				dbg(npcName, string.format("Cleared door '%s' (%.2f studs away).", doorName, distFromDoor))
				return
			end

			local currentPos = root.Position
			local speed = (currentPos - lastPos).Magnitude / STUCK_POLL
			lastPos = currentPos

			-- NPC is slow/stopped near the door
			if speed < STUCK_THRESHOLD then
				stuckSecs += STUCK_POLL

				-- Check if the NPC is actually in combat range of a player —
				-- if so, standing still is intentional, not a stuck condition
				local Players = game:GetService("Players")
				local inCombat = false
				for _, player in Players:GetPlayers() do
					local char = player.Character
					local targetRoot = char and char:FindFirstChild("HumanoidRootPart")
					if targetRoot then
						local distToPlayer = (root.Position - targetRoot.Position).Magnitude
						if distToPlayer <= 6 then -- generous combat range check
							inCombat = true
							break
						end
					end
				end

				if inCombat then
					dbg(npcName, "NPC is in combat near door — not stuck, stopping monitor.")
					return
				end

				-- Only then check if it's near a door part
				local closestPart, closestDist = nil, math.huge
				for _, part in ipairs(doorModel:GetDescendants()) do
					if part:IsA("BasePart") then
						local d = (part.Position - currentPos).Magnitude
						if d < closestDist then
							closestDist = d
							closestPart = part
						end
					end
				end

				local nearDoor = closestPart and closestDist < 5

				if nearDoor then
					warn_dbg(npcName, string.format(
						"STUCK near door part '%s' (dist=%.2f studs, speed=%.2f studs/s, stuck for %.1fs)",
						closestPart.Name, closestDist, speed, stuckSecs
						))
				end
			else
				if stuckSecs > 0 then
					dbg(npcName, string.format("Resumed moving (speed=%.2f studs/s).", speed))
				end
				stuckSecs = 0
			end
		end

		if NPC.Parent and NPC:FindFirstChild("HumanoidRootPart") then
			local finalDist = (doorModel:GetPivot().Position - root.Position).Magnitude
			if finalDist < 5 then
				warn_dbg(npcName, string.format(
					"TIMEOUT — NPC still %.2f studs from door '%s'.",
					finalDist, doorName
					))
			else
				dbg(npcName, string.format(
					"Cleared door '%s' (%.2f studs away at timeout).",
					doorName, finalDist
					))
			end
		end
	end)
end

-- ─────────────────────────────────────────────
-- Matches Forbidden's config.Hooks.PathfindingLinkReached signature:
-- (NPC: Instance, Waypoint: PathWaypoint) -> boolean
-- ─────────────────────────────────────────────
function DoorOpener.onPathfindingLinkReached(NPC: Instance, Waypoint: PathWaypoint): boolean
	print("LINK REACHED", Waypoint.Label, Waypoint.Position)
	print("DOOROPENER CALLED", Waypoint.Label, Waypoint.Action)
	local npcName = NPC.Name

	-- Not a door waypoint — ignore silently
	if not Waypoint.Label or not string.find(string.lower(Waypoint.Label), "door") then
		return true
	end

	dbg(npcName, string.format("Door waypoint reached (Label='%s', Pos=%s)", Waypoint.Label, tostring(Waypoint.Position)))

	local doorModel = DoorOpener.findNearestDoor(Waypoint.Position)
	if not doorModel then
		warn_dbg(npcName, "No door model with tag '" .. DOOR_TAG .. "' found near waypoint. Is the door tagged?")
		return true
	end

	dbg(npcName, string.format("Found door model: '%s'", doorModel.Name))

	local openValue = doorModel:FindFirstChild("Open")
	if not openValue then
		warn_dbg(npcName, string.format("Door '%s' has no 'Open' BoolValue child.", doorModel.Name))
		return true
	end

	if openValue.Value == true then
		dbg(npcName, string.format("Door '%s' was already open — walking through.", doorModel.Name))
		monitorPassthrough(NPC, doorModel)
		return true
	end

	dbg(npcName, string.format("Opening door '%s'...", doorModel.Name))
	openValue.Value = true
	task.wait(OPEN_WAIT)
	dbg(npcName, string.format("Door '%s' should be open now (waited %.2fs). NPC resuming path.", doorModel.Name, OPEN_WAIT))

	monitorPassthrough(NPC, doorModel)

	return true
end

return DoorOpener
