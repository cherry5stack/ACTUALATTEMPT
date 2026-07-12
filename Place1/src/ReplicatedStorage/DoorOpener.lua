local DoorOpener = {}
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ForbiddenMath = require(ReplicatedStorage.Forbidden.Math)
local AI = require(ReplicatedStorage.Forbidden.AI)

local DOOR_TAG = "Door"
local OPEN_WAIT = 0.5
local DOOR_PROXIMITY_RANGE =8 -- studs; should exceed the door's own isNPCInDoorway() close-block radius (5.5)

local DEBUG = true
local busyBreakers: {[Instance]: boolean} = {}

local function dbg(npcName: string, msg: string)
	if DEBUG then print(string.format("[DoorOpener][%s] %s", npcName, msg)) end
end

local function warn_dbg(npcName: string, msg: string)
	if DEBUG then warn(string.format("[DoorOpener][%s] %s", npcName, msg)) end
end

-- SINGLE AUTHORITY: this is the only function in the whole project allowed
-- to request a door open/close. It only ever calls the door's own
-- SecureToggleDoor_ global (defined in system.lua) — it never writes
-- Open.Value directly, anywhere, for any reason. If the global isn't
-- present (e.g. system.lua hasn't run yet), we log and bail instead of
-- silently writing to the value ourselves, since that would reintroduce
-- the exact race condition we're trying to eliminate.
local function requestDoorState(doorModel: Model, state: boolean): boolean
	local secureToggleFunc = _G["SecureToggleDoor_" .. doorModel:GetFullName()]
	if not secureToggleFunc then
		warn(string.format("[DoorOpener] No SecureToggleDoor_ found for '%s' — is system.lua loaded on this door?", doorModel:GetFullName()))
		return false
	end

	secureToggleFunc(state)
	return true
end

local PathfindingService = game:GetService("PathfindingService")

-- Runs a raw ComputeAsync from the NPC to its target and returns the first
-- closed, tagged Door whose waypoint Label matches its own unique name
-- (Doors should be uniquely named, e.g. "Door_KitchenHallway", and each
-- door's PathfindingLink Label, if any, should match — this only matters
-- for identification here, not for actually triggering anything, since we
-- already proved the navmesh routes through doorways as plain floor and
-- the link itself never produces a Custom waypoint).
--
-- This is intentionally NOT called every tick — it's a real ComputeAsync
-- call, so EnemyManager should throttle it (e.g. once per repath, not once
-- per 0.1s heartbeat).
function DoorOpener.FindBlockingDoor(NPC: Instance, TargetPos: Vector3, AgentInfo: {[string]: any}, overrideRange: number?): Model?
	local npcRoot = NPC:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return nil end

	-- NEW: Use the custom door attack range if provided, otherwise fallback to 8
	local checkRange = overrideRange or DOOR_PROXIMITY_RANGE

	-- First pass: path-aware detection. Compute route to target and check
	-- if any waypoint passes near a closed door.
	local path = PathfindingService:CreatePath(AgentInfo)
	local ok = pcall(function()
		path:ComputeAsync(npcRoot.Position, TargetPos)
	end)

	if ok and path.Status == Enum.PathStatus.Success then
		local waypoints = path:GetWaypoints()
		for _, doorModel in ipairs(CollectionService:GetTagged(DOOR_TAG)) do
			if not doorModel:IsA("Model") then continue end
			local openValue = doorModel:FindFirstChild("Open")
			if not openValue or openValue.Value == true then continue end
			local doorBBCF, _ = doorModel:GetBoundingBox()
			local doorCenter   = doorBBCF.Position
			for _, wp in ipairs(waypoints) do
				-- NEW: Check against our new checkRange variable
				if (wp.Position - doorCenter).Magnitude <= checkRange then
					return doorModel
				end
			end
		end
	end

	-- Second pass: proximity fallback.
	for _, doorModel in ipairs(CollectionService:GetTagged(DOOR_TAG)) do
		if not doorModel:IsA("Model") then continue end
		local openValue = doorModel:FindFirstChild("Open")
		if not openValue or openValue.Value == true then continue end
		local doorBBCF, _ = doorModel:GetBoundingBox()
		local doorCenter   = doorBBCF.Position
		local npcDist = (npcRoot.Position - doorCenter).Magnitude
		-- NEW: Check against our new checkRange variable
		if npcDist <= checkRange then
			return doorModel
		end
	end

	return nil
end

-- Returns true if the NPC has unobstructed line of sight to the door.
-- Uses Forbidden.Math.LineOfSight so it respects collision groups,
-- non-collidable parts, and descendant matching the same way the rest
-- of the AI system does.
local function hasLOSToDoor(NPC: Instance, doorModel: Model): boolean
	local npcRoot = NPC:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return false end

	local ok = ForbiddenMath.LineOfSight(npcRoot, doorModel, {
		Range                    = 200,
		SeeThroughNonCollidable  = true,  -- ignore glass, triggers, sensors etc.
		FilterTable              = { NPC },
	})

	if not ok then
		dbg(NPC.Name, string.format("No LOS to door '%s'.", doorModel:GetFullName()))
	end

	return ok
end

-- Walks the NPC to within attackRange studs of the door, then opens it.
-- Uses the same standoff positioning as AttackDoor so openers approach
-- at a consistent distance before triggering the open, rather than
-- opening from wherever they happen to be standing.
function DoorOpener.RequestOpen(NPC: Instance, doorModel: Model, attackRange: number?, maxHeightDiff: number?)
	local range    = math.max(attackRange or 5, 2) -- never closer than 2 studs or NPC ends up inside the door
	local npcRoot  = NPC:FindFirstChild("HumanoidRootPart")
	local humanoid = NPC:FindFirstChildOfClass("Humanoid")
	if not npcRoot or not humanoid then
		requestDoorState(doorModel, true)
		return
	end

	local doorBBCF, _ = doorModel:GetBoundingBox()
	local doorPos     = doorBBCF.Position
	local toNPC       = npcRoot.Position - doorPos
	local flatToNPC   = Vector3.new(toNPC.X, 0, toNPC.Z)

	-- Y height check — don't open if NPC is too far above/below the door.
	local yGap = math.abs(npcRoot.Position.Y - doorPos.Y)
	if yGap > (maxHeightDiff or 5) then
		dbg(NPC.Name, string.format("Y gap too large (%.1f studs) — skipping door open.", yGap))
		return
	end

	-- If already within range, just open immediately.
	if flatToNPC.Magnitude <= range then
		dbg(NPC.Name, string.format("Already within %.1f studs of door — opening '%s'.", range, doorModel:GetFullName()))
		requestDoorState(doorModel, true)
		return
	end

	-- Stand directly in front of the door's bounding box center on the NPC's side.
	local standPos = Vector3.new(
		doorPos.X + flatToNPC.Unit.X * (range - 0.5),
		npcRoot.Position.Y,
		doorPos.Z + flatToNPC.Unit.Z * (range - 0.5)
	)

	dbg(NPC.Name, string.format(
		"Walking to open position (%.1f studs) for door '%s'.",
		range, doorModel:GetFullName()
		))

	task.spawn(function()
		-- Pathfind without yielding and poll with a timeout, same as AttackDoor.
		-- Yields=true would hang forever if AI.Stop cancels the pathfind mid-way.
		AI.SmartPathfind(NPC, standPos, false)

		local deadline = os.clock() + 6 --door open time
		while os.clock() < deadline do
			task.wait(0.1)
			if not doorModel.Parent then return end
			local openValue = doorModel:FindFirstChild("Open")
			if openValue and openValue.Value == true then return end
			local distToStand = Vector3.new(
				npcRoot.Position.X - standPos.X, 0, npcRoot.Position.Z - standPos.Z
			).Magnitude
			if distToStand <= range then break end
		end

		local openValue = doorModel:FindFirstChild("Open")
		if openValue and openValue.Value == true then
			dbg(NPC.Name, "Door already opened before NPC arrived — skipping open.")
			return
		end

		dbg(NPC.Name, string.format("Requesting open on '%s'.", doorModel:GetFullName()))
		requestDoorState(doorModel, true)
	end)
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

-- Called once per NPC per tick from EnemyManager.lua. Checks every tagged
-- Door in the level; if the NPC is within DOOR_PROXIMITY_RANGE of a closed
-- door, requests it open. This replaces both the old link-based opener and
-- the old raycast-based tryOpenBlockingDoor — proximity is the only signal
-- needed since the navmesh already routes straight through doorways without
-- requiring a PathfindingLink waypoint.
function DoorOpener.OpenNearbyDoors(NPC: Instance)
	if busyBreakers[NPC] then return end -- mid door-break, let AttackDoor finish its own loop

	local npcRoot = NPC:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	for _, doorModel in ipairs(CollectionService:GetTagged(DOOR_TAG)) do
		if not doorModel:IsA("Model") then continue end

		local openValue = doorModel:FindFirstChild("Open")
		if not openValue then continue end
		if openValue.Value == true then continue end -- already open, nothing to do

		local dist = (doorModel:GetPivot().Position - npcRoot.Position).Magnitude
		if dist <= DOOR_PROXIMITY_RANGE then
			dbg(NPC.Name, string.format("Within %.1f studs of door '%s', requesting open.", dist, doorModel:GetFullName()))
			requestDoorState(doorModel, true)
		end
	end
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

-- Kept for backwards compatibility / in case a PathfindingLink waypoint is
-- ever actually produced by the pathfinder (it currently is not, since the
-- navmesh routes straight through doorways once PassThrough modifiers are
-- correctly placed — see DoorOpener.OpenNearbyDoors for the active path).
function DoorOpener.onPathfindingLinkReached(NPC: Instance, Waypoint: PathWaypoint): boolean
	print("[DoorOpener] Link reached with label:", Waypoint.Label)
	if not Waypoint.Label or not string.find(string.lower(Waypoint.Label), "door") then
		return true
	end

	local doorModel = DoorOpener.findNearestDoor(Waypoint.Position)
	if not doorModel then return true end

	local openValue = doorModel:FindFirstChild("Open")
	if not openValue then return true end

	if openValue.Value == true then
		monitorPassthrough(NPC, doorModel)
		return true
	end

	requestDoorState(doorModel, true)

	task.wait(OPEN_WAIT)
	monitorPassthrough(NPC, doorModel)
	return true
end

-- ─────────────────────────────────────────────────────────────
-- DOOR BREAKING (for enemies with EnemyData.BreaksDoors = true)
-- ─────────────────────────────────────────────────────────────

function DoorOpener.IsBreaking(NPC: Instance): boolean
	return busyBreakers[NPC] == true
end

-- Faces the NPC toward a world position using AlignOrientation,
-- matching the VisionSystem.faceTarget pattern used elsewhere.
local function faceDoor(NPC: Instance, doorPos: Vector3)
	local npcRoot = NPC:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	local align = npcRoot:FindFirstChild("DoorFaceAlign")
	if not align then
		local attachment = Instance.new("Attachment")
		attachment.Name = "DoorFaceAttachment"
		attachment.Parent = npcRoot

		align = Instance.new("AlignOrientation")
		align.Name = "DoorFaceAlign"
		align.Mode = Enum.OrientationAlignmentMode.OneAttachment
		align.Attachment0 = attachment
		align.RigidityEnabled = false
		align.Responsiveness = 2500
		align.MaxTorque = math.huge
		align.MaxAngularVelocity = math.huge
		align.Parent = npcRoot
	end

	local direction = doorPos - npcRoot.Position
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude > 0.1 then
		align.CFrame = CFrame.lookAt(Vector3.new(), flat.Unit)
	end
end

local function cleanupDoorFacing(NPC: Instance)
	local npcRoot = NPC:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end
	local align = npcRoot:FindFirstChild("DoorFaceAlign")
	if align then align:Destroy() end
	local attachment = npcRoot:FindFirstChild("DoorFaceAttachment")
	if attachment then attachment:Destroy() end
end

-- Melee-animation-driven door attack. The NPC walks to within attackRange
-- studs of the door, faces it, plays the attack animation, and deals damage
-- at the Hit marker (falling back to a timed hit if no marker exists).
-- Only deals damage if actually within attackRange — prevents ranged-looking
-- hits where the NPC swings from far away.
--
-- attackConfig shape (from EnemyData.DoorAttack or built from EnemyStats):
--   AnimationName  (string)   animation to play per swing
--   AttackSpeed    (number?)  animation playback speed, default 1
--   Cooldown       (number)   seconds between swings
--   Damage         (number)   HP drained from door per hit
--   AttackRange    (number?)  max distance to deal damage, default 5 studs
function DoorOpener.AttackDoor(NPC: Instance, doorModel: Model, attackConfig: {[string]: any}, onFinished: (() -> ())?)
	if busyBreakers[NPC] then return end

	local doorHealth = doorModel:FindFirstChild("Health")
	if not doorHealth or not doorHealth:IsA("IntValue") then
		warn(string.format("[DoorOpener] '%s' has no Health IntValue — cannot break it down.", doorModel:GetFullName()))
		if onFinished then onFinished() end
		return
	end

	local openValue = doorModel:FindFirstChild("Open")
	local humanoid  = NPC:FindFirstChildOfClass("Humanoid")
	local npcRoot   = NPC:FindFirstChild("HumanoidRootPart")
	if not humanoid or not npcRoot then
		if onFinished then onFinished() end
		return
	end

	local attackRange    = math.max(attackConfig.AttackRange)
	local maxHeightDiff  = attackConfig.MaxHeightDiff or 5

	-- Use the bounding box center rather than pivot — pivot placement varies
	-- per model but the bounding box center is always the physical middle of the door.
	local function getDoorCenter(): Vector3
		local cf, _ = doorModel:GetBoundingBox()
		return cf.Position
	end
	local doorPos = getDoorCenter()

	busyBreakers[NPC] = true
	humanoid.AutoRotate = false

	dbg(NPC.Name, string.format(
		"Starting door break on '%s' | Health=%d | AttackRange=%.1f | Damage=%d",
		doorModel:GetFullName(), doorHealth.Value, attackRange, attackConfig.Damage or 10
		))

	task.spawn(function()

		local standPos = nil
		local function computeStandPos()
			doorPos = getDoorCenter()
			local toNPC     = (npcRoot.Position - doorPos)
			local flatToNPC = Vector3.new(toNPC.X, 0, toNPC.Z)
			if flatToNPC.Magnitude < 0.1 then return end

			standPos = Vector3.new(
				doorPos.X + flatToNPC.Unit.X * (attackRange - 0.5),
				npcRoot.Position.Y,
				doorPos.Z + flatToNPC.Unit.Z * (attackRange - 0.5)
			)
		end
		computeStandPos()

		local function horizontalDist(a: Vector3, b: Vector3): number
			return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
		end

		local function moveToAttackPosition()
			if not standPos then return end

			-- If already within attack range, no need to walk anywhere.
			local currentDist = horizontalDist(npcRoot.Position, doorPos)
			if currentDist <= attackRange + 1 then
				dbg(NPC.Name, string.format("Already within attack range (%.1f studs) — skipping pathfind.", currentDist))
				return
			end

			dbg(NPC.Name, string.format("Pathfinding to attack position: (%.1f, %.1f, %.1f)", standPos.X, standPos.Y, standPos.Z))
			AI.SmartPathfind(NPC, standPos, false)

			local deadline = os.clock() + 6
			while os.clock() < deadline do
				task.wait(0.1)
				if not doorModel.Parent then break end
				if openValue and openValue.Value == true then break end
				local distToDoor = horizontalDist(npcRoot.Position, doorPos)
				if distToDoor <= attackRange + 1 then break end
			end

			dbg(NPC.Name, string.format(
				"At attack position — distance to door: %.1f studs.",
				horizontalDist(npcRoot.Position, doorPos)
				))
		end

		local function applyDoorFacingGyro()
			local bodyGyro = npcRoot:FindFirstChild("FaceDoorGyro")
			if not bodyGyro then
				bodyGyro            = Instance.new("BodyGyro")
				bodyGyro.Name       = "FaceDoorGyro"
				bodyGyro.P          = 8000
				bodyGyro.D          = 400
				bodyGyro.MaxTorque  = Vector3.new(0, 100000, 0)
				bodyGyro.Parent     = npcRoot
			end
			-- Destroy player-facing gyro if it crept in
			local playerGyro = npcRoot:FindFirstChild("FaceTargetGyro")
			if playerGyro then playerGyro:Destroy() end

			local center    = getDoorCenter()
			local direction = (center - npcRoot.Position)
			local flat      = Vector3.new(direction.X, 0, direction.Z)
			if flat.Magnitude > 0.1 then
				bodyGyro.CFrame = CFrame.lookAt(npcRoot.Position, npcRoot.Position + flat.Unit)
			end
		end

		moveToAttackPosition()

		while doorModel.Parent and doorHealth.Value > 0 do
			if openValue and openValue.Value == true then
				dbg(NPC.Name, "Door opened mid-break — stopping attack.")
				break
			end

			-- Refresh door position and face it each swing.
			doorPos = doorModel:GetPivot().Position
			applyDoorFacingGyro()

			-- Stop any in-progress pathfind before checking distance / swinging.
			AI.Stop(NPC)

			-- Distance check — 3D distance + Y cap so elevated NPCs can't swing at doors below them.
			-- Distance check — horizontal only to avoid Y offset from bounding box center
			doorPos = getDoorCenter()
			local currentDist = horizontalDist(npcRoot.Position, doorPos)  -- was (npcRoot.Position - doorPos).Magnitude
			local yDiff = math.abs(npcRoot.Position.Y - doorPos.Y)

			-------
			if yDiff > maxHeightDiff then
				-- Too high/low to reach the door — abort so EnemyManager can repath.
				dbg(NPC.Name, string.format("Y gap too large (%.1f studs) — aborting door attack.", yDiff))
				break
			end

			-----

			if currentDist > attackRange + 1 then
				dbg(NPC.Name, string.format("Too far from door (%.1f) — repositioning.", currentDist))
				computeStandPos()
				moveToAttackPosition()
				continue
			end

			-- Hold NPC position during animation using AI.Stop so Forbidden
			-- doesn't issue competing MoveTo calls.
			local swingDone = false

			local animator  = humanoid:FindFirstChildOfClass("Animator")
			local animFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Animations")
			local animObject = attackConfig.AnimationName and animFolder and animFolder:FindFirstChild(attackConfig.AnimationName)

			dbg(NPC.Name, string.format(
				"Swinging at door '%s' | Distance=%.1f | Health=%d",
				doorModel:GetFullName(), currentDist, doorHealth.Value
				))

			local dealt = false
			local function dealDoorDamage()
				if dealt then return end
				dealt = true

				-- Final range check at actual hit moment — 3D + Y cap so elevation blocks damage.
				local hitPos = doorModel:GetPivot().Position
				local distAtHit = Vector3.new(
					npcRoot.Position.X - hitPos.X, 0, npcRoot.Position.Z - hitPos.Z
				).Magnitude
				local yDiffAtHit = math.abs(npcRoot.Position.Y - hitPos.Y)
				-----
				if distAtHit > attackRange + 1 or yDiffAtHit > maxHeightDiff then
					dbg(NPC.Name, string.format(
						"Hit marker fired but NPC too far (%.1f) — damage withheld.",
						distAtHit
						))
					return
				end
				----
				local dmg = attackConfig.Damage or 10
				doorHealth.Value = math.max(0, doorHealth.Value - dmg)
				dbg(NPC.Name, string.format(
					"DEALT %d damage to door '%s' — Health now %d.",
					dmg, doorModel:GetFullName(), doorHealth.Value
					))
			end

			if animator and animObject then
				local track = animator:LoadAnimation(animObject)
				track:Play(nil, nil, attackConfig.AttackSpeed or 1)
				local hitConn = track:GetMarkerReachedSignal("Hit"):Connect(dealDoorDamage)

				-- Trace position every 0.1s during animation so we can see drift.
				local animDone = false
				task.spawn(function()
					while not animDone do
						task.wait(0.1)
						if not npcRoot.Parent then break end
						local distNow = horizontalDist(npcRoot.Position, doorModel:GetPivot().Position)
						local vel = npcRoot.AssemblyLinearVelocity
						local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
						dbg(NPC.Name, string.format(
							"[ANIM]  dist=%.2f | speed=%.2f | pos=(%.1f,%.1f,%.1f)",
							distNow, speed, npcRoot.Position.X, npcRoot.Position.Y, npcRoot.Position.Z
							))
					end
				end)

				track.Stopped:Wait()
				animDone = true
				swingDone = true
				hitConn:Disconnect()
				-- Safety net: if no Hit marker in the animation, damage once at end.
				dealDoorDamage()
			else
				dbg(NPC.Name, "No animator or animation found — using timed fallback hit.")
				task.wait(0.5)
				swingDone = true
				dealDoorDamage()
			end

			if doorHealth.Value <= 0 then break end

			-- Cooldown between swings — hold position so NPC doesn't drift toward player.
			AI.Stop(NPC)
			local cooldown = attackConfig.Cooldown or 1
			local elapsed  = 0
			dbg(NPC.Name, string.format("Cooldown %.1fs before next swing.", cooldown))
			while elapsed < cooldown do
				elapsed += task.wait(0.1)
				if not doorModel.Parent then break end
				if doorHealth.Value <= 0 then break end
				if openValue and openValue.Value == true then break end

				local distNow = horizontalDist(npcRoot.Position, doorModel:GetPivot().Position)
				local vel = npcRoot.AssemblyLinearVelocity
				local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
				dbg(NPC.Name, string.format(
					"[COOLDOWN] elapsed=%.1f/%.1f | dist=%.2f | speed=%.2f | standPos=(%.1f,%.1f,%.1f)",
					elapsed, cooldown, distNow, speed,
					standPos and standPos.X or 0,
					standPos and standPos.Y or 0,
					standPos and standPos.Z or 0
					))
			end
		end

		if doorModel.Parent and doorHealth.Value <= 0 then
			dbg(NPC.Name, string.format("Door '%s' destroyed!", doorModel:GetFullName()))
			doorModel:Destroy()
		end

		cleanupDoorFacing(NPC) -- removes DoorFaceAlign/DoorFaceAttachment (kept for compat)
		local doorGyro = npcRoot:FindFirstChild("FaceDoorGyro")
		if doorGyro then doorGyro:Destroy() end
		humanoid.AutoRotate = true
		busyBreakers[NPC] = nil
		dbg(NPC.Name, "Door break finished — resuming normal behaviour.")
		if onFinished then onFinished() end
	end)
end

return DoorOpener
