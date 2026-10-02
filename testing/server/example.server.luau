--!strict
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local NpcService = require(ServerScriptService.ServerPackages.NpcService)

local NPC_COUNT = 500
local AREA = 500
local CULL_DISTANCE = 125

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
	})

	npc.Think:Connect(function()
		if npc.MoveTarget == nil and math.random() < 0.5 then
			npc:MoveTo(randomPoint())
		end
	end)

	npc.Think:Connect(function()
		for _, player in Players:GetPlayers() do
			if player:DistanceFromCharacter(npc.Position) > CULL_DISTANCE then
				npc:SetPlayerVisibleFlag(player, false)
			else
				npc:SetPlayerVisibleFlag(player, true)
			end
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
