--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local NpcController = require(ReplicatedStorage.Packages.NpcController)

local CULL_DISTANCE = 300

local modelsAdded = 0
NpcController.ModelAdded:Connect(function(_npc, model)
	assert(model.Parent ~= nil, "ModelAdded should fire with the rig in the world")
	modelsAdded += 1
end)

NpcController.NpcAdded:Connect(function(npc)
	npc.Died:Connect(function()
		print(`[test] client saw {npc.CustomData.Name} die`)
	end)
	if npc.Id == 1 then
		npc.RenderedChanged:Connect(function(rendered)
			local camera = Workspace.CurrentCamera.CFrame.Position
			print(`[test] Npc 1 rendered: {rendered} at {math.round((npc.Position - camera).Magnitude)} studs`)
		end)
	end
end)

NpcController.start()

-- Count distance checks per frame by watching when each record's next check
-- gets rescheduled (reading a private field, test only)
local checks, frames = 0, 0
local lastScheduled: { [any]: number } = {}
RunService.PostSimulation:Connect(function()
	frames += 1
	for _, npc in NpcController.getRecords() do
		local scheduled = (npc :: any)._nextCullCheck
		if lastScheduled[npc] ~= scheduled then
			lastScheduled[npc] = scheduled
			checks += 1
		end
	end
end)

while true do
	task.wait(5)
	local camera = Workspace.CurrentCamera.CFrame.Position
	local rendered, culled, wrongShown, wrongHidden = 0, 0, 0, 0
	local placements: { [string]: number } = { Attached = 0, Parked = 0, Detached = 0 }
	local healthMismatches = 0
	local variantMismatches = 0
	local records = NpcController.getRecords()
	for _, npc in records do
		local distance = (npc.Position - camera).Magnitude
		if npc.IsRendered then
			rendered += 1
		end
		local index = tonumber(string.match(npc.CustomData.Name, "%d+"))
		if index and npc.Variant ~= index % 4 then
			variantMismatches += 1
		end
		local placement = (npc :: any)._placement
		placements[placement] += 1
		local humanoid = npc.Model and npc.Model:FindFirstChildOfClass("Humanoid")
		if humanoid and (humanoid.Health ~= npc.Health or humanoid.MaxHealth ~= npc.MaxHealth) then
			healthMismatches += 1
		end
		if npc.IsCulled then
			culled += 1
			if distance < CULL_DISTANCE - 1 then
				wrongHidden += 1
			end
		elseif distance > CULL_DISTANCE + 11 then
			wrongShown += 1
		end
	end
	print(
		`[test] {#records} NPCs, {rendered} rendered, {culled} culled, `
			.. `wrongly culled {wrongHidden}, wrongly shown {wrongShown}, `
			.. `{string.format("%.1f", checks / math.max(frames, 1))} checks/frame, `
			.. `attached {placements.Attached}, parked {placements.Parked}, detached {placements.Detached}, `
			.. `humanoid health mismatches {healthMismatches}, variant mismatches {variantMismatches}, `
			.. `models created {modelsAdded}, replicated NpcSystem instances {#ReplicatedStorage
				:WaitForChild("NpcSystem")
				:GetDescendants()}`
	)
	checks, frames = 0, 0
end
