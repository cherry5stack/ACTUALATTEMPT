local ServerStorage = game:GetService("ServerStorage")
local templates = ServerStorage:WaitForChild("EnemyTemplates")
local enemiesFolder = workspace:WaitForChild("Enemies")

local function spawnEnemy(enemyType, position)
	local template = templates:FindFirstChild(enemyType)
	if not template then 
		warn("No template found for: " .. enemyType)
		return 
	end
	
	

	local clone = template:Clone()
	
	clone:PivotTo(CFrame.new(position))
	clone.Parent = enemiesFolder -- this triggers the ChildAdded in EnemyManager
end

-- example usage
spawnEnemy("Fighter", Vector3.new(0, 5, 0))
spawnEnemy("Fighter", Vector3.new(0, 6, 0))
spawnEnemy("Fighter", Vector3.new(0, 7, 0))


