local AppearanceManager = {}
local TweenService = game:GetService("TweenService")

-- Stores each NPC's original part colors so we can restore them later.
-- Keyed by NPC model, value is {[BasePart] = Color3}
local originalColors: {[Model]: {[BasePart]: Color3}} = {}

-- Tracks a "generation" counter per NPC so stale tweens/timers from a
-- cancelled or overlapping cast don't stomp on a newer one.
local activeGeneration: {[Model]: number} = {}

local function captureOriginalColors(npc: Model)
	if originalColors[npc] then return end -- already captured

	originalColors[npc] = {}
	for _, part in npc:GetDescendants() do
		if part:IsA("BasePart") then
			originalColors[npc][part] = part.Color
		end
	end
end

-- Tints every BasePart in the model to `color` over `duration` seconds.
-- Call this when the cast/attack starts.
function AppearanceManager.tintModel(npc: Model, color: Color3, duration: number?)
	duration = duration or 0.15

	captureOriginalColors(npc)

	local myGen = (activeGeneration[npc] or 0) + 1
	activeGeneration[npc] = myGen

	local saved = originalColors[npc]
	for part, _ in saved do
		if part.Parent then
			TweenService:Create(part, TweenInfo.new(duration), {Color = color}):Play()
		end
	end
end

-- Restores every BasePart back to its original color over `duration` seconds.
-- Call this when the cast/attack finishes (e.g. track.Stopped).
function AppearanceManager.restoreModel(npc: Model, duration: number?)
	duration = duration or 0.2

	local saved = originalColors[npc]
	if not saved then return end

	local myGen = (activeGeneration[npc] or 0) + 1
	activeGeneration[npc] = myGen

	for part, originalColor in saved do
		if part.Parent then
			TweenService:Create(part, TweenInfo.new(duration), {Color = originalColor}):Play()
		end
	end
end

-- Call this on death or whenever the NPC is being torn down, so we don't
-- leak the stored color table or keep tweening a destroyed model.
function AppearanceManager.cleanup(npc: Model)
	originalColors[npc] = nil
	activeGeneration[npc] = nil
end

return AppearanceManager