local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local DamageEvent  = ReplicatedStorage:WaitForChild("DamageEvent")
local ParticleEvent = ReplicatedStorage:WaitForChild("ParticleEvent")

local LIFETIME   = 1.4
local RISE_SPEED = 3.5
local SPREAD     = 2.5

local function spawnNumber(worldPos, amount, isCrit)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DmgNum"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = player.PlayerGui

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = isCrit and UDim2.fromOffset(140, 50) or UDim2.fromOffset(100, 40)
	label.TextColor3 = isCrit
		and Color3.fromRGB(255, 200, 60)
		or  Color3.fromRGB(255, 75, 75)
	label.TextSize = isCrit and 30 or 22
	label.Text = "-" .. amount
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

		local scale = isCrit
			and (1 + math.sin(t * math.pi) * 0.4)
			or  (1 - t * 0.3)
		label.TextSize = math.round((isCrit and 30 or 22) * scale)

		local alpha = t > 0.6 and (1 - (t - 0.6) / 0.4) or 1
		label.TextTransparency = 1 - alpha
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