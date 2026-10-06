--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Config)
local Network = require(script.Network)
local NpcRecord = require(script.NpcRecord)
local Protocol = require(script.Protocol)
local Templates = require(script.Templates)
local Types = require(script.serverNpcTypes)

export type NpcRecord = Types.NpcRecord
export type NpcConfig = Types.NpcConfig
export type ResolvedNpcConfig = Types.ResolvedNpcConfig
export type CustomData = Types.CustomData

type Internal = NpcRecord.Internal

local MAX_ID = 65535 -- ids travel as u16
local ENTRY_SIZE = Protocol.TRANSFORM_ENTRY_SIZE

local NpcService = {
	Name = "NpcService",
}

local started = false
local context: NpcRecord.Context? = nil

-- Array for fast iteration, maps for lookups
local internals: { Internal } = {}
local indexOf: { [Internal]: number } = {}
local recordsById: { [number]: NpcRecord } = {}
local internalsById: { [number]: Internal } = {}
local lastId = 0

local batch: NpcRecord.FrameBatch = {
	movedParts = {},
	movedCFrames = {},
	dueTransforms = {},
}
local transformEntries = buffer.create(ENTRY_SIZE * 64)
local visibleOffsets: { number } = {}

local function allocateId(): number
	-- Counting up instead of reusing freed ids right away keeps a recycled id
	-- away from packets still in flight for the NPC that last had it
	for _ = 1, MAX_ID do
		lastId = lastId % MAX_ID + 1
		if internalsById[lastId] == nil then
			return lastId
		end
	end
	error(`Can't have more than {MAX_ID} NPCs at once`)
end

local function onDestroyed(internal: Internal)
	local index = indexOf[internal]
	if index == nil then
		return
	end

	-- Swap remove. If this runs mid-update, one record skips a single frame,
	-- which its accumulators absorb.
	local lastIndex = #internals
	local last = internals[lastIndex]
	internals[index] = last
	indexOf[last] = index
	internals[lastIndex] = nil
	indexOf[internal] = nil

	recordsById[internal.Id] = nil
	internalsById[internal.Id] = nil
end

local function onPlayerReady(player: Player)
	for _, internal in internals do
		NpcRecord.writeSpawn(internal, player)
	end
end

local function sendTransforms(now: number)
	local due = batch.dueTransforms
	local count = #due
	if count == 0 then
		return
	end

	if buffer.len(transformEntries) < count * ENTRY_SIZE then
		transformEntries = buffer.create(count * ENTRY_SIZE * 2)
	end
	for index, internal in due do
		Protocol.writeTransformEntry(
			transformEntries,
			(index - 1) * ENTRY_SIZE,
			internal.Id,
			internal._sentPosition,
			internal._sentVelocity,
			internal.Heading
		)
	end

	-- Players who can see every due NPC (the usual case) share one set of packets
	local sharedPackets: { buffer }? = nil
	for _, player in Network.getReadyPlayers() do
		table.clear(visibleOffsets)
		for index, internal in due do
			if NpcRecord.isVisibleTo(internal, player) then
				table.insert(visibleOffsets, (index - 1) * ENTRY_SIZE)
			end
		end

		local visibleCount = #visibleOffsets
		if visibleCount == count then
			if sharedPackets == nil then
				sharedPackets = Network.buildTransformPackets(now, transformEntries, visibleOffsets)
			end
			Network.sendUnreliable(player, sharedPackets :: { buffer })
		elseif visibleCount > 0 then
			Network.sendUnreliable(player, Network.buildTransformPackets(now, transformEntries, visibleOffsets))
		end
	end
end

local function onHeartbeat(dt: number)
	local now = Workspace:GetServerTimeNow()

	local index = 1
	while index <= #internals do
		NpcRecord.update(internals[index], dt, now, batch)
		index += 1
	end

	if #batch.movedParts > 0 then
		Workspace:BulkMoveTo(batch.movedParts, batch.movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	sendTransforms(now)
	Network.flushReliable(now)

	table.clear(batch.movedParts)
	table.clear(batch.movedCFrames)
	table.clear(batch.dueTransforms)
end

-- Creates the runtime remotes and folders and starts updating NPCs.
-- Safe to call more than once.
function NpcService.start()
	assert(RunService:IsServer(), "NpcService can only run on the server")
	if started then
		return
	end
	started = true

	local instances = Network.start(onPlayerReady)
	Templates.start(instances.templates)
	context = {
		hitboxes = instances.hitboxes,
		onDestroyed = onDestroyed,
	}

	Players.PlayerRemoving:Connect(function(player)
		for _, internal in internals do
			NpcRecord.forgetPlayer(internal, player)
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

-- Creates an NPC rendered as `template`. The template is replicated to clients
-- once, the first time it's used, and each client clones its own rigs from
-- it. Changes to the template after that first use aren't picked up, and it
-- is never modified itself.
function NpcService.create(template: Model, config: NpcConfig?): NpcRecord
	local currentContext = context
	assert(currentContext, "Call NpcService.start() before creating NPCs")
	assert(typeof(template) == "Instance" and template:IsA("Model"), "template must be a Model")

	local resolved = Config.resolve(config, template)
	local id = allocateId()
	local internal, record = NpcRecord.new(id, template, resolved, currentContext)

	table.insert(internals, internal)
	indexOf[internal] = #internals
	recordsById[id] = record
	internalsById[id] = internal

	for _, player in Network.getReadyPlayers() do
		NpcRecord.writeSpawn(internal, player)
	end

	return record
end

function NpcService.getRecord(id: number): NpcRecord?
	return recordsById[id]
end

-- Finds the NPC that owns a hitbox, e.g. from a raycast result.
function NpcService.getRecordFromHitbox(part: BasePart): NpcRecord?
	local id = part:GetAttribute("NpcId")
	if typeof(id) ~= "number" then
		return nil
	end
	local internal = internalsById[id]
	if internal == nil or internal.Hitbox ~= part then
		return nil
	end
	return recordsById[id]
end

-- Returns a new array of every live NPC.
function NpcService.getRecords(): { NpcRecord }
	local records: { NpcRecord } = {}
	for _, internal in internals do
		table.insert(records, recordsById[internal.Id])
	end
	return records
end

return NpcService
