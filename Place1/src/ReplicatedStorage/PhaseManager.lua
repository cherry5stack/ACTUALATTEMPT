local PhaseManager = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))
local AppearanceManager = require(ReplicatedStorage:WaitForChild("AppearanceManager"))

-- Per-NPC state.
-- phases: the list of phase configs from EnemyData.PhaseTransitions, checked
--   in list order (so list them highest HealthThreshold -> lowest).
-- phaseRuntime[i]: per-phase fired/rearm tracking, indexed to match `phases`.
-- transitioning: true while the freeze/animation window is active.
-- queuedPhaseIndex: index of a phase that became eligible while transitioning
--   (or while waiting out PhaseCooldown), to be fired once clear. Cleared if
--   health recovers above that phase's threshold before its turn comes up.
-- lastPhaseEndTime: os.clock() when the last transition's freeze ended.
local PhaseState: {[Model]: {
	phases: {any},
	phaseRuntime: {[number]: {fired: boolean, rearmed: boolean}},
	transitioning: boolean,
	generation: number,
	lastPhaseEndTime: number,
	phaseCooldown: number,
	queuedPhaseIndex: number?,
}} = {}

-- @param phaseCooldown (number?) Minimum seconds required after one phase's
--   freeze ends before another phase is allowed to begin. Default 0 (none).
function PhaseManager.registerPhases(npc: Model, phases: {any}?, phaseCooldown: number?)
	if PhaseState[npc] then return end -- already registered

	local phaseList = phases or {}
	local runtime = {}
	for i = 1, #phaseList do
		runtime[i] = {fired = false, rearmed = true}
	end

	PhaseState[npc] = {
		phases = phaseList,
		phaseRuntime = runtime,
		transitioning = false,
		generation = 0,
		lastPhaseEndTime = 0,
		phaseCooldown = phaseCooldown or 0,
		queuedPhaseIndex = nil,
	}
end

-- Current phase number, 1-indexed, based on how many DISTINCT phase slots
-- have ever fired at least once.
function PhaseManager.getCurrentPhase(npc: Model): number
	local state = PhaseState[npc]
	if not state then return 1 end

	local firedCount = 0
	for i = 1, #state.phases do
		if state.phaseRuntime[i].fired then
			firedCount += 1
		else
			break
		end
	end
	return firedCount + 1
end

function PhaseManager.isTransitioning(npc: Model): boolean
	local state = PhaseState[npc]
	return state ~= nil and state.transitioning
end

local function applyHealthRecovery(humanoid: Humanoid, phase)
	if not humanoid or humanoid.Health <= 0 then return end

	local restoreAmount = 0

	if phase.HealthRestorePercent then
		restoreAmount += humanoid.MaxHealth * phase.HealthRestorePercent
	end

	if phase.HealthRestoreFlat then
		restoreAmount += phase.HealthRestoreFlat
	end

	if restoreAmount > 0 then
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + restoreAmount)
	end
end

local function beginTransition(npc: Model, humanoid: Humanoid, phase, phaseIndex: number, ai)
	local state = PhaseState[npc]
	state.transitioning = true
	state.queuedPhaseIndex = nil -- this phase is now running, not queued

	local myGen = state.generation + 1
	state.generation = myGen

	state.phaseRuntime[phaseIndex].fired = true
	state.phaseRuntime[phaseIndex].rearmed = false

	if phase.FreezeMovement ~= false and ai then
		ai.Stop(npc)
	end

	applyHealthRecovery(humanoid, phase)

	local npcRoot = npc:FindFirstChild("HumanoidRootPart")

	if phase.Sounds and phase.Sounds.Transition and npcRoot then
		SoundManager.play(phase.Sounds.Transition, npcRoot.Position)
	end

	if phase.CastAppearance and phase.CastAppearance.Enabled then
		AppearanceManager.tintModel(npc, phase.CastAppearance.Color, phase.CastAppearance.FadeInTime)
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	local animFolder = ReplicatedStorage:FindFirstChild("Animations")
	local animObject = phase.AnimationName and animFolder and animFolder:FindFirstChild(phase.AnimationName)

	if animator and animObject then
		local track = animator:LoadAnimation(animObject)

		local playbackSpeed = 1
		if phase.ScaleAnimationToDuration and phase.Duration and track.Length > 0 then
			playbackSpeed = track.Length / phase.Duration
		end

		track:Play(nil, nil, playbackSpeed)
	end

	task.delay(phase.Duration or 2, function()
		if state.generation ~= myGen then return end

		if phase.CastAppearance and phase.CastAppearance.Enabled then
			AppearanceManager.restoreModel(npc, phase.CastAppearance.FadeOutTime)
		end

		state.transitioning = false
		state.lastPhaseEndTime = os.clock()
	end)
end

-- Finds the first phase (in list order) currently eligible to fire given
-- the NPC's health. Updates rearm tracking for Repeatable phases as a side
-- effect. Returns nil if nothing is eligible right now.
local function findEligiblePhase(state, healthFraction): number?
	for i, phase in ipairs(state.phases) do
		local runtime = state.phaseRuntime[i]

		if phase.Repeatable and runtime.fired and healthFraction > phase.HealthThreshold then
			runtime.rearmed = true
		end

		local eligible = (not runtime.fired) or (phase.Repeatable and runtime.rearmed)

		if eligible and healthFraction <= phase.HealthThreshold then
			return i
		end
	end
	return nil
end

-- Call every tick (e.g. from EnemyManager's main loop) while the NPC is alive.
function PhaseManager.update(npc: Model, humanoid: Humanoid, ai)
	local state = PhaseState[npc]
	if not state then return end
	if humanoid.Health <= 0 then return end

	local healthFraction = humanoid.Health / humanoid.MaxHealth
	local eligibleIndex = findEligiblePhase(state, healthFraction)

	if not eligibleIndex then
		-- nothing eligible right now (e.g. healed back above every pending
		-- threshold) -- clear any stale queue entry so it doesn't fire later
		-- for a condition that no longer holds.
		state.queuedPhaseIndex = nil
		return
	end

	-- Already mid-transition: queue this phase to run once clear, instead
	-- of firing now.
	if state.transitioning then
		state.queuedPhaseIndex = eligibleIndex
		return
	end

	-- Not transitioning, but still inside the post-phase cooldown window:
	-- queue it and wait.
	if state.phaseCooldown > 0 and state.lastPhaseEndTime > 0 then
		if os.clock() - state.lastPhaseEndTime < state.phaseCooldown then
			state.queuedPhaseIndex = eligibleIndex
			return
		end
	end

	state.queuedPhaseIndex = nil
	beginTransition(npc, humanoid, state.phases[eligibleIndex], eligibleIndex, ai)
end

function PhaseManager.cleanup(npc: Model)
	local state = PhaseState[npc]
	if state then
		state.generation += 1
	end
	PhaseState[npc] = nil
end

return PhaseManager