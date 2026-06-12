local AttacksData = require(game.ReplicatedStorage.AttacksData)

local function mergeAttack(baseName, overrides)
	local base = AttacksData[baseName]
	if not base then warn("No attack found: " .. baseName) return nil end
	local merged = table.clone(base)
	merged.Name = baseName -- store the key as the name
	if overrides then
		for k, v in pairs(overrides) do
			merged[k] = v
		end
	end
	return merged
end

local EnemyData = {}

EnemyData["Fighter"] = {
	
	Health = 100,
	WalkSpeed = 12,
	DetectionRange = 50,
	AgentRadius = 2.5,
	AgentHeight = 5,
	AttackDistance = 5,

	Attacks = {
		mergeAttack("Punch"), -- uses base values as-is
		mergeAttack("HeavySlam", { -- overrides specific fields
			Damage = 30,
			Cooldown = 2,
		}),
	},
}

return EnemyData
