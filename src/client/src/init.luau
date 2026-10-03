--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Signal)
local Culling = require(script.Culling)
local NpcRecord = require(script.NpcRecord)
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

local NpcController = {
	Name = "NpcController",
	-- Fires as soon as the server announces an NPC. It becomes visible once
	-- its render timeline catches up.
	NpcAdded = npcAdded,
	-- Fires right before an NPC is destroyed
	NpcRemoving = npcRemoving,
}

local started = false
local internalsById: { [number]: Internal } = {}
local recordsById: { [number]: NpcRecord } = {}
-- Records whose rig hasn't replicated yet, by rig name
local pendingModels: { [string]: Internal } = {}
-- Smoothed age of incoming packets, measured on the synced server clock
local latency = 0
local renderClock: number? = nil

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
	local name = tostring(id)
	if pendingModels[name] == internal then
		pendingModels[name] = nil
	end

	npcRemoving:Fire(record)
	Culling.untrack(internal)
	NpcRecord.destroy(internal)
end

local function spawn(
	currentContext: NpcRecord.Context,
	t: number,
	id: number,
	position: Vector3,
	velocity: Vector3,
	heading: number,
	health: number,
	maxHealth: number,
	replicationHz: number,
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
		position,
		velocity,
		heading,
		health,
		maxHealth,
		replicationHz,
		visible,
		customData,
		currentContext,
		latency
	)
	internalsById[id] = internal
	recordsById[id] = record
	Culling.track(internal)

	local name = tostring(id)
	local model = currentContext.rigs:FindFirstChild(name)
	if model and model:IsA("Model") then
		NpcRecord.attachModel(internal, model)
	else
		pendingModels[name] = internal
	end

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
				Protocol.readPosition(payload, cursor),
				Protocol.readVelocity(payload, cursor + 9),
				Protocol.decodeHeading(buffer.readu8(payload, cursor + 15)),
				buffer.readf32(payload, cursor + 16),
				buffer.readf32(payload, cursor + 20),
				buffer.readf32(payload, cursor + 24),
				buffer.readu8(payload, cursor + 28) == 1,
				if typeof(customData) == "table" then customData else {}
			)
			cursor += 29
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
	Culling.beginFrame(os.clock(), dt)
	for _, internal in internalsById do
		if NpcRecord.update(internal, now, latency, dt) then
			removeRecord(internal)
		else
			Culling.updateRecord(internal)
		end
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
	local rigs = waitForChildOfClass(root, Protocol.RIGS_FOLDER_NAME, "Folder") :: Folder
	local reliable = waitForChildOfClass(root, Protocol.RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
	local unreliable =
		waitForChildOfClass(root, Protocol.UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent

	local render = Instance.new("Folder")
	render.Name = "Npcs"
	render.Parent = Workspace

	local currentContext: NpcRecord.Context = { rigs = rigs, render = render }

	rigs.ChildAdded:Connect(function(child)
		local internal = pendingModels[child.Name]
		if internal and child:IsA("Model") then
			pendingModels[child.Name] = nil
			NpcRecord.attachModel(internal, child)
		end
	end)

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
