local AttacksData = {}

--default debounce is 1 second
AttacksData["Punch"] = {
	Damage = 10,
	Cooldown = 1,
	AttackDebounce = 1, --time to no be able to trigger another attack after casting this attack
	Priority = 1,
	AnimationName = "Punch",   -- matches Animation object name in RS.Animations
	HitboxSize = Vector3.new(4, 4, 4),
	HitboxOffset = 1,
	Range = 5,
	AttackSpeed = 1,
}

AttacksData["HeavySlam"] = {
	Damage = 100,
	PerTick = 0.5,
	Cooldown = 13,
	AnimationName = "Kick",
	HitboxSize = Vector3.new(8, 4, 8),
	HitboxOffset = 2,
	Range = 6,
	Priority = 2,
	HitboxDuration = 3,
	StaticHitbox = true,
	ParticleEffect = "SlamEffect",  -- name of ParticleEmitter in RS.ParticleEffects
	AttackSpeed = 0.5,
}

return AttacksData
