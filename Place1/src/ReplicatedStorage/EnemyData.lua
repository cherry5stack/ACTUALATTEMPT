--[[
	ENEMY DATA — field reference
	(full field docs unchanged from original header — trimmed here for brevity)

	ComfortDistance (number)  How close the NPC prefers to stand once engaged.
	                          Checked fresh every tick in EnemyManager against
	                          live distance -- NOT tied to Tracking's retrack
	                          timer, so it reacts immediately even if the
	                          target barely moves.

	AttackDistance is auto-derived from the max Range across Attacks below --
	do not hand-set it, or it can drift out of sync with what attacks can
	actually reach (this caused a real freeze bug previously).
]]
local AttacksData = require(game.ReplicatedStorage.AttacksData)

local function mergeAttack(baseName, overrides)
	local base = AttacksData[baseName]
	if not base then warn("No attack found: " .. baseName) return nil end
	local merged = table.clone(base)
	merged.Name = baseName
	if overrides then
		for k, v in pairs(overrides) do
			merged[k] = v
		end
	end
	return merged
end

-- Derives the max usable attack range from a built Attacks list.
local function getMaxAttackRange(attacks)
	local max = 0
	for _, atk in ipairs(attacks) do
		if atk and atk.Range and atk.Range > max then
			max = atk.Range
		end
	end
	return max
end

local EnemyData = {}

EnemyData["Fighter"] = {
	Health         = 100,
	WalkSpeed      = 12,
	DetectionRange = 50,
	DetectionHeightLimit = 15,
	PursueHeightLimit    = 25,
	PursueRange    = 80,
	PursueLingerTime = 6,
	AgentRadius    = 2,
	AgentHeight    = 5,

	-- ComfortDistance: how close the NPC prefers to stand once engaged.
	-- Should generally be <= the shortest attack Range you want reliably
	-- usable, and always <= the derived AttackDistance below.
	ComfortDistance = 4,

	-- AttackDistance is derived below from Attacks -- do not set here.
	DoorInteractionRange = 8,
	FaceTargetRange  = 40,
	DoorCooldown   = 2,
	Wander = {
		Enabled           = true,
		BreaksDoors       = true,
		MinWanderWait     = 1,
		MaxWanderWait     = 2,
		MinWanderDistance = 10,
		MaxWanderDistance = 25,
		PostCombatDelay   = 5,
	},

	AgentCosts = {
		Obstacle    = math.huge,
		CrackedLava = math.huge,
	},

	PhaseCooldown = 3,
	PhaseTransitions = {
		{
			HealthThreshold = 0.5,
			AnimationName   = "Phase2",
			Duration        = 2.5,
			ScaleAnimationToDuration = true,
			FreezeMovement  = true,
			HealthRestorePercent = 0.15,
			Repeatable      = true,
			Sounds = { Transition = "BossRoar" },
			CastAppearance = {
				Enabled     = true,
				Color       = Color3.fromRGB(255, 30, 30),
				FadeInTime  = 0.3,
				FadeOutTime = 0.4,
			},
		},
		{
			HealthThreshold = 0.49,
			Duration        = 1.5,
			Repeatable      = false,
		},
		{
			HealthThreshold = 0.2,
			AnimationName   = "Phase2",
			Duration        = 2.5,
			ScaleAnimationToDuration = true,
			FreezeMovement  = true,
			HealthRestorePercent = 0.15,
			Sounds = { Transition = "BossRoar" },
			CastAppearance = {
				Enabled     = true,
				Color       = Color3.fromRGB(255, 30, 30),
				FadeInTime  = 0.3,
				FadeOutTime = 0.4,
			},
		},
	},
	Attacks = {
		mergeAttack("Punch"),
		mergeAttack("HeavySlam", {
			Damage   = 51,
			Cooldown = 4,
		}),
		mergeAttack("EnragedSlam", {
			RequiresPhase = 2,
		}),
	},
	Sounds = {
		Spawn    = "FighterSpawn",
		Death    = "FighterDeath",
		Footstep = "FighterFootstep",
	},

	DoorAttackHeight = 5,
	BreaksDoors = true,
	DoorDamage  = 15,
	DoorAttack = {
		AnimationName = "Punch",
		AttackSpeed   = 1,
		Cooldown      = 1,
		Damage        = 15,
		AttackRange   = 5,
	},

	Flee = {
		Enabled          = true,
		HealthThreshold  = 0.25,
		FleeSpeed        = 18,
		FleeDistance     = 30,
		ResumeRange      = 40,
		BreaksDoors      = false,
	},
}

-- Derive AttackDistance for every enemy from its actual Attacks list, and
-- warn if ComfortDistance would put the NPC outside every attack's reach.
for name, data in pairs(EnemyData) do
	data.AttackDistance = getMaxAttackRange(data.Attacks)

	if data.ComfortDistance and data.ComfortDistance > data.AttackDistance then
		warn(string.format(
			"[EnemyData] '%s': ComfortDistance (%.1f) exceeds max attack Range (%.1f) -- NPC may stand out of range of all attacks!",
			name, data.ComfortDistance, data.AttackDistance
			))
	end
end

return EnemyData
