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
	PursueRange    = 80,  -- range to STAY engaged once pursuing (NEW)
	PursueLingerTime = 6, -- seconds after losing all targets before reverting to DetectionRange (NEW)
	AgentRadius    = 2,
	AgentHeight    = 5,
	AttackDistance = 5,
	FaceTargetRange  = 20,

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

	Attacks = {
		mergeAttack("Punch"),
		mergeAttack("HeavySlam", {
			Damage   = 51,
			Cooldown = 4,
		}),
	},
	Sounds = {
		Spawn    = "FighterSpawn",
		Death    = "FighterDeath",
		Footstep = "FighterFootstep",
	},
}

return EnemyData
