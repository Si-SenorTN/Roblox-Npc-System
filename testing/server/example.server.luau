--!strict
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local NpcService = require(ServerScriptService.ServerPackages.NpcService)

local NPC_COUNT = 500
local AREA = 500

NpcService.start()

local template =
	Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
template.Name = "TestRig"

local function randomPoint(): Vector3
	return Vector3.new(math.random(-AREA, AREA), 0, math.random(-AREA, AREA))
end

local function spawnNpc(index: number)
	local npc = NpcService.create(template, {
		SpawnCFrame = CFrame.new(randomPoint() + Vector3.new(0, 5, 0)),
		ThinkHz = 2,
		CustomData = { Name = `Npc{index}` },
		Variant = index % 4,
	})

	npc.Think:Connect(function()
		if npc.MoveTarget == nil and math.random() < 0.5 then
			npc:MoveTo(randomPoint())
		end
	end)

	npc.Died:Connect(function()
		print(`[test] {npc.CustomData.Name} died`)
		task.delay(3, function()
			npc:Destroy()
			spawnNpc(index)
		end)
	end)
end

for index = 1, NPC_COUNT do
	spawnNpc(index)
end

-- Teleport NPC 1 between the center and far away, to check client culling
-- re-checks it immediately
task.spawn(function()
	local far = true
	while true do
		task.wait(4)
		local npc = NpcService.getRecord(1)
		if npc and not npc.IsDead then
			npc:Teleport(CFrame.new(if far then Vector3.new(0, 5, 20) else Vector3.new(900, 5, 900)))
			far = not far
		end
	end
end)
