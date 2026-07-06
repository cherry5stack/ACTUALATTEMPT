--[[
	ENEMY DATA — field reference

	Each entry describes one enemy archetype. Most fields configure the
	Forbidden AI module and Humanoid; Attacks is a list built with
	mergeAttack(), which clones a base AttacksData entry and lets you
	override any field per-enemy (Damage, Cooldown, AttackDebounce,
	AttackSpeed, etc.) without duplicating the whole attack definition.

	── Core Stats ───────────────────────────────────────────────────
	Health          (number)   Starting/max Humanoid health.
	WalkSpeed       (number)   Humanoid.WalkSpeed.
	DetectionRange  (number)   Max distance to acquire a player as a target
	                           (used by TargetingManager).
	AttackDistance  (number)   Max distance to be considered "in range" to
	                           attack (used by DistanceManager.isInRange).
	DetectionHeightLimit (number?) Max vertical distance (Y) tolerated for
	                           initial detection. Omit for unlimited.
	PursueHeightLimit    (number?) Same as above, but used while in the
	                           pursuit window. Falls back to
	                           DetectionHeightLimit if unset.

	── Pathfinding (Forbidden AI) ───────────────────────────────────
	AgentRadius     (number)   Pathfinding agent radius (collision sizing).
	AgentHeight     (number)   Pathfinding agent height.
	AgentCosts      (table)    Per-label pathfinding cost overrides, e.g.
	                           { Obstacle = math.huge } makes Obstacle-
	                           labelled parts impassable for this enemy.

	── Combat ────────────────────────────────────────────────────────
	Attacks         (table)    List of attacks built via mergeAttack().
	                           Example:
	                             mergeAttack("Punch", {
	                                 AttackDebounce = 0.5,
	                             })
	                           This clones AttacksData["Punch"] and patches
	                           just AttackDebounce, leaving everything else
	                           (Damage, Range, HitboxSize, etc.) untouched.

	                           CAUTION: overrides are a SHALLOW patch. If you
	                           override a nested table field like Telegraph
	                           or Sounds, you must pass the WHOLE nested
	                           table, not just one field inside it, or you'll
	                           accidentally share/mutate the base's table.

	── Phases ────────────────────────────────────────────────────────
	PhaseTransitions (table?)  Ordered list of HP-gated transitions, handled
	                           by PhaseManager. List entries highest
	                           HealthThreshold -> lowest. Each entry:
	                             HealthThreshold (number) fraction of MaxHealth
	                               (e.g. 0.5 = triggers once Health <= 50%)
	                             AnimationName   (string?) plays if found
	                             Duration        (number)  freeze window (sec)
	                             FreezeMovement  (bool?)   default true,
	                               calls ai.Stop(npc) for the duration
	                             Sounds.Transition (string?)
	                             CastAppearance (table?) same shape as an
	                               attack's CastAppearance

	                           Attacks can gate on phase via:
	                             RequiresPhase (number) — attack only valid
	                             once PhaseManager.getCurrentPhase(npc) is
	                             at least this value. Phase 1 = base phase
	                             (no transitions fired yet), phase 2 = after
	                             the first PhaseTransitions entry fires, etc.

	── Audio ─────────────────────────────────────────────────────────
	Sounds.Spawn     (string)  Played when the enemy is set up/spawned.
	Sounds.Death     (string)  Played on humanoid.Died.
	Sounds.Footstep  (string)  Played periodically while humanoid.Running
	                           fires with speed > 0.
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

local EnemyData = {}

EnemyData["Fighter"] = {
	Health         = 100,
	WalkSpeed      = 12,
	DetectionRange = 50,  -- range to FIRST notice a target
	DetectionHeightLimit = 15,  -- studs vertical tolerance
	PursueHeightLimit    = 25,
	PursueRange    = 80,  -- range to STAY engaged once pursuing (NEW)
	PursueLingerTime = 6, -- seconds after losing all targets before reverting to DetectionRange (NEW)
	AgentRadius    = 2,
	AgentHeight    = 5,
	AttackDistance = 5,
	FaceTargetRange  = 40,
	DoorCooldown   = 2,
	Wander = {
		Enabled           = true,
		BreaksDoors       = false,
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
	
	PhaseCooldown = 3, -- minimum 3 seconds after any phase ends before another can begin
	-- Phase 2 triggers once Health <= 50% of MaxHealth (i.e. <= 50).
	-- NPC freezes, plays EnrageRoar (if the animation exists), tints red,
	-- then unlocks EnragedSlam below via RequiresPhase = 2.
	PhaseTransitions = {
		{
			HealthThreshold = 0.5,
			AnimationName   = "Phase2",
			Duration        = 2.5,
			ScaleAnimationToDuration = true,
			FreezeMovement  = true,
			HealthRestorePercent = 0.15,
			Repeatable      = true, -- NEW: can fire again if healed back above 50% and dropped below again
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
			Repeatable      = false, -- default behavior: fires once, never again
		},
		{
			HealthThreshold = 0.2,
			AnimationName   = "Phase2",
			Duration        = 2.5,
			ScaleAnimationToDuration = true, -- NEW: stretches/compresses the anim to fit Duration exactly
			FreezeMovement  = true,
			HealthRestorePercent = 0.15, -- NEW: heals 15% of MaxHealth when this phase triggers
			-- HealthRestoreFlat = 20,   -- NEW: alternative/additional flat HP restore, can combine with the percent
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
			RequiresPhase = 2, -- only usable once the phase-1 transition above has fired
		}),
	},
	Sounds = {
		Spawn    = "FighterSpawn",
		Death    = "FighterDeath",
		Footstep = "FighterFootstep",
	},
	DoorAttackRange = 1,
	BreaksDoors = true,
	DoorDamage  = 15, -- fallback used if DoorAttack isn't set
	DoorAttack  = {
		AnimationName = "Punch", -- reuse an existing animation in ReplicatedStorage.Animations
		AttackSpeed   = 1,
		Cooldown      = 1,
		Damage        = 15,
	},
}

return EnemyData
