--!strict
-- Template rigs, replicated once each instead of once per NPC. A template is
-- registered the first time an NPC uses it: a prepared copy goes into the
-- replicated Templates folder and clients clone their own rigs from it.
-- Registration takes a snapshot, later changes to the original are ignored.
-- Templates no NPC uses anymore are removed after a grace period.

local MAX_ID = 65535 -- ids travel as u16
-- Seconds an unused template stays around, so clients still rendering a
-- despawning NPC, or an NPC spawned right after, can find it
local RELEASE_GRACE = 10

export type Entry = {
	id: number,
	source: Model,
	-- Bottom center of the template's bounding box, in its pivot's space
	bottom: Vector3,
	references: number,
}

local Templates = {}

local folder: Folder? = nil
local bySource: { [Model]: Entry } = {}
local byId: { [number]: Entry } = {}
local copies: { [Entry]: Model } = {}
local lastId = 0

local function allocateId(): number
	for _ = 1, MAX_ID do
		lastId = lastId % MAX_ID + 1
		if byId[lastId] == nil then
			return lastId
		end
	end
	error(`Can't have more than {MAX_ID} templates at once`)
end

-- The rig is shared by every NPC using it, so only things true for all of
-- them happen here
local function prepare(copy: Model)
	-- Only the root is anchored so jointed parts (like Motor6D limbs) can
	-- still be animated. Without a PrimaryPart there's no root to hang the
	-- rest from.
	local primaryPart = copy.PrimaryPart
	if primaryPart then
		primaryPart.Anchored = true
	else
		for _, descendant in copy:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end
	end

	-- Clients only pivot the rig, a Humanoid's state machine is wasted work
	local humanoid = copy:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.EvaluateStateMachine = false
	end
end

function Templates.start(templatesFolder: Folder)
	folder = templatesFolder
end

-- Registers `source` if needed and adds a reference to it.
function Templates.acquire(source: Model): Entry
	local entry = bySource[source]
	if entry then
		entry.references += 1
		return entry
	end

	local currentFolder = folder
	assert(currentFolder, "Templates.start must run first")
	local copy: Model? = source:Clone()
	assert(copy, "The template couldn't be cloned, make sure it is Archivable")
	prepare(copy)

	local pivot = copy:GetPivot()
	local boxCFrame, boxSize = copy:GetBoundingBox()
	local bottom = pivot:PointToObjectSpace(boxCFrame.Position - boxCFrame.UpVector * (boxSize.Y / 2))

	local id = allocateId()
	copy.Name = tostring(id)
	copy.Parent = currentFolder

	local newEntry: Entry = { id = id, source = source, bottom = bottom, references = 1 }
	bySource[source] = newEntry
	byId[id] = newEntry
	copies[newEntry] = copy
	return newEntry
end

-- Drops a reference. The template is removed once nothing has used it for
-- RELEASE_GRACE seconds.
function Templates.release(entry: Entry)
	entry.references -= 1
	if entry.references > 0 then
		return
	end
	task.delay(RELEASE_GRACE, function()
		if entry.references > 0 or byId[entry.id] ~= entry then
			return
		end
		bySource[entry.source] = nil
		byId[entry.id] = nil
		local copy = copies[entry]
		copies[entry] = nil
		if copy then
			copy:Destroy()
		end
	end)
end

return Templates
