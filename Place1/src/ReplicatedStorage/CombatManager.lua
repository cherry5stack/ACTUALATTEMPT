local CombatManager = {}
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local SoundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))
local DamageEvent = ReplicatedStorage:WaitForChild("DamageEvent")
local ParticleEvent = ReplicatedStorage:WaitForChild("ParticleEvent")
local TelegraphManager = require(ReplicatedStorage:WaitForChild("TelegraphManager"))
local lastAttackTimes = {}
local activeAnimations = {}
local lastAttackEnd = {}
local spawnTimes = {} -- NEW: tracks os.clock() when each NPC was first seen by tryAttack
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
	Debris:AddItem(part, duration or 0.2)
end

local function isNpcAlive(npc)
	local hum = npc:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function dealDamage(character, amount, worldPos, effectName, emitCount)
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end

	local player = Players:GetPlayerFromCharacter(character)
	hum:TakeDamage(amount)

	local isCrit = amount >= 50

	if player then
		DamageEvent:FireClient(player, worldPos, amount, isCrit)
	end

	if effectName and effectName ~= "" then
		ParticleEvent:FireAllClients(worldPos, effectName, emitCount or 20)
	end
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
			Debris:AddItem(hitboxPart, duration)
		end

		local connection
		connection = RunService.Heartbeat:Connect(function(dt)
			-- Kill hitbox if NPC died mid-swing
			if not isNpcAlive(npc) then
				connection:Disconnect()
				if onFinished then onFinished() end
				return
			end

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
					local hitRoot = character:FindFirstChild("HumanoidRootPart")
					local hitPos = hitRoot and hitRoot.Position or npcRoot.Position
					dealDamage(character, chosen.Damage, hitPos, chosen.ParticleEffect, chosen.EmitCount)
					if hitRoot then
						SoundManager.play(chosen.Sounds and chosen.Sounds.Hit, hitRoot.Position)
					end
				end
			end

			if elapsed >= duration then
				connection:Disconnect()
				if onFinished then onFinished() end
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
				local hitRoot = character:FindFirstChild("HumanoidRootPart")
				local hitPos = hitRoot and hitRoot.Position or npcRoot.Position
				dealDamage(character, chosen.Damage, hitPos, chosen.ParticleEffect, chosen.EmitCount)
				if hitRoot then
					SoundManager.play(chosen.Sounds and chosen.Sounds.Hit, hitRoot.Position)
				end
			end
		end
		if onFinished then onFinished() end
	end
end

function CombatManager.tryAttack(npc, target, data)
	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then return end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end

	if activeAnimations[npc] then return end

	if not lastAttackTimes[npc] then lastAttackTimes[npc] = {} end

	local timeAlive = os.clock() - (spawnTimes[npc] or os.clock()) -- NEW

	local dist = (npcRoot.Position - targetRoot.Position).Magnitude

	local validAttacks = {}
	for _, attack in ipairs(data.Attacks) do
		if not attack then continue end

		if attack.UnlockAfter and timeAlive < attack.UnlockAfter then continue end -- NEW

		local lastTime = lastAttackTimes[npc][attack.Name] or 0
		if dist <= attack.Range and os.clock() - lastTime >= attack.Cooldown then
			table.insert(validAttacks, attack)
		end
	end

	if #validAttacks == 0 then return end

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
		spawnHitbox(npcRoot, npc, chosen)
		return
	end

	local animFolder = ReplicatedStorage:FindFirstChild("Animations")
	local animObject = animFolder and animFolder:FindFirstChild(chosen.AnimationName)

	if not animObject then
		spawnHitbox(npcRoot, npc, chosen)
		return
	end

	local track = animator:LoadAnimation(animObject)
	activeAnimations[npc] = true

	local animDone = false
	local hitboxDone = false
	local hitboxSpawned = false -- prevents double-spawn if marker fires after telegraph already gated it

	local function tryRelease()
		if animDone and hitboxDone then
			activeAnimations[npc] = false
			lastAttackEnd[npc] = os.clock()
			lastAttackTimes[npc][chosen.Name] = os.clock()
		end
	end

	track.Stopped:Connect(function()
		animDone = true
		tryRelease()
	end)

	SoundManager.play(chosen.Sounds and chosen.Sounds.Swing, npcRoot.Position)

	local telegraph = chosen.Telegraph
	local gatesHitbox = telegraph and telegraph.Enabled and telegraph.GatesHitbox

	local function doSpawnHitbox()
		if hitboxSpawned then return end
		hitboxSpawned = true

		if not isNpcAlive(npc) then
			hitboxDone = true
			tryRelease()
			return
		end

		spawnHitbox(npcRoot, npc, chosen, function()
			hitboxDone = true
			tryRelease()
		end)
	end

	-- Start telegraph at swing start (visual cue), regardless of gating mode
	if telegraph and telegraph.Enabled then
		TelegraphManager.play(npc, telegraph, function()
			-- Only this branch actually spawns the hitbox when gating is enabled
			if gatesHitbox then
				doSpawnHitbox()
			end
		end)
	end

	track:Play(nil, nil, chosen.AttackSpeed or 1)

	track:GetMarkerReachedSignal("Hit"):Connect(function()
		-- If gated, the telegraph's onReady is responsible for spawning — skip here
		if gatesHitbox then return end
		doSpawnHitbox()
	end)
end

function CombatManager.cleanup(npc)
	TelegraphManager.cancel(npc)
	lastAttackTimes[npc] = nil
	activeAnimations[npc] = nil
	lastAttackEnd[npc] = nil
	spawnTimes[npc] = nil -- NEW
end

function CombatManager.registerSpawnTime(npc)
	spawnTimes[npc] = os.clock()
end

return CombatManager
