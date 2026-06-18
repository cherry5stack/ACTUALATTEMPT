local TelegraphManager = {}
local TweenService = game:GetService("TweenService")

local activeHighlights: {[Model]: Highlight} = {}
local activeGeneration: {[Model]: number} = {}

local function makeHighlight(npc: Model, color: Color3): Highlight
	local existing = npc:FindFirstChildOfClass("Highlight")
	if existing then existing:Destroy() end

	local hl = Instance.new("Highlight")
	hl.FillColor            = color
	hl.OutlineColor         = color
	hl.FillTransparency     = 1
	hl.OutlineTransparency  = 0.3
	hl.DepthMode            = Enum.HighlightDepthMode.Occluded
	hl.Parent               = npc
	return hl
end

local function tweenTransparency(hl: Highlight, target: number, duration: number)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Linear)
	local tween = TweenService:Create(hl, info, { FillTransparency = target })
	tween:Play()
	return tween
end

function TelegraphManager.play(npc: Model, config: {
	Duration: number,
	Color: Color3,
	FadeIn: number,
	FadeOut: number,
	}, onReady: () -> ())

	TelegraphManager.cancel(npc)

	local myGen = (activeGeneration[npc] or 0) + 1
	activeGeneration[npc] = myGen

	local hl = makeHighlight(npc, config.Color)
	activeHighlights[npc] = hl

	tweenTransparency(hl, 0.4, config.FadeIn)

	task.delay(config.Duration - config.FadeOut, function()
		if activeGeneration[npc] ~= myGen then return end -- cancelled or superseded

		tweenTransparency(hl, 1, config.FadeOut)

		task.delay(config.FadeOut, function()
			if activeGeneration[npc] ~= myGen then return end
			hl:Destroy()
			activeHighlights[npc] = nil
			onReady()
		end)
	end)
end

function TelegraphManager.cancel(npc: Model)
	activeGeneration[npc] = (activeGeneration[npc] or 0) + 1 -- invalidates any pending callbacks

	local hl = activeHighlights[npc]
	if hl and hl.Parent then
		hl:Destroy()
	end
	activeHighlights[npc] = nil
end

return TelegraphManager