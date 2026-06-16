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
	DetectionRange = 50,
	AgentRadius    = 2,
	AgentHeight    = 5,
	AttackDistance = 5,

	AgentCosts = {
		Obstacle   = math.huge,
		CrackedLava = math.huge,
	},

	Attacks = {
		mergeAttack("Punch"),
		mergeAttack("HeavySlam", {
			Damage  = 51,
			Cooldown = 4,
		}),
	},
	Sounds = {
		Spawn     = "FighterSpawn",
		Death     = "FighterDeath",
		Footstep  = "FighterFootstep",
	},
}

return EnemyData
