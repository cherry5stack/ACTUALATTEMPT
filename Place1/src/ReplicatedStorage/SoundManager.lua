local SoundManager = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

function SoundManager.play(name, position)
	if not name or name == "" then return end
	local soundsFolder = ReplicatedStorage:FindFirstChild("Sounds")
	if not soundsFolder then return end
	local sound = soundsFolder:FindFirstChild(name)
	if not sound or not sound:IsA("Sound") then return end

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Transparency = 1
	part.Position = position
	part.Parent = workspace

	local clone = sound:Clone()
	clone.Parent = part
	clone:Play()

	Debris:AddItem(part, clone.TimeLength + 0.5)
end

return SoundManager