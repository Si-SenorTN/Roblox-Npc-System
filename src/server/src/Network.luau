--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Protocol = require(script.Parent.Protocol)

local Op = Protocol.Op
local TIMESTAMP_SIZE = Protocol.TIMESTAMP_SIZE
local ENTRY_SIZE = Protocol.TRANSFORM_ENTRY_SIZE
local MAX_ENTRIES = Protocol.MAX_TRANSFORMS_PER_UNRELIABLE

-- Reliable ops queued for one player, sent once per frame by flushReliable.
type Writer = {
	buffer: buffer,
	cursor: number,
	extras: { any },
}

export type Instances = {
	templates: Folder,
	-- Parts inside a Camera are in the physics world but never replicate.
	hitboxes: Camera,
}

local Network = {}

local reliableRemote: RemoteEvent? = nil
local unreliableRemote: UnreliableRemoteEvent? = nil

local readyPlayers: { Player } = {}
local readySet: { [Player]: true } = {}
local writers: { [Player]: Writer } = {}

local function reserve(player: Player, bytes: number): (buffer, number)
	local writer = writers[player]
	if writer == nil then
		writer = { buffer = buffer.create(256), cursor = 0, extras = {} }
		writers[player] = writer
	end

	local offset = writer.cursor
	local needed = offset + bytes
	local capacity = buffer.len(writer.buffer)
	if needed > capacity then
		local grown = buffer.create(math.max(capacity * 2, needed))
		buffer.copy(grown, 0, writer.buffer, 0, offset)
		writer.buffer = grown
	end
	writer.cursor = needed

	return writer.buffer, offset
end

function Network.start(onPlayerReady: (Player) -> ()): Instances
	assert(
		ReplicatedStorage:FindFirstChild(Protocol.FOLDER_NAME) == nil,
		`ReplicatedStorage.{Protocol.FOLDER_NAME} already exists`
	)

	local root = Instance.new("Folder")
	root.Name = Protocol.FOLDER_NAME

	local templates = Instance.new("Folder")
	templates.Name = Protocol.TEMPLATES_FOLDER_NAME
	templates.Parent = root

	local reliable = Instance.new("RemoteEvent")
	reliable.Name = Protocol.RELIABLE_NAME
	reliable.Parent = root

	local unreliable = Instance.new("UnreliableRemoteEvent")
	unreliable.Name = Protocol.UNRELIABLE_NAME
	unreliable.Parent = root

	-- Parent last so clients never see a partial tree
	root.Parent = ReplicatedStorage

	local hitboxes = Instance.new("Camera")
	hitboxes.Name = "NpcHitboxes"
	hitboxes.Parent = Workspace

	reliableRemote = reliable
	unreliableRemote = unreliable

	reliable.OnServerEvent:Connect(function(player: Player, payload: unknown)
		if typeof(payload) ~= "buffer" or buffer.len(payload) ~= 1 then
			return
		end
		if buffer.readu8(payload, 0) ~= Protocol.ClientOp.Ready or readySet[player] then
			return
		end

		readySet[player] = true
		table.insert(readyPlayers, player)
		onPlayerReady(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		if readySet[player] then
			readySet[player] = nil
			local index = table.find(readyPlayers, player)
			if index then
				table.remove(readyPlayers, index)
			end
		end
		writers[player] = nil
	end)

	return { templates = templates, hitboxes = hitboxes }
end

-- Players whose client has finished loading. Don't mutate the returned array.
function Network.getReadyPlayers(): { Player }
	return readyPlayers
end

function Network.isReady(player: Player): boolean
	return readySet[player] == true
end

function Network.writeSpawn(
	player: Player,
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
	customData: { [string]: any }
)
	local b, offset = reserve(player, 50)
	buffer.writeu8(b, offset, Op.Spawn)
	buffer.writeu16(b, offset + 1, id)
	buffer.writeu16(b, offset + 3, templateId)
	buffer.writef32(b, offset + 5, rigOffset.X)
	buffer.writef32(b, offset + 9, rigOffset.Y)
	buffer.writef32(b, offset + 13, rigOffset.Z)
	Protocol.writePosition(b, offset + 17, position)
	Protocol.writeVelocity(b, offset + 26, velocity)
	buffer.writeu8(b, offset + 32, Protocol.encodeHeading(heading))
	buffer.writef32(b, offset + 33, health)
	buffer.writef32(b, offset + 37, maxHealth)
	buffer.writef32(b, offset + 41, replicationHz)
	buffer.writeu32(b, offset + 45, variant)
	buffer.writeu8(b, offset + 49, if visible then 1 else 0)
	table.insert(writers[player].extras, customData)
end

function Network.writeDespawn(player: Player, id: number)
	local b, offset = reserve(player, 3)
	buffer.writeu8(b, offset, Op.Despawn)
	buffer.writeu16(b, offset + 1, id)
end

function Network.writeHealth(player: Player, id: number, health: number, maxHealth: number)
	local b, offset = reserve(player, 11)
	buffer.writeu8(b, offset, Op.Health)
	buffer.writeu16(b, offset + 1, id)
	buffer.writef32(b, offset + 3, health)
	buffer.writef32(b, offset + 7, maxHealth)
end

function Network.writeVisibility(player: Player, id: number, visible: boolean)
	local b, offset = reserve(player, 4)
	buffer.writeu8(b, offset, Op.Visibility)
	buffer.writeu16(b, offset + 1, id)
	buffer.writeu8(b, offset + 3, if visible then 1 else 0)
end

function Network.writeTransform(
	player: Player,
	id: number,
	position: Vector3,
	velocity: Vector3,
	heading: number,
	snap: boolean
)
	local b, offset = reserve(player, 20)
	buffer.writeu8(b, offset, Op.Transform)
	buffer.writeu16(b, offset + 1, id)
	buffer.writeu8(b, offset + 3, if snap then 1 else 0)
	Protocol.writePosition(b, offset + 4, position)
	Protocol.writeVelocity(b, offset + 13, velocity)
	buffer.writeu8(b, offset + 19, Protocol.encodeHeading(heading))
end

function Network.writeReplicationRate(player: Player, id: number, replicationHz: number)
	local b, offset = reserve(player, 7)
	buffer.writeu8(b, offset, Op.ReplicationRate)
	buffer.writeu16(b, offset + 1, id)
	buffer.writef32(b, offset + 3, replicationHz)
end

-- Sends every player's queued reliable ops as one packet stamped with `now`.
function Network.flushReliable(now: number)
	local remote = reliableRemote
	if remote == nil then
		return
	end

	for player, writer in writers do
		if writer.cursor == 0 then
			continue
		end

		local packet = buffer.create(TIMESTAMP_SIZE + writer.cursor)
		Protocol.writeTime(packet, 0, now)
		buffer.copy(packet, TIMESTAMP_SIZE, writer.buffer, 0, writer.cursor)
		writer.cursor = 0

		if #writer.extras > 0 then
			remote:FireClient(player, packet, writer.extras)
			writer.extras = {}
		else
			remote:FireClient(player, packet)
		end
	end
end

-- Packs the transform entries at `offsets` (byte offsets into `entries`) into
-- as many unreliable packets as needed.
function Network.buildTransformPackets(now: number, entries: buffer, offsets: { number }): { buffer }
	local packets = {}
	local count = #offsets
	local first = 1
	while first <= count do
		local last = math.min(first + MAX_ENTRIES - 1, count)
		local packet = buffer.create(TIMESTAMP_SIZE + (last - first + 1) * ENTRY_SIZE)
		Protocol.writeTime(packet, 0, now)
		local cursor = TIMESTAMP_SIZE
		for index = first, last do
			buffer.copy(packet, cursor, entries, offsets[index], ENTRY_SIZE)
			cursor += ENTRY_SIZE
		end
		table.insert(packets, packet)
		first = last + 1
	end
	return packets
end

function Network.sendUnreliable(player: Player, packets: { buffer })
	local remote = unreliableRemote
	if remote == nil then
		return
	end
	for _, packet in packets do
		remote:FireClient(player, packet)
	end
end

return Network
