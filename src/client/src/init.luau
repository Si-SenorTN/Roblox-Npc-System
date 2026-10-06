--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Signal)
local Culling = require(script.Culling)
local NpcRecord = require(script.NpcRecord)
local Rendering = require(script.Rendering)
local Protocol = require(script.Protocol)
local Types = require(script.clientNpcTypes)

export type NpcRecord = Types.NpcRecord
export type CustomData = Types.CustomData

type Internal = NpcRecord.Internal

local Op = Protocol.Op
local TIMESTAMP_SIZE = Protocol.TIMESTAMP_SIZE
local ENTRY_SIZE = Protocol.TRANSFORM_ENTRY_SIZE
-- The latency estimate rises fast so packets are rarely late, and falls slowly
-- so one quick packet doesn't shrink every NPC's buffer
local LATENCY_RISE = 0.5
local LATENCY_FALL = 0.02
-- The render clock advances by frame time and eases toward the server clock at
-- this rate per second, snapping only when it drifts further than CLOCK_SNAP.
-- GetServerTimeNow alone advances unevenly frame to frame, which shows up as
-- NPCs speeding up and slowing down.
local CLOCK_CORRECTION = 1
local CLOCK_SNAP = 0.25

local npcAdded: Signal.Signal<NpcRecord> = Signal.new()
local npcRemoving: Signal.Signal<NpcRecord> = Signal.new()
local modelAdded: Signal.Signal<NpcRecord, Model> = Signal.new()
local renderedChanged: Signal.Signal<NpcRecord, boolean> = Signal.new()

local NpcController = {
	Name = "NpcController",
	-- Fires as soon as the server announces an NPC. It becomes visible once
	-- its render timeline catches up.
	NpcAdded = npcAdded,
	-- Fires right before an NPC is destroyed
	NpcRemoving = npcRemoving,
	-- (record, model) Fires once per NPC when its rig is created, right after
	-- it enters the world and before it counts as rendered. Set up visuals
	-- here. Same as each record's ModelAdded.
	ModelAdded = modelAdded,
	-- (record, isRendered) Same as each record's RenderedChanged.
	RenderedChanged = renderedChanged,
}

local started = false
local internalsById: { [number]: Internal } = {}
local recordsById: { [number]: NpcRecord } = {}
-- Smoothed age of incoming packets, measured on the synced server clock
local latency = 0
local renderClock: number? = nil
-- Rig moves collected over a frame and applied in one BulkMoveTo
local moveBatch: NpcRecord.MoveBatch = { parts = {}, cframes = {} }

local function observeTimestamp(t: number)
	local age = math.max(Workspace:GetServerTimeNow() - t, 0)
	local rate = if age > latency then LATENCY_RISE else LATENCY_FALL
	latency += (age - latency) * rate
end

local function removeRecord(internal: Internal)
	local id = internal.Id
	local record = recordsById[id]
	internalsById[id] = nil
	recordsById[id] = nil
	npcRemoving:Fire(record)
	Culling.untrack(internal)
	Rendering.untrack(internal)
	NpcRecord.destroy(internal)
end

local function spawn(
	currentContext: NpcRecord.Context,
	t: number,
	id: number,
	templateId: number,
	rigOffset: Vector3,
	position: Vector3,
	velocity: Vector3,
	heading: number,
	health: number,
	maxHealth: number,
	replicationHz: number,
	variant: number,
	visible: boolean,
	customData: CustomData
)
	-- A spawn for a live id means the old NPC's despawn is still queued
	local existing = internalsById[id]
	if existing then
		removeRecord(existing)
	end

	local internal, record = NpcRecord.new(
		id,
		t,
		templateId,
		rigOffset,
		position,
		velocity,
		heading,
		health,
		maxHealth,
		replicationHz,
		variant,
		visible,
		customData,
		currentContext,
		latency
	)
	internalsById[id] = internal
	recordsById[id] = record
	Culling.track(internal)

	internal.ModelAdded:Connect(function(model)
		modelAdded:Fire(record, model)
	end)
	internal.RenderedChanged:Connect(function(rendered)
		renderedChanged:Fire(record, rendered)
	end)

	npcAdded:Fire(record)
end

local function onReliable(currentContext: NpcRecord.Context, payload: unknown, extras: unknown)
	if typeof(payload) ~= "buffer" or buffer.len(payload) < TIMESTAMP_SIZE then
		return
	end
	local extraList: { any } = if typeof(extras) == "table" then extras :: { any } else {}

	local t = Protocol.readTime(payload, 0, Workspace:GetServerTimeNow())
	observeTimestamp(t)

	local length = buffer.len(payload)
	local cursor = TIMESTAMP_SIZE
	local spawnIndex = 0
	while cursor < length do
		local op = buffer.readu8(payload, cursor)
		local id = buffer.readu16(payload, cursor + 1)
		cursor += 3
		local internal = internalsById[id]

		if op == Op.Spawn then
			spawnIndex += 1
			local customData = extraList[spawnIndex]
			spawn(
				currentContext,
				t,
				id,
				buffer.readu16(payload, cursor),
				Vector3.new(
					buffer.readf32(payload, cursor + 2),
					buffer.readf32(payload, cursor + 6),
					buffer.readf32(payload, cursor + 10)
				),
				Protocol.readPosition(payload, cursor + 14),
				Protocol.readVelocity(payload, cursor + 23),
				Protocol.decodeHeading(buffer.readu8(payload, cursor + 29)),
				buffer.readf32(payload, cursor + 30),
				buffer.readf32(payload, cursor + 34),
				buffer.readf32(payload, cursor + 38),
				buffer.readu32(payload, cursor + 42),
				buffer.readu8(payload, cursor + 46) == 1,
				if typeof(customData) == "table" then customData else {}
			)
			cursor += 47
		elseif op == Op.Despawn then
			if internal then
				NpcRecord.addDespawnEvent(internal, t)
			end
		elseif op == Op.Health then
			if internal then
				NpcRecord.addHealthEvent(
					internal,
					t,
					buffer.readf32(payload, cursor),
					buffer.readf32(payload, cursor + 4)
				)
			end
			cursor += 8
		elseif op == Op.Visibility then
			if internal then
				NpcRecord.addVisibilityEvent(internal, t, buffer.readu8(payload, cursor) == 1)
			end
			cursor += 1
		elseif op == Op.Transform then
			if internal then
				NpcRecord.addKeyframe(
					internal,
					t,
					Protocol.readPosition(payload, cursor + 1),
					Protocol.readVelocity(payload, cursor + 10),
					Protocol.decodeHeading(buffer.readu8(payload, cursor + 16)),
					buffer.readu8(payload, cursor) == 1
				)
			end
			cursor += 17
		elseif op == Op.ReplicationRate then
			if internal then
				NpcRecord.setReplicationHz(internal, buffer.readf32(payload, cursor))
			end
			cursor += 4
		else
			warn(`[NpcController] Unknown op {op}, dropping the rest of the packet`)
			return
		end
	end
end

local function onUnreliable(payload: unknown)
	if typeof(payload) ~= "buffer" or buffer.len(payload) < TIMESTAMP_SIZE then
		return
	end

	local t = Protocol.readTime(payload, 0, Workspace:GetServerTimeNow())
	observeTimestamp(t)

	for offset = TIMESTAMP_SIZE, buffer.len(payload) - ENTRY_SIZE, ENTRY_SIZE do
		local id, position, velocity, heading = Protocol.readTransformEntry(payload, offset)
		local internal = internalsById[id]
		if internal then
			NpcRecord.addKeyframe(internal, t, position, velocity, heading, false)
		end
	end
end

local function advanceRenderClock(dt: number): number
	local serverNow = Workspace:GetServerTimeNow()
	local previous = renderClock
	local clock: number
	if previous == nil or math.abs(serverNow - previous) > CLOCK_SNAP then
		clock = serverNow
	else
		clock = previous + dt
		clock += (serverNow - clock) * math.min(dt * CLOCK_CORRECTION, 1)
	end
	renderClock = clock
	return clock
end

local function onRender(dt: number)
	local now = advanceRenderClock(dt)
	local clock = os.clock()
	Culling.beginFrame(clock, dt)
	for _, internal in internalsById do
		if NpcRecord.update(internal, now, latency, dt, moveBatch) then
			removeRecord(internal)
		else
			Culling.updateRecord(internal)
			Rendering.updateRecord(internal, clock)
		end
	end
	Rendering.endFrame(Culling.getFocus(), clock, moveBatch)

	if #moveBatch.parts > 0 then
		Workspace:BulkMoveTo(moveBatch.parts, moveBatch.cframes, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveBatch.parts)
		table.clear(moveBatch.cframes)
	end
end

local function waitForChildOfClass(parent: Instance, name: string, className: string): Instance
	local child = parent:WaitForChild(name)
	assert(child:IsA(className), `{child:GetFullName()} should be a {className}`)
	return child
end

-- Connects to NpcService. Yields until the server has started it.
-- Safe to call more than once.
function NpcController.start()
	assert(RunService:IsClient(), "NpcController can only run on the client")
	if started then
		return
	end
	started = true

	local root = ReplicatedStorage:WaitForChild(Protocol.FOLDER_NAME)
	local templates = waitForChildOfClass(root, Protocol.TEMPLATES_FOLDER_NAME, "Folder") :: Folder
	local reliable = waitForChildOfClass(root, Protocol.RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
	local unreliable =
		waitForChildOfClass(root, Protocol.UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent

	local render = Instance.new("Folder")
	render.Name = "Npcs"
	render.Parent = Workspace

	-- Detached rigs stay in the DataModel, so whatever set them up keeps working
	local rigs = Instance.new("Folder")
	rigs.Name = "NpcRigs"
	rigs.Parent = ReplicatedStorage

	local currentContext: NpcRecord.Context = { templates = templates, rigs = rigs, render = render }

	reliable.OnClientEvent:Connect(function(payload: unknown, extras: unknown)
		onReliable(currentContext, payload, extras)
	end)
	unreliable.OnClientEvent:Connect(onUnreliable)
	RunService.PreRender:Connect(onRender)

	local ready = buffer.create(1)
	buffer.writeu8(ready, 0, Protocol.ClientOp.Ready)
	reliable:FireServer(ready)
end

-- Sets the cull distance for NPCs without their own (see
-- NpcRecord:SetCullDistance). Default 300 studs.
function NpcController.setCullDistance(distance: number)
	assert(
		typeof(distance) == "number" and distance >= 0 and distance < math.huge,
		"distance must be a non-negative finite number"
	)
	Culling.setDefaultDistance(distance)
end

-- Sets where cull distances are measured from. nil measures from the camera.
function NpcController.setCullFocus(getFocus: (() -> Vector3)?)
	Culling.setFocus(getFocus)
end

-- How long a hidden rig stays parked out of sight in the world before it is
-- moved out of it. Showing a parked rig again is just a move, so this saves
-- work on NPCs that come back quickly. Default 2 seconds.
function NpcController.setDetachDelay(seconds: number)
	assert(
		typeof(seconds) == "number" and seconds >= 0 and seconds < math.huge,
		"seconds must be a non-negative finite number"
	)
	Rendering.setDetachDelay(seconds)
end

-- Milliseconds per frame spent moving rigs into and out of the world. Rigs
-- waiting to be shown go nearest first, and at least one is shown every
-- frame. Default 3, attaching a rig costs around 1-2 ms.
function NpcController.setRenderBudget(milliseconds: number)
	assert(
		typeof(milliseconds) == "number" and milliseconds >= 0 and milliseconds < math.huge,
		"milliseconds must be a non-negative finite number"
	)
	Rendering.setBudget(milliseconds)
end

function NpcController.getRecord(id: number): NpcRecord?
	return recordsById[id]
end

-- Returns a new array of every known NPC.
function NpcController.getRecords(): { NpcRecord }
	local records = {}
	for _, record in recordsById do
		table.insert(records, record)
	end
	return records
end

return NpcController
