-- CombatManager.lua
local CombatManager = {}
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local SoundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))
local TelegraphManager = require(ReplicatedStorage:WaitForChild("TelegraphManager"))
local AppearanceManager = require(ReplicatedStorage:WaitForChild("AppearanceManager"))
local PhaseManager = require(ReplicatedStorage:WaitForChild("PhaseManager"))
local DamageEvent = ReplicatedStorage:WaitForChild("DamageEvent")
local ParticleEvent = ReplicatedStorage:WaitForChild("ParticleEvent")

local lastAttackTimes = {}
-- activeAnimations removed: attacks are gated only by Cooldown and AttackDebounce
local lastAttackEnd = {}
local spawnTimes = {}
local standingStill = {} -- [npc] = true while StandStillAfter is active
local DEBUG = true

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

function CombatManager.registerSpawnTime(npc)
	spawnTimes[npc] = os.clock()
end

function CombatManager.isStandingStill(npc)
	return standingStill[npc] == true
end

function CombatManager.tryAttack(npc, target, data)
	if DEBUG then print(string.format("[%s] tryAttack called", npc.Name)) end
	if not isNpcAlive(npc) then if DEBUG then print(string.format("[%s] tryAttack — NPC dead", npc.Name)) end return end
	if PhaseManager.isTransitioning(npc) then if DEBUG then print(string.format("[%s] tryAttack — phase transitioning", npc.Name)) end return end

	local npcRoot = npc:FindFirstChild("HumanoidRootPart")
	if not npcRoot then if DEBUG then print(string.format("[%s] tryAttack — no npcRoot", npc.Name)) end return end

	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then if DEBUG then print(string.format("[%s] tryAttack — no targetRoot", npc.Name)) end return end

	local targetHum = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	if not targetHum or targetHum.Health <= 0 then if DEBUG then print(string.format("[%s] tryAttack — target dead/missing", npc.Name)) end return end


	if not lastAttackTimes[npc] then lastAttackTimes[npc] = {} end

	local timeAlive = os.clock() - (spawnTimes[npc] or os.clock())
	local npcPos = npcRoot.Position
	local targetPos = targetRoot.Position
	local dist = Vector3.new(npcPos.X - targetPos.X, 0, npcPos.Z - targetPos.Z).Magnitude

	local validAttacks = {}
	for _, attack in ipairs(data.Attacks) do
		if not attack then continue end
		if attack.UnlockAfter and timeAlive < attack.UnlockAfter then continue end
		if attack.RequiresPhase and PhaseManager.getCurrentPhase(npc) < attack.RequiresPhase then continue end

		local lastTime = lastAttackTimes[npc][attack.Name] or 0
		if dist <= attack.Range and os.clock() - lastTime >= (attack.Cooldown or 0) then
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

	-- While standing still (from a previous StandStillAfter), only block attacks
	-- that themselves have StandStillAfter — let quick attacks like Punch through.
	-- Set the cooldown before returning so HeavySlam can't monopolize the slot
	-- every tick while standingStill is active.
	if standingStill[npc] and (chosen.StandStillAfter and chosen.StandStillAfter > 0) then
		lastAttackTimes[npc][chosen.Name] = os.clock()
		return
	end

	-- AttackDebounce: set at cast time — blocks ALL attacks until it expires.
	-- Cooldown: set when the Hit marker fires — blocks THIS attack specifically.
	lastAttackEnd[npc] = os.clock()

	if DEBUG then
		print(string.format("[%s] Attack '%s' cast.", npc.Name, chosen.Name))
	end

	local animator = npc:FindFirstChildOfClass("Humanoid")
		and npc:FindFirstChildOfClass("Humanoid"):FindFirstChildOfClass("Animator")

	if not animator then
		if DEBUG then print(string.format("[%s] No animator — spawning hitbox directly.", npc.Name)) end
		lastAttackTimes[npc][chosen.Name] = os.clock()
		spawnHitbox(npcRoot, npc, chosen)
		return
	end

	local animFolder = ReplicatedStorage:FindFirstChild("Animations")
	local animObject = animFolder and animFolder:FindFirstChild(chosen.AnimationName)

	if not animObject then
		if DEBUG then print(string.format("[%s] No animation '%s' — spawning hitbox directly.", npc.Name, chosen.AnimationName)) end
		lastAttackTimes[npc][chosen.Name] = os.clock()
		spawnHitbox(npcRoot, npc, chosen)
		return
	end

	local track = animator:LoadAnimation(animObject)

	local castAppearance = chosen.CastAppearance

	SoundManager.play(chosen.Sounds and chosen.Sounds.Swing, npcRoot.Position)

	local telegraph = chosen.Telegraph
	if telegraph and telegraph.Enabled then
		TelegraphManager.play(npc, telegraph, function() end)
	end

	if castAppearance and castAppearance.Enabled then
		AppearanceManager.tintModel(npc, castAppearance.Color, castAppearance.FadeInTime)
	end

	if chosen.StandStillAfter and chosen.StandStillAfter > 0 then
		standingStill[npc] = true
		if DEBUG then
			print(string.format(
				"[%s] StandStillAfter %.2fs starting now.",
				npc.Name, tonumber(chosen.StandStillAfter) or 0
				))
		end
		task.delay(chosen.StandStillAfter, function()
			if not isNpcAlive(npc) then
				standingStill[npc] = nil
				return
			end
			standingStill[npc] = nil
			if DEBUG then
				print(string.format(
					"[%s] StandStillAfter %.2fs elapsed — free to move again.",
					npc.Name, tonumber(chosen.StandStillAfter) or 0
					))
			end
		end)
	end

	track:Play(nil, nil, chosen.AttackSpeed or 1)

	track:GetMarkerReachedSignal("Hit"):Connect(function()
		if not isNpcAlive(npc) then return end
		-- Per-attack Cooldown starts when the hit lands, not when cast.
		lastAttackTimes[npc][chosen.Name] = os.clock()
		spawnHitbox(npcRoot, npc, chosen)
		if castAppearance and castAppearance.Enabled then
			AppearanceManager.restoreModel(npc, castAppearance.FadeOutTime)
		end
	end)
end

function CombatManager.cleanup(npc)
	TelegraphManager.cancel(npc)
	AppearanceManager.cleanup(npc)
	PhaseManager.cleanup(npc)
	standingStill[npc] = nil
	lastAttackTimes[npc] = nil
	lastAttackEnd[npc] = nil
	spawnTimes[npc] = nil
end

return CombatManager
