local EnemyData = {}

EnemyData["Fighter"] = {
	-- Core stats
	Health = 100,
	Damage = 10,
	WalkSpeed = 12,

	-- Attack settings
	AttackDistance = 5,       -- how close before attacking
	AttackHitboxSize = Vector3.new(4, 4, 4),  -- size of the damage hitbox
	AttackCooldown = 1.5,     -- seconds between attacks

	-- Animations (animation IDs)
	Animations = {
		Idle   = "rbxassetid://YOUR_ID_HERE",
		Walk   = "rbxassetid://YOUR_ID_HERE",
		Jump   = "rbxassetid://YOUR_ID_HERE",
		Fall   = "rbxassetid://YOUR_ID_HERE",
		Attack = "rbxassetid://YOUR_ID_HERE",
		Death  = "rbxassetid://YOUR_ID_HERE",
	},

	-- AI settings
	DetectionRange = 50,      -- how far it can see a player
	AgentRadius = 2.5,        -- for pathfinding
	AgentHeight = 5,
}

EnemyData["Elite Fighter"] = {
	Health = 60,
	Damage = 15,
	WalkSpeed = 16,
	AttackDistance = 4,
	AttackHitboxSize = Vector3.new(3, 4, 3),
	AttackCooldown = 1,
	Animations = {
		Idle   = "rbxassetid://YOUR_ID_HERE",
		Walk   = "rbxassetid://YOUR_ID_HERE",
		Jump   = "rbxassetid://YOUR_ID_HERE",
		Fall   = "rbxassetid://YOUR_ID_HERE",
		Attack = "rbxassetid://YOUR_ID_HERE",
		Death  = "rbxassetid://YOUR_ID_HERE",
	},
	DetectionRange = 70,
	AgentRadius = 2.5,
	AgentHeight = 5,
}

return EnemyData