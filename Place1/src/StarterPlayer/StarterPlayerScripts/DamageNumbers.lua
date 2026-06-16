local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local DamageEvent  = ReplicatedStorage:WaitForChild("DamageEvent")
local ParticleEvent = ReplicatedStorage:WaitForChild("ParticleEvent")

-- ── Config ───────────────────────────────────────────────────────────────────
local LIFETIME   = 1.4
local RISE_SPEED = 3.5
local SPREAD     = 2.5

local STYLES = {
	normal = {
		size       = UDim2.fromOffset(100, 40),
		textSize   = 22,
		color      = Color3.fromRGB(255, 75, 75),
		scaleFunc  = function(t) return 1 - t * 0.3 end,
	},
	crit = {
		size       = UDim2.fromOffset(140, 50),
		textSize   = 30,
		color      = Color3.fromRGB(255, 200, 60),
		scaleFunc  = function(t) return 1 + math.sin(t * math.pi) * 0.4 end,
	},
}
-- ─────────────────────────────────────────────────────────────────────────────

local function createLabel(style)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency  = 1
	label.Font                    = Enum.Font.GothamBold
	label.TextStrokeTransparency  = 0.4
	label.TextStrokeColor3        = Color3.new(0, 0, 0)
	label.AnchorPoint             = Vector2.new(0.5, 0.5)
	label.Size                    = style.size
	label.TextColor3              = style.color
	label.TextSize                = style.textSize
	return label
end

local function spawnNumber(worldPos, amount, isCrit)
	local style = isCrit and STYLES.crit or STYLES.normal

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name             = "DmgNum"
	screenGui.ResetOnSpawn     = false
	screenGui.IgnoreGuiInset   = true
	screenGui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
	screenGui.Parent           = player.PlayerGui

	local label = createLabel(style)
	label.Text   = "-" .. tostring(amount)
	label.Parent = screenGui

	local drift = Vector3.new(
		(math.random() - 0.5) * SPREAD,
		0,
		(math.random() - 0.5) * SPREAD
	)
	local pos3D = worldPos + Vector3.new(0, 2.5, 0)
	local born  = os.clock()
	local conn

	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - born
		if elapsed >= LIFETIME then
			conn:Disconnect()
			screenGui:Destroy()
			return
		end

		local t = elapsed / LIFETIME

		pos3D = pos3D + Vector3.new(0, RISE_SPEED * 0.016, 0) + drift * 0.01
		drift = drift * 0.92

		local screenPos, onScreen = camera:WorldToViewportPoint(pos3D)
		if not onScreen then return end

		label.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)

		local scale = style.scaleFunc(t)
		label.TextSize = math.round(style.textSize * scale)

		local alpha = t > 0.6 and (1 - (t - 0.6) / 0.4) or 1
		label.TextTransparency       = 1 - alpha
		label.TextStrokeTransparency = 0.4 + (1 - alpha) * 0.6
	end)
end

local function spawnParticle(worldPos, effectName, emitCount)
	local effectsFolder = ReplicatedStorage:FindFirstChild("ParticleEffects")
	if not effectsFolder then return end

	local template = effectsFolder:FindFirstChild(effectName)
	if not template or not template:IsA("ParticleEmitter") then return end

	local part = Instance.new("Part")
	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.CastShadow   = false
	part.Transparency = 1
	part.Size         = Vector3.new(1, 1, 1)
	part.Position     = worldPos
	part.Parent       = workspace

	local emitter = template:Clone()
	emitter.Parent = part
	emitter:Emit(emitCount)

	Debris:AddItem(part, 2)
end

DamageEvent.OnClientEvent:Connect(function(worldPos, amount, isCrit)
	spawnNumber(worldPos, amount, isCrit)
end)

ParticleEvent.OnClientEvent:Connect(function(worldPos, effectName, emitCount)
	spawnParticle(worldPos, effectName, emitCount)
end)
