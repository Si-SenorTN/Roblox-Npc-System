--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NpcController = require(ReplicatedStorage.Packages.NpcController)

NpcController.NpcAdded:Connect(function(npc)
	npc.Died:Connect(function()
		print(`[test] client saw {npc.CustomData.Name} die`)
	end)
	if npc.Id == 1 then
		npc.VisibilityChanged:Connect(function(visible)
			print(`[test] Npc 1 visible: {visible}`)
		end)
	end
end)

NpcController.start()

while true do
	task.wait(5)
	local visible = 0
	local records = NpcController.getRecords()
	for _, npc in records do
		if npc.Visible then
			visible += 1
		end
	end
	print(`[test] {#records} NPCs, {visible} visible`)
end
