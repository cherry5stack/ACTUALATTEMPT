local CombatManager = {}
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lastAttackTimes = {}
local activeAnimations = {}
local lastAttackEnd = {}
local DEBUG = false

local function drawHitbox(cframe, size, duration)
	if not DEBUG then return end
	local part = Instance.new("Part")
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.CastShadow   = false
	part.Transparency = 0.5
	part.Color        = Color3.fromRGB(255, 0, 0)
	part.Material     = Enum.Material.Neon
	part.Size         = size
	part.CFrame       = cframe
	part.Parent       = workspace
	game:GetService("Debris"):AddItem(part, duration or 0.2)
end

local function attachParticle(hitboxPart, effectName)
	if not effectName or effectName == "" then return end
	local effectsFolder = ReplicatedStorage:FindFirstChild("ParticleEffects")
	if not effectsFolder then return end
	local particle = effectsFolder:FindFirstChild(effectName)
	if not particle or not particle:IsA("ParticleEmitter") then return end
	particle:Clone().Parent = hitboxPart
end

local function spawnHitbox(npcRoot, npc, chosen, onFinished)
	local params = OverlapParams.new()
	params.FilterDescendantsInstances = {npc}
	params.FilterType = Enum.RaycastFilterType.Exclude

	local duration = chosen.HitboxDuration or 0
	local tickRate = chosen.PerTick

	if duration > 0 then
		local hitTimestamps = {}
		local elapsed = 0
		local frozenCFrame = npcRoot.CFrame * CFrame.new(0, 0, -chosen.HitboxOffset)

		local hitboxPart
		if DEBUG then
			hitboxPart = Instance.new("Part")
			hitboxPart.Anchored     = true
			hitboxPart.CanCollide   = false
			hitboxPart.CanQuery     = false
			hitboxPart.CastShadow   = false
			hitboxPart.Transparency = 0.5
			hitboxPart.Color        = Color3.fromRGB(255, 0, 0)
			hitboxPart.Material     = Enum.Material.Neon
			hitboxPart.Size         = chosen.HitboxSize
			hitboxPart.CFrame       = frozenCFrame
			hitboxPart.Parent       = workspace
			attachParticle(hitboxPart, chosen.ParticleEffect)
			game:GetService("Debris"):AddItem(hitboxPart, duration)
		end

		local connection
		connection = RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			local now = os.clock()

			local activeCFrame = chosen.StaticHitbox
				and frozenCFrame
				or npcRoot.CFrame * CFrame.new(0, 0, -chosen.HitboxOffset)

			if hitboxPart and not chosen.StaticHitbox then
				hitboxPart.CFrame = activeCFrame
			end

			for _, hit in workspace:GetPartBoundsInBox(activeCFrame, chosen.HitboxSize, params) do
				local character = hit.Parent
				local player = Players:GetPlayerFromCharacter(character)
				local hum = character:FindFirstChildOfClass("Humanoid")
				local lastHit = hitTimestamps[character]

				local canHit = not lastHit or (tickRate and now - lastHit >= tickRate)
				if hum and character ~= npc and player and canHit then
					hitTimestamps[character] = now
					hum:TakeDamage(chosen.Damage)
					print(string.format("[%s] Used %s on %s for %d damage", npc.Name, chosen.Name, character.Name, chosen.Damage))
				end
			end

			if elapsed >= duration then
				connection:Disconnect()
				if onFinished then onFinished() end  -- notify when hitbox is fully done
			end
		end)
	else
		local hitboxCFrame = npcRoot.CFrame * CFrame.new(0, 0, -chosen.HitboxOffset)
		drawHitbox(hitboxCFrame, chosen.HitboxSize, 0.2)
		local alreadyHit = {}
		for _, hit in workspace:GetPartBoundsInBox(hitboxCFrame, chosen.HitboxSize, params) do
			local character = hit.Parent
			local player = Players:GetPlayerFromCharacter(character)
			local hum = character:FindFirstChildOfClass("Humanoid")
			if hum and character ~= npc and player and not alreadyHit[character] then
				alreadyHit[character] = true
				hum:TakeDamage(chosen.Damage)
				print(string.format("[%s] Used %s on %s for %d damage", npc.Name, chosen.Name, character.Name, chosen.Damage))
			end
		end
		if onFinished then onFinished() end  -- instant attacks finish immediately
	end
end

function CombatManager.tryAttack(npc, target, data)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end

	if activeAnimations[npc] then return end

	if not lastAttackTimes[npc] then lastAttackTimes[npc] = {} end

	local dist = (npcRoot.Position - targetRoot.Position).Magnitude

	local validAttacks = {}
	for _, attack in ipairs(data.Attacks) do
		if not attack then continue end
		local lastTime = lastAttackTimes[npc][attack.Name] or 0
		if dist <= attack.Range and os.clock() - lastTime >= attack.Cooldown then
			table.insert(validAttacks, attack)
		end
	end

	if #validAttacks == 0 then
		print(string.format("[%s] All attacks on cooldown", npc.Name))
		return
	end

	table.sort(validAttacks, function(a, b)
		return (a.Priority or 1) > (b.Priority or 1)
	end)

	local topPriority = validAttacks[1].Priority or 1
	local topAttacks = {}
	for _, attack in ipairs(validAttacks) do
		if (attack.Priority or 1) == topPriority then
			table.insert(topAttacks, attack)
		end
	end

	local chosen = topAttacks[math.random(1, #topAttacks)]

	local debounce = chosen.AttackDebounce or 0
	if os.clock() - (lastAttackEnd[npc] or 0) < debounce then return end

	local animator = npc:FindFirstChildOfClass("Humanoid")
		and npc:FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")

	if not animator then
		print(string.format("[%s] No Animator found, falling back", npc.Name))
		spawnHitbox(npcRoot, npc, chosen)
		return
	end

	local animFolder = ReplicatedStorage:FindFirstChild("Animations")
	local animObject = animFolder and animFolder:FindFirstChild(chosen.AnimationName)

	if not animObject then
		print(string.format("[%s] Animation '%s' not found, falling back", npc.Name, tostring(chosen.AnimationName)))
		spawnHitbox(npcRoot, npc, chosen)
		return
	end

	print(string.format("[%s] Playing animation '%s'", npc.Name, chosen.AnimationName))
	local track = animator:LoadAnimation(animObject)
	activeAnimations[npc] = true

	local animDone = false
	local hitboxDone = false

	local function tryRelease()
		if animDone and hitboxDone then
			activeAnimations[npc] = false
			lastAttackEnd[npc] = os.clock()
			lastAttackTimes[npc][chosen.Name] = os.clock()  -- cooldown starts NOW
			print(string.format("[%s] Attack '%s' fully finished", npc.Name, chosen.Name))
		end
	end

	track.Stopped:Connect(function()
		print(string.format("[%s] Animation '%s' stopped", npc.Name, chosen.AnimationName))
		animDone = true
		tryRelease()
	end)

	track:Play(nil, nil, chosen.AttackSpeed or 1)

	track:GetMarkerReachedSignal("Hit"):Connect(function()
		print(string.format("[%s] Hit marker reached for '%s'", npc.Name, chosen.AnimationName))
		spawnHitbox(npcRoot, npc, chosen, function()
			hitboxDone = true
			tryRelease()
		end)
	end)
end

function CombatManager.cleanup(npc)
	lastAttackTimes[npc] = nil
	activeAnimations[npc] = nil
	lastAttackEnd[npc] = nil
end

return CombatManager
