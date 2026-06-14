local CombatManager = {}

local lastAttackTimes = {}
local DEBUG = true

local function drawHitbox(cframe, size, duration)
	if not DEBUG then return end
	local part = Instance.new("Part")
	part.Anchored    = true
	part.CanCollide  = false
	part.CanQuery    = false
	part.CastShadow  = false
	part.Transparency = 0.5
	part.Color       = Color3.fromRGB(255, 0, 0)
	part.Material    = Enum.Material.Neon
	part.Size        = size
	part.CFrame      = cframe
	part.Parent      = workspace
	game:GetService("Debris"):AddItem(part, duration or 0.2)
end

function CombatManager.tryAttack(npc, target, data)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end

	if not lastAttackTimes[npc] then lastAttackTimes[npc] = {} end

	local dist = (npcRoot.Position - targetRoot.Position).Magnitude

	-- build list of valid attacks
	local validAttacks = {}
	for _, attack in ipairs(data.Attacks) do
		if not attack then continue end
		local lastTime = lastAttackTimes[npc][attack.Name] or 0  -- use Name not AnimationId
		if dist <= attack.Range and os.clock() - lastTime >= attack.Cooldown then
			table.insert(validAttacks, attack)
		end
	end

	if #validAttacks == 0 then 
		print(string.format("[%s] All attacks on cooldown", npc.Name))
		return 
	end

	-- sort by priority descending
	table.sort(validAttacks, function(a, b)
		return (a.Priority or 1) > (b.Priority or 1)
	end)

	-- collect all attacks tied at the top priority
	local topPriority = validAttacks[1].Priority or 1
	local topAttacks = {}
	for _, attack in ipairs(validAttacks) do
		if (attack.Priority or 1) == topPriority then
			table.insert(topAttacks, attack)
		end
	end

	-- randomly pick between tied attacks
	local chosen = topAttacks[math.random(1, #topAttacks)]

	-- execute chosen attack
	lastAttackTimes[npc][chosen.Name] = os.clock()  -- use Name not AnimationId

	local direction = (targetRoot.Position - npcRoot.Position).Unit
	local hitboxCFrame = CFrame.new(npcRoot.Position + direction * chosen.HitboxOffset)
	drawHitbox(hitboxCFrame, chosen.HitboxSize, 0.2)

	local params = OverlapParams.new()
	params.FilterDescendantsInstances = {npc}
	params.FilterType = Enum.RaycastFilterType.Exclude

	local hits = workspace:GetPartBoundsInBox(hitboxCFrame, chosen.HitboxSize, params)
	local alreadyHit = {}

	for _, hit in hits do
		local character = hit.Parent
		local player = game:GetService("Players"):GetPlayerFromCharacter(character)
		local hitHumanoid = character:FindFirstChildOfClass("Humanoid")
		if hitHumanoid and character ~= npc and player and not alreadyHit[character] then
			alreadyHit[character] = true
			hitHumanoid:TakeDamage(chosen.Damage)
			print(string.format("[%s] Used %s on %s for %d damage", npc.Name, chosen.Name, character.Name, chosen.Damage))
		end
	end
end

function CombatManager.cleanup(npc)
	lastAttackTimes[npc] = nil
end



return CombatManager
