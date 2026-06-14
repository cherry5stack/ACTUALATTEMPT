-- StuckRecovery.lua in ReplicatedStorage
return function()
	local StuckRecovery = {}

	local STUCK_DIST_THRESHOLD = 0.3
	local STUCK_TIME           = 1.5

	local lastPos       = Vector3.new(0, 0, 0)
	local lastMovedTime = os.clock()

	local function getNpcPos(npc)
		local root = npc:FindFirstChild("HumanoidRootPart")
		return root and root.Position or Vector3.new(0, 0, 0)
	end

	function StuckRecovery.reset(npc)
		lastPos       = getNpcPos(npc)
		lastMovedTime = os.clock()
	end

	function StuckRecovery.update(npc)
		local pos   = getNpcPos(npc)
		local moved = (pos - lastPos).Magnitude
		if moved > STUCK_DIST_THRESHOLD then
			lastPos       = pos
			lastMovedTime = os.clock()
		end
	end

	function StuckRecovery.isStuck()
		return os.clock() - lastMovedTime >= STUCK_TIME
	end

	function StuckRecovery.suppress()
		-- call this when the NPC is intentionally standing still (attacking)
		-- so it doesn't false-trigger
		lastMovedTime = os.clock()
	end

	function StuckRecovery.updateSettings(newSettings)
		for k, v in pairs(newSettings) do
			if k == "DistThreshold" then STUCK_DIST_THRESHOLD = v end
			if k == "StuckTime"     then STUCK_TIME = v end
		end
	end

	return StuckRecovery
end