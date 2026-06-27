--[[
	ATTACKS DATA — field reference

	Each attack is a table of properties consumed by CombatManager.tryAttack()
	and spawnHitbox(). Fields are grouped below by what system reads them.

	── Identity / Animation ──────────────────────────────────────────
	AnimationName   (string)   Name of the Animation object in RS.Animations
	                           to play when this attack triggers.
	AttackSpeed     (number)   Playback speed multiplier for the animation.
	                           1 = normal speed, 0.5 = half speed (slower,
	                           good for heavy/dramatic windups), 1.5 = faster.
	                           Does NOT affect cooldown or damage timing,
	                           purely how fast the animation track plays.

	── Timing / Pacing ────────────────────────────────────────────────
	Cooldown        (number)   Seconds before THIS SPECIFIC attack (by name)
	                           can be reused again. Tracked per attack-name,
	                           so Punch and HeavySlam cooldowns are independent.
	AttackDebounce  (number)   Seconds the NPC must wait after THIS attack
	                           finishes before starting ANY attack (including
	                           a different one). This is a global "still
	                           recovering" gate, separate from Cooldown.
	                           Default is 0 if omitted (no extra wait).
	Priority        (number)   When multiple attacks are valid at once (in
	                           range + off cooldown), higher Priority wins.
	                           Ties are randomly chosen among the top group.

	── Hitbox ─────────────────────────────────────────────────────────
	Damage          (number)   Damage dealt per hit.
	Range           (number)   Max distance from NPC to target for this
	                           attack to be considered usable at all.
	HitboxSize      (Vector3)  Size of the hitbox box used for hit detection.
	HitboxOffset    (number)   Studs in front of the NPC the hitbox is placed.
	HitboxDuration  (number?)  If set (>0), hitbox stays active for this many
	                           seconds, ticking instead of a single instant
	                           check. Used for AoE/channeled attacks.
	PerTick         (number?)  Only relevant if HitboxDuration is set — how
	                           often (seconds) a single target can be hit
	                           again while inside a duration-based hitbox.
	StaticHitbox    (bool?)    If true, the hitbox CFrame is locked at the
	                           position/rotation it had when it spawned,
	                           instead of following the NPC's current CFrame
	                           every tick (relevant only with HitboxDuration).

	── Audio ──────────────────────────────────────────────────────────
	Sounds.Swing    (string)   Sound name (in RS.Sounds) played when the
	                           animation starts.
	Sounds.Hit      (string)   Sound name played when the hitbox connects.

	── Telegraph (windup highlight) ────────────────────────────────────
	Telegraph.Enabled   (bool)    If false, no highlight at all — hitbox
	                              fires exactly at the animation's "Hit"
	                              marker, same as if Telegraph didn't exist.
	Telegraph.Duration  (number)  Total seconds the highlight glow lasts,
	                              start to finish (fade in + hold + fade out).
	Telegraph.Color     (Color3)  Highlight fill/outline color.
	Telegraph.FadeIn    (number)  Seconds for the glow to fade in from
	                              invisible to visible.
	Telegraph.FadeOut   (number)  Seconds for the glow to fade back out
	                              before the hitbox spawns.

	NOTE: Telegraph and the Hit marker are two SEPARATE timers when
	Telegraph.Enabled = true. The hitbox spawns at the Hit marker as
	normal — Telegraph.Duration is purely visual and does not delay or
	gate the hitbox. Tune Duration to roughly match where your Hit
	marker sits in the animation if you want them to look synced.
]]

--[[
	Cooldown vs AttackDebounce — quick distinction

	Cooldown        → "How long until I can use THIS SAME move again?"
	                   Scoped per attack-name. Punch and HeavySlam track
	                   their own independent cooldown timers.

	AttackDebounce  → "How long must I wait after ANY attack before doing
	                   ANYTHING else (including a different attack)?"
	                   Global per-NPC gate, checked against the time the
	                   NPC's last attack finished (lastAttackEnd[npc]).

	Example: Punch.Cooldown = 1, HeavySlam.AttackDebounce = 1.5
	  -> Punch itself can be reused every 1s.
	  -> But right after a HeavySlam finishes, NO attack (not even Punch)
	     can start for 1.5s, even if Punch's own cooldown already expired.
]]

--[[
	UnlockAfter   (number?)   Seconds the NPC must have been alive before
	                          this attack becomes usable at all. Omit or
	                          set to 0 for attacks available immediately
	                          on spawn. Checked against spawn time, NOT
	                          time since last use.
]]
--[[
	CastAppearance (table?)   Optional color tint applied to the NPC's whole
	                          body while this attack's animation plays.
	CastAppearance.Enabled        (bool)    Turns the tint on/off for this attack.
	CastAppearance.Color          (Color3)  Color tint applied at swing start.
	CastAppearance.FadeInTime     (number)  Seconds to tween into the tint color.
	CastAppearance.FadeOutTime    (number)  Seconds to tween back to original
	                                        color once the animation finishes.
]]


local AttacksData = {}

--default debounce is 1 second
AttacksData["Punch"] = {
	Damage = 10,
	Cooldown = 1,
	AttackDebounce = 1,
	Priority = 1,
	AnimationName = "Punch",
	HitboxSize = Vector3.new(4, 4, 4),
	HitboxOffset = 1,
	Range = 5,
	AttackSpeed = 1,
	Sounds = {
		Swing = "PunchSwing",
		Hit   = "PunchHit",
	},
	Telegraph = {
		Enabled = false,
	},
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
	AttackSpeed = 0.5,
	StandStillAfter = 10, 
	Sounds = {
		Swing = "PunchSwing",
		Hit   = "PunchHit",
	},
	Telegraph = {
		Enabled  = true,
		Duration = 1.2,
		Color    = Color3.fromRGB(255, 50, 50),
		FadeIn   = 0.15,
		FadeOut  = 0.2,
		GatesHitbox  = false,
		-- if true, hitbox waits for telegraph to finish will cast after telegraph is done, ignores Hit marker timing completely
		--if false, hitbox and telegraph and 2 different timers, telehraph is just visual, hitbox triggers are normal
	},
	CastAppearance = {
		Enabled     = true,
		Color       = Color3.fromRGB(120, 0, 150), -- purple while winding up
		FadeInTime  = 0.2,
		FadeOutTime = 0.3,
	},
}

AttacksData["EnragedSlam"] = {
	Damage = 80,
	Cooldown = 6,
	AnimationName = "Kick",
	HitboxSize = Vector3.new(6, 4, 6),
	HitboxOffset = 2,
	Range = 6,
	Priority = 3, -- higher than normal attacks once unlocked, so it gets picked
	AttackSpeed = 0.8,
	Sounds = {
		Swing = "PunchSwing",
		Hit   = "PunchHit",
	},
	Telegraph = {
		Enabled  = true,
		Duration = 1,
		Color    = Color3.fromRGB(255, 120, 0),
		FadeIn   = 0.15,
		FadeOut  = 0.2,
	},
	UnlockAfter = 15, -- only usable once this NPC has been alive 15+ seconds
}

return AttacksData
