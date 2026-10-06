--!strict
-- Wire format shared by npc-service and npc-controller.
-- This file must stay identical in both packages.

local Protocol = {}

Protocol.FOLDER_NAME = "NpcSystem"
-- Each template rig is replicated here once, named by its template id. Clients
-- clone their own rigs from these, nothing per NPC is replicated as instances.
Protocol.TEMPLATES_FOLDER_NAME = "Templates"
Protocol.RELIABLE_NAME = "Reliable"
Protocol.UNRELIABLE_NAME = "Unreliable"

-- Encoded sizes, see the read/write functions below
Protocol.TIMESTAMP_SIZE = 4
Protocol.POSITION_SIZE = 9
Protocol.VELOCITY_SIZE = 6

-- Server -> client reliable packets: u32 timestamp, followed by any number of
-- [u8 opcode, payload] records.
Protocol.Op = table.freeze({
	-- u16 id, u16 templateId, f32 x3 rigOffset, position, velocity, u8 heading,
	-- f32 health, f32 maxHealth, f32 replicationHz, u32 variant, u8 visible.
	-- rigOffset is where the rig's pivot goes, in the template pivot's space.
	-- CustomData travels in the extras array, one entry per Spawn, in order.
	Spawn = 1,
	-- u16 id
	Despawn = 2,
	-- u16 id, f32 health, f32 maxHealth
	Health = 3,
	-- u16 id, u8 visible
	Visibility = 4,
	-- u16 id, u8 snap, position, velocity, u8 heading
	Transform = 5,
	-- u16 id, f32 replicationHz
	ReplicationRate = 6,
})

-- Client -> server packets: a single u8 opcode.
Protocol.ClientOp = table.freeze({
	Ready = 1,
})

-- Unreliable packets: u32 timestamp, then fixed size transform entries
-- (u16 id, position, velocity, u8 heading).
Protocol.TRANSFORM_ENTRY_SIZE = 2 + Protocol.POSITION_SIZE + Protocol.VELOCITY_SIZE + 1
-- UnreliableRemoteEvent drops payloads over 900 bytes, leave headroom for the
-- remote's own argument encoding.
Protocol.MAX_TRANSFORMS_PER_UNRELIABLE = 47

-- Clients extrapolate moving NPCs along their velocity between updates. The
-- server sends a moving NPC at least this often even when the extrapolation
-- is still accurate, so a lost packet can't leave it wrong for long.
Protocol.KEEPALIVE_INTERVAL = 1

-- Positions are 24-bit fixed point per axis: 1/64 stud precision, ±131072 studs
local POSITION_SCALE = 64
local I24_OFFSET = 2 ^ 23
local I24_MAX = 2 ^ 23 - 1
-- Velocities are 16-bit fixed point per axis: 1/64 stud/s precision, ±512 studs/s
local VELOCITY_SCALE = 64
-- Headings are 8-bit, about 1.4 degrees per step
local HEADING_STEPS = 256
-- Timestamps are milliseconds of server time, wrapping every ~49 days
local TIME_WRAP = 2 ^ 32

local TAU = 2 * math.pi

local function quantize(value: number, scale: number, min: number, max: number): number
	return math.clamp(math.round(value * scale), min, max)
end

function Protocol.encodeHeading(heading: number): number
	return math.round(heading % TAU / TAU * HEADING_STEPS) % HEADING_STEPS
end

function Protocol.decodeHeading(encoded: number): number
	return encoded / HEADING_STEPS * TAU
end

-- The value a position reads back as on the other end.
function Protocol.quantizePosition(position: Vector3): Vector3
	return Vector3.new(
		quantize(position.X, POSITION_SCALE, -I24_OFFSET, I24_MAX),
		quantize(position.Y, POSITION_SCALE, -I24_OFFSET, I24_MAX),
		quantize(position.Z, POSITION_SCALE, -I24_OFFSET, I24_MAX)
	) / POSITION_SCALE
end

-- The value a velocity reads back as on the other end.
function Protocol.quantizeVelocity(velocity: Vector3): Vector3
	return Vector3.new(
		quantize(velocity.X, VELOCITY_SCALE, -32768, 32767),
		quantize(velocity.Y, VELOCITY_SCALE, -32768, 32767),
		quantize(velocity.Z, VELOCITY_SCALE, -32768, 32767)
	) / VELOCITY_SCALE
end

local function writeI24(b: buffer, offset: number, value: number)
	local unsigned = value + I24_OFFSET
	buffer.writeu16(b, offset, unsigned % 65536)
	buffer.writeu8(b, offset + 2, unsigned // 65536)
end

local function readI24(b: buffer, offset: number): number
	return buffer.readu16(b, offset) + buffer.readu8(b, offset + 2) * 65536 - I24_OFFSET
end

function Protocol.writePosition(b: buffer, offset: number, position: Vector3)
	writeI24(b, offset, quantize(position.X, POSITION_SCALE, -I24_OFFSET, I24_MAX))
	writeI24(b, offset + 3, quantize(position.Y, POSITION_SCALE, -I24_OFFSET, I24_MAX))
	writeI24(b, offset + 6, quantize(position.Z, POSITION_SCALE, -I24_OFFSET, I24_MAX))
end

function Protocol.readPosition(b: buffer, offset: number): Vector3
	return Vector3.new(readI24(b, offset), readI24(b, offset + 3), readI24(b, offset + 6)) / POSITION_SCALE
end

function Protocol.writeVelocity(b: buffer, offset: number, velocity: Vector3)
	buffer.writei16(b, offset, quantize(velocity.X, VELOCITY_SCALE, -32768, 32767))
	buffer.writei16(b, offset + 2, quantize(velocity.Y, VELOCITY_SCALE, -32768, 32767))
	buffer.writei16(b, offset + 4, quantize(velocity.Z, VELOCITY_SCALE, -32768, 32767))
end

function Protocol.readVelocity(b: buffer, offset: number): Vector3
	return Vector3.new(buffer.readi16(b, offset), buffer.readi16(b, offset + 2), buffer.readi16(b, offset + 4))
		/ VELOCITY_SCALE
end

function Protocol.writeTime(b: buffer, offset: number, serverTime: number)
	buffer.writeu32(b, offset, math.round(serverTime * 1000) % TIME_WRAP)
end

-- `reference` is the reader's current server time, used to undo the wrap.
function Protocol.readTime(b: buffer, offset: number, reference: number): number
	local referenceMs = reference * 1000
	local candidate = referenceMs - referenceMs % TIME_WRAP + buffer.readu32(b, offset)
	if candidate - referenceMs > TIME_WRAP / 2 then
		candidate -= TIME_WRAP
	elseif referenceMs - candidate > TIME_WRAP / 2 then
		candidate += TIME_WRAP
	end
	return candidate / 1000
end

function Protocol.writeTransformEntry(
	b: buffer,
	offset: number,
	id: number,
	position: Vector3,
	velocity: Vector3,
	heading: number
)
	buffer.writeu16(b, offset, id)
	Protocol.writePosition(b, offset + 2, position)
	Protocol.writeVelocity(b, offset + 11, velocity)
	buffer.writeu8(b, offset + 17, Protocol.encodeHeading(heading))
end

function Protocol.readTransformEntry(b: buffer, offset: number): (number, Vector3, Vector3, number)
	return buffer.readu16(b, offset),
		Protocol.readPosition(b, offset + 2),
		Protocol.readVelocity(b, offset + 11),
		Protocol.decodeHeading(buffer.readu8(b, offset + 17))
end

return table.freeze(Protocol)
