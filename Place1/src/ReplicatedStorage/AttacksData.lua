local AttacksData = {}

AttacksData["Punch"] = {
	Damage = 10,
	Cooldown = 1,
	Priority = 1,
	AnimationId = "rbxassetid://YOUR_ID_HERE",
	HitboxSize = Vector3.new(4, 4, 4),
	HitboxOffset = 1, -- how far forward from NPC center
	Range = 5, -- how close enemy needs to be to use this attack
}

AttacksData["HeavySlam"] = {
	Damage = 25,
	Cooldown = 3,
	AnimationId = "rbxassetid://YOUR_ID_HERE",
	HitboxSize = Vector3.new(8, 4, 8),
	HitboxOffset = 2,
	Range = 6,
	Priority = 2,
}

return AttacksData