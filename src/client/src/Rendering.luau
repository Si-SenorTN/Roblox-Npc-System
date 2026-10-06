--!strict
-- Moves rigs in and out of the world. Each NPC's rig is cloned from its
-- template the first time it's shown, so NPCs never shown cost nothing.
-- Reparenting a rig is the expensive part
-- (Humanoid, Animator and physics all react), and moving hundreds of rigs in
-- one frame isn't free either, so:
-- - Hidden rigs are parked out of sight first and only reparented after
--   DetachDelay, so an NPC that comes back soon is just moved back.
-- - Every change shares a per-frame time budget: hiding first (cheap, and
--   order doesn't matter), then showing nearest first, then detaching. A rig
--   keeps moving normally until it's actually hidden.

local NpcRecord = require(script.Parent.NpcRecord)

type Internal = NpcRecord.Internal
type MoveBatch = NpcRecord.MoveBatch

local DEFAULT_DETACH_DELAY = 2
-- Milliseconds per frame spent moving rigs in and out of the world. At least
-- one rig is shown every frame regardless.
local DEFAULT_BUDGET = 3
-- Far enough to be out of sight and out of the way of gameplay raycasts
local PARK_OFFSET = Vector3.new(0, 10000, 0)

local magnitude: (Vector3) -> number = vector.magnitude :: any

local Rendering = {}

local detachDelay = DEFAULT_DETACH_DELAY
local budget = DEFAULT_BUDGET / 1000
local hideQueue: { [Internal]: true } = {}
local showQueue: { [Internal]: true } = {}
local detachQueue: { [Internal]: true } = {}

-- Returns false while the NPC's template hasn't replicated yet
local function show(internal: Internal, batch: MoveBatch): boolean
	local model: Model
	local created = false
	local existing = internal.Model
	if existing then
		model = existing
	else
		local new = NpcRecord.createModel(internal)
		if new == nil then
			return false
		end
		model = new
		created = true
	end

	if internal._placement == "Detached" then
		model:PivotTo(internal.CFrame)
		model.Parent = internal._context.render
		NpcRecord.prepareBulkMove(internal, model)
	else
		NpcRecord.placeModel(internal, model, internal.CFrame, batch)
	end
	internal._placement = "Attached"

	-- In the world and in place, but not yet counted as rendered, so visuals
	-- set up here are ready before anything reacts to RenderedChanged
	if created then
		internal.ModelAdded:Fire(model)
	end
	NpcRecord.setRendered(internal, true)
	return true
end

local function park(internal: Internal, model: Model, now: number, batch: MoveBatch)
	NpcRecord.placeModel(internal, model, internal.CFrame + PARK_OFFSET, batch)
	internal._placement = "Parked"
	internal._detachAt = now + detachDelay
	NpcRecord.setRendered(internal, false)
end

local function detach(internal: Internal, model: Model)
	model.Parent = internal._context.rigs
	internal._placement = "Detached"
end

local function dequeue(internal: Internal)
	hideQueue[internal] = nil
	showQueue[internal] = nil
	detachQueue[internal] = nil
end

function Rendering.setDetachDelay(seconds: number)
	detachDelay = seconds
end

function Rendering.setBudget(milliseconds: number)
	budget = milliseconds / 1000
end

function Rendering.untrack(internal: Internal)
	dequeue(internal)
end

-- Runs once per frame for every NPC, after culling. Only queues work.
function Rendering.updateRecord(internal: Internal, now: number)
	-- The rig was destroyed from outside, a new one is made next time it's shown
	if internal.Model == nil and internal._placement ~= "Detached" then
		hideQueue[internal] = nil
		detachQueue[internal] = nil
		internal._placement = "Detached"
		NpcRecord.setRendered(internal, false)
	end

	local placement = internal._placement
	if internal.Visible and not internal.IsCulled then
		hideQueue[internal] = nil
		detachQueue[internal] = nil
		if placement ~= "Attached" then
			showQueue[internal] = true
		end
	else
		showQueue[internal] = nil
		if placement == "Attached" then
			hideQueue[internal] = true
		elseif placement == "Parked" and now >= internal._detachAt then
			detachQueue[internal] = true
		end
	end
end

-- Runs once per frame after every NPC was updated. `focus` is where cull
-- distances are measured from. Moves go into `batch`, which the caller
-- applies with BulkMoveTo after this.
function Rendering.endFrame(focus: Vector3, now: number, batch: MoveBatch)
	local start = os.clock()

	for internal in hideQueue do
		if os.clock() - start >= budget then
			break
		end
		hideQueue[internal] = nil
		local model = internal.Model
		if model and internal._placement == "Attached" then
			park(internal, model, now, batch)
		end
	end

	if next(showQueue) then
		local queued: { Internal } = {}
		local distances: { [Internal]: number } = {}
		for internal in showQueue do
			table.insert(queued, internal)
			distances[internal] = magnitude(internal.Position - focus)
		end
		table.sort(queued, function(a, b)
			return distances[a] < distances[b]
		end)

		local shown = 0
		for _, internal in queued do
			if shown > 0 and os.clock() - start >= budget then
				break
			end
			if show(internal, batch) then
				showQueue[internal] = nil
				shown += 1
			end
		end
	end

	for internal in detachQueue do
		if os.clock() - start >= budget then
			break
		end
		detachQueue[internal] = nil
		local model = internal.Model
		if model and internal._placement == "Parked" then
			detach(internal, model)
		end
	end
end

return Rendering
