--!strict
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Parent.Signal)
local Network = require(script.Parent.Network)
local Protocol = require(script.Parent.Protocol)
local Templates = require(script.Parent.Templates)
local Types = require(script.Parent.serverNpcTypes)

type NpcRecord = Types.NpcRecord
type ResolvedNpcConfig = Types.ResolvedNpcConfig

export type Context = {
	hitboxes: Camera,
	onDestroyed: (Internal) -> (),
}

-- Filled while the service updates every record in one frame.
export type FrameBatch = {
	movedParts: { BasePart },
	movedCFrames: { CFrame },
	dueTransforms: { Internal },
}

-- The real state behind an NpcRecord. Public fields are read through the
-- record proxy, fields starting with _ are private.
export type Internal = {
	Id: number,
	Data: { [any]: any },
	CustomData: Types.CustomData,
	Config: ResolvedNpcConfig,
	Template: Model,
	Variant: number,
	Hitbox: Part,
	CFrame: CFrame,
	Position: Vector3,
	Heading: number,
	Health: number,
	MaxHealth: number,
	IsDead: boolean,
	WalkSpeed: number,
	MoveDirection: Vector3,
	MoveTarget: Vector3?,
	IsGrounded: boolean,
	ThinkHz: number,
	ReplicationHz: number,
	IsDestroyed: boolean,

	Think: Signal.Signal<()>,
	HealthChanged: Signal.Signal<number, number>,
	Died: Signal.Signal<()>,
	MoveToFinished: Signal.Signal<boolean>,
	Cleanup: Signal.Signal<()>,

	_context: Context,
	_template: Templates.Entry,
	-- Sent to clients so their rig lines up with the hitbox
	_rigOffset: Vector3,
	_raycastParams: RaycastParams,
	_halfHeight: number,
	_sweepSize: Vector3,
	_sweepLift: number,
	_probeSize: Vector3,
	_thinkAccumulator: number,
	_motionAccumulator: number,
	_replicationTick: number,
	_moveToElapsed: number,
	_verticalVelocity: number,
	-- Velocity over the last motion step and the server time it ran at, used to
	-- line replicated positions up with their packet timestamp
	_motionVelocity: Vector3,
	_motionTime: number,
	_idleTime: number,
	-- What clients were last told, quantized exactly as they decode it. They
	-- extrapolate from it, so the server only sends when reality drifts away.
	_sentPosition: Vector3,
	_sentVelocity: Vector3,
	_sentHeading: number,
	_sentTime: number,
	-- Send again on the next tick so one lost correction can't stick around
	_repeatSend: boolean,
	_snapPending: boolean,
	_healthDirty: boolean,
	_visibleByDefault: boolean,
	_visibilityOverrides: { [Player]: boolean },
}

local TAU = 2 * math.pi
-- Gap kept between the movement box and whatever it hits
local SKIN = 0.05
-- Horizontal distance at which MoveTo counts as reached
local ARRIVE_DISTANCE = 0.05
-- Height of the thin box swept down to find the ground
local PROBE_HEIGHT = 0.1
-- Grounded NPCs that aren't moving only re-check the ground this often
local IDLE_GROUND_CHECK_INTERVAL = 0.5
local MIN_MOVE = 1e-4
-- Send a moving NPC when clients' extrapolation is off by more than this many
-- studs, or its velocity changed by more than this many studs per second
local POSITION_TOLERANCE = 0.1
local VELOCITY_TOLERANCE = 0.25
-- Slower than this counts as stopped
local MIN_SPEED = 0.01
-- Longest single motion step, in seconds
local MAX_MOTION_STEP = 0.25

local NpcRecord = {}

local Methods = {}
local InternalMeta = { __index = Methods }
-- Records are the keys, so a record nobody references can be collected
local internals: { [NpcRecord]: Internal } = setmetatable({}, { __mode = "k" }) :: any

local function internalOf(record: NpcRecord): Internal
	local internal = internals[record]
	if internal == nil then
		error("Expected an NpcRecord, call methods with ':'", 3)
	end
	return internal
end

local function rejectWrite(_: unknown, key: unknown)
	error(`NpcRecord.{tostring(key)} is read-only, use its methods instead`, 2)
end

local function assertNumber(value: unknown, name: string)
	assert(typeof(value) == "number" and value == value, `{name} must be a number`)
end

local function headingFromDirection(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z) % TAU
end

local function setTransform(self: Internal, position: Vector3, heading: number): boolean
	if position == self.Position and heading == self.Heading then
		return false
	end
	self.Position = position
	self.Heading = heading
	self.CFrame = CFrame.new(position) * CFrame.Angles(0, heading, 0)
	return true
end

local function finishMoveTo(self: Internal, reached: boolean)
	if self.MoveTarget == nil then
		return
	end
	self.MoveTarget = nil
	self._moveToElapsed = 0
	self.MoveToFinished:Fire(reached)
end

local function checkMoveTo(self: Internal)
	local target = self.MoveTarget
	if target == nil then
		return
	end
	local position = self.Position
	local dx, dz = target.X - position.X, target.Z - position.Z
	if dx * dx + dz * dz <= ARRIVE_DISTANCE * ARRIVE_DISTANCE then
		finishMoveTo(self, true)
	elseif self._moveToElapsed >= self.Config.MoveToTimeout then
		finishMoveTo(self, false)
	end
end

local function applyHealth(self: Internal, health: number)
	if self.IsDead or self.IsDestroyed then
		return
	end
	local clamped = math.clamp(health, 0, self.MaxHealth)
	local old = self.Health
	if clamped == old then
		return
	end

	self.Health = clamped
	self._healthDirty = true
	self.HealthChanged:Fire(clamped, old)

	-- Re-read Health, a HealthChanged handler may have changed it
	if self.Health <= 0 and not self.IsDead then
		self.IsDead = true
		self.MoveDirection = Vector3.zero
		self._motionVelocity = Vector3.zero
		finishMoveTo(self, false)
		self.Died:Fire()
	end
end

local function isVisibleTo(self: Internal, player: Player): boolean
	local override = self._visibilityOverrides[player]
	if override == nil then
		return self._visibleByDefault
	end
	return override
end

-- Where clients currently extrapolate the NPC to at `time`, and its velocity
local function predictedState(self: Internal, time: number): (Vector3, Vector3)
	return self._sentPosition + self._sentVelocity * (time - self._sentTime), self._sentVelocity
end

local function markSent(self: Internal, position: Vector3, velocity: Vector3, now: number)
	self._sentPosition = Protocol.quantizePosition(position)
	self._sentVelocity = Protocol.quantizeVelocity(velocity)
	self._sentHeading = Protocol.encodeHeading(self.Heading)
	self._sentTime = now
end

local function sendVisibility(self: Internal, player: Player, visible: boolean)
	Network.writeVisibility(player, self.Id, visible)
	if visible then
		-- The player got no transforms while hidden. Give them the same
		-- trajectory everyone else is extrapolating.
		local position, velocity = predictedState(self, Workspace:GetServerTimeNow())
		Network.writeTransform(player, self.Id, position, velocity, self.Heading, true)
	end
end

-- Sweeps the movement box and returns how far it can actually go, plus the
-- normal of whatever stopped it.
local function sweep(self: Internal, origin: Vector3, rotation: CFrame, displacement: Vector3): (Vector3, Vector3?)
	local length = displacement.Magnitude
	if length < MIN_MOVE then
		return Vector3.zero, nil
	end
	local result =
		Workspace:Blockcast(CFrame.new(origin) * rotation, self._sweepSize, displacement, self._raycastParams)
	if result == nil then
		return displacement, nil
	end
	return displacement * (math.max(result.Distance - SKIN, 0) / length), result.Normal
end

-- Advances movement and gravity by dt. Returns whether the transform changed.
local function stepMotion(self: Internal, dt: number, now: number): boolean
	local config = self.Config
	local position = self.Position
	local heading = self.Heading

	local displacement = Vector3.zero
	local target = self.MoveTarget
	if target then
		self._moveToElapsed += dt
		local offset = Vector3.new(target.X - position.X, 0, target.Z - position.Z)
		local distance = offset.Magnitude
		if distance > ARRIVE_DISTANCE then
			displacement = offset * (math.min(self.WalkSpeed * dt, distance) / distance)
		end
	elseif self.MoveDirection ~= Vector3.zero then
		displacement = self.MoveDirection * (self.WalkSpeed * dt)
	end
	local moving = displacement.Magnitude >= MIN_MOVE

	if not moving and self.IsGrounded and self._verticalVelocity == 0 then
		self._idleTime += dt
		if self._idleTime < IDLE_GROUND_CHECK_INTERVAL then
			self._motionVelocity = Vector3.zero
			self._motionTime = now
			checkMoveTo(self)
			return false
		end
	end
	self._idleTime = 0

	if moving and config.AutoRotate then
		local delta = (headingFromDirection(displacement) - heading + math.pi) % TAU - math.pi
		local maxTurn = config.TurnSpeed * dt
		heading = (heading + math.clamp(delta, -maxTurn, maxTurn)) % TAU
	end

	local rotation = CFrame.Angles(0, heading, 0)
	local feet = position - Vector3.new(0, self._halfHeight, 0)

	if moving then
		if self.Config.Phase then
			feet += displacement
		else
			local origin = feet + Vector3.new(0, self._sweepLift, 0)
			local moved, normal = sweep(self, origin, rotation, displacement)
			if normal then
				-- Slide along whatever was hit
				local flatNormal = Vector3.new(normal.X, 0, normal.Z)
				if flatNormal.Magnitude > 1e-3 then
					flatNormal = flatNormal.Unit
					local remaining = displacement - moved
					local slide = remaining - flatNormal * remaining:Dot(flatNormal)
					moved += sweep(self, origin + moved, rotation, slide)
				end
			end
			feet += moved
		end
	end

	-- Probe down from StepHeight above the feet: steps up onto anything
	-- shorter than StepHeight, and follows slopes down while grounded.
	local verticalVelocity = self._verticalVelocity - config.Gravity * dt
	local fall = math.max(-verticalVelocity * dt, 0)
	local snapDown = if self.IsGrounded then config.StepHeight else 0
	local probeCenter = feet + Vector3.new(0, config.StepHeight + PROBE_HEIGHT / 2, 0)
	local probeLength = config.StepHeight + math.max(fall, snapDown) + SKIN
	local ground = Workspace:Blockcast(
		CFrame.new(probeCenter) * rotation,
		self._probeSize,
		Vector3.new(0, -probeLength, 0),
		self._raycastParams
	)

	if ground and verticalVelocity <= 0 then
		feet = Vector3.new(feet.X, probeCenter.Y - PROBE_HEIGHT / 2 - ground.Distance, feet.Z)
		verticalVelocity = 0
		self.IsGrounded = true
	else
		feet += Vector3.new(0, verticalVelocity * dt, 0)
		self.IsGrounded = false
	end
	self._verticalVelocity = verticalVelocity

	local changed = setTransform(self, feet + Vector3.new(0, self._halfHeight, 0), heading)
	self._motionVelocity = (self.Position - position) / dt
	self._motionTime = now
	checkMoveTo(self)

	if feet.Y < Workspace.FallenPartsDestroyHeight then
		self._verticalVelocity = 0
		applyHealth(self, 0)
	end

	return changed
end

function NpcRecord.new(id: number, template: Model, config: ResolvedNpcConfig, context: Context): (Internal, NpcRecord)
	local entry = Templates.acquire(template)

	local spawnCFrame = config.SpawnCFrame
	local look = spawnCFrame.LookVector
	local heading = if math.abs(look.X) + math.abs(look.Z) > 1e-3 then headingFromDirection(look) else 0
	local cframe = CFrame.new(spawnCFrame.Position) * CFrame.Angles(0, heading, 0)

	-- Where clients put their rig's pivot, in the template pivot's space:
	-- bounding box bottom on the hitbox bottom, so the pivot lands on the
	-- hitbox center
	local rigOffset = if config.AlignRigToHitbox
		then entry.bottom + Vector3.new(0, config.HitboxSize.Y / 2, 0)
		else Vector3.zero

	local hitbox = Instance.new("Part")
	hitbox.Name = tostring(id)
	hitbox.Size = config.HitboxSize
	hitbox.CFrame = cframe
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = true
	hitbox.CastShadow = false
	hitbox.Transparency = 1
	hitbox:SetAttribute("NpcId", id)
	hitbox.Parent = context.hitboxes

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { context.hitboxes }
	raycastParams.RespectCanCollide = true
	raycastParams.CollisionGroup = config.CollisionGroup

	local think: Signal.Signal<()> = Signal.new()
	local healthChanged: Signal.Signal<number, number> = Signal.new()
	local died: Signal.Signal<()> = Signal.new()
	local moveToFinished: Signal.Signal<boolean> = Signal.new()
	local cleanup: Signal.Signal<()> = Signal.new()

	local blockcastSize = config.BlockcastSize
	local sweepHeight = math.max(blockcastSize.Y - config.StepHeight, 0.1)

	local internal: Internal = {
		Id = id,
		Data = {},
		CustomData = config.CustomData,
		Config = config,
		Template = template,
		Variant = config.Variant,
		Hitbox = hitbox,
		CFrame = cframe,
		Position = cframe.Position,
		Heading = heading,
		Health = config.Health,
		MaxHealth = config.MaxHealth,
		IsDead = config.Health <= 0,
		WalkSpeed = config.WalkSpeed,
		MoveDirection = Vector3.zero,
		MoveTarget = nil,
		IsGrounded = false,
		ThinkHz = config.ThinkHz,
		ReplicationHz = config.ReplicationHz,
		IsDestroyed = false,

		Think = think,
		HealthChanged = healthChanged,
		Died = died,
		MoveToFinished = moveToFinished,
		Cleanup = cleanup,

		_context = context,
		_template = entry,
		_rigOffset = rigOffset,
		_raycastParams = raycastParams,
		_halfHeight = config.HitboxSize.Y / 2,
		_sweepSize = Vector3.new(blockcastSize.X, sweepHeight, blockcastSize.Z),
		_sweepLift = config.StepHeight + sweepHeight / 2,
		_probeSize = Vector3.new(blockcastSize.X, PROBE_HEIGHT, blockcastSize.Z),
		_replicationTick = 0,
		-- Random phases spread NPCs across frames instead of bunching them up
		_thinkAccumulator = math.random() / config.ThinkHz,
		_motionAccumulator = math.random() / config.MotionHz,
		_moveToElapsed = 0,
		_verticalVelocity = 0,
		_motionVelocity = Vector3.zero,
		_motionTime = 0,
		_idleTime = 0,
		_sentPosition = Vector3.zero,
		_sentVelocity = Vector3.zero,
		_sentHeading = 0,
		_sentTime = 0,
		_repeatSend = false,
		_snapPending = false,
		_healthDirty = false,
		_visibleByDefault = config.Visible,
		_visibilityOverrides = {},
	}
	-- Clients learn the spawn transform from the Spawn op
	markSent(internal, internal.Position, Vector3.zero, Workspace:GetServerTimeNow())
	setmetatable(internal :: any, InternalMeta)

	local record: NpcRecord = setmetatable({}, {
		__index = internal,
		__newindex = rejectWrite,
		__tostring = function()
			return `NpcRecord({id})`
		end,
		__metatable = "The metatable is locked",
	}) :: any
	internals[record] = internal

	return internal, record
end

function NpcRecord.isVisibleTo(self: Internal, player: Player): boolean
	return isVisibleTo(self, player)
end

function NpcRecord.writeSpawn(self: Internal, player: Player)
	local position, velocity = predictedState(self, Workspace:GetServerTimeNow())
	Network.writeSpawn(
		player,
		self.Id,
		self._template.id,
		self._rigOffset,
		position,
		velocity,
		self.Heading,
		self.Health,
		self.MaxHealth,
		self.ReplicationHz,
		self.Variant,
		isVisibleTo(self, player),
		self.CustomData
	)
end

-- Position extrapolated to `now`. Motion steps don't line up with replication
-- ticks, so sending the raw Position stamped with the send time makes
-- snapshot spacing uneven and clients see the NPC speed up and slow down.
function NpcRecord.replicatedPosition(self: Internal, now: number): Vector3
	local age = math.clamp(now - self._motionTime, 0, MAX_MOTION_STEP)
	return self.Position + self._motionVelocity * age
end

function NpcRecord.forgetPlayer(self: Internal, player: Player)
	self._visibilityOverrides[player] = nil
end

-- Clients extrapolate from the last transform they were sent, so it's only
-- worth sending when that extrapolation has gone wrong. A straight walk costs
-- one update per KEEPALIVE_INTERVAL instead of one per replication tick.
local function replicateTransform(self: Internal, now: number, batch: FrameBatch, readyPlayers: { Player })
	local position = NpcRecord.replicatedPosition(self, now)
	local velocity = self._motionVelocity
	local stopped = velocity.Magnitude < MIN_SPEED
	if stopped then
		velocity = Vector3.zero
	end

	local predictedPosition = predictedState(self, now)
	local changed = (position - predictedPosition).Magnitude > POSITION_TOLERANCE
		or (velocity - self._sentVelocity).Magnitude > VELOCITY_TOLERANCE
		or Protocol.encodeHeading(self.Heading) ~= self._sentHeading

	if stopped then
		self._repeatSend = false
		if changed then
			-- Nothing follows a stop to correct it, so it goes reliably.
			-- Idle NPCs then cost nothing.
			markSent(self, position, velocity, now)
			for _, player in readyPlayers do
				if isVisibleTo(self, player) then
					Network.writeTransform(player, self.Id, self._sentPosition, Vector3.zero, self.Heading, false)
				end
			end
		end
		return
	end

	if changed or self._repeatSend or now - self._sentTime >= Protocol.KEEPALIVE_INTERVAL then
		markSent(self, position, velocity, now)
		-- Corrections go out twice so a single lost packet can't leave clients
		-- extrapolating the old motion until the next keepalive
		self._repeatSend = changed
		table.insert(batch.dueTransforms, self)
	end
end

-- Runs once per Heartbeat for every record.
function NpcRecord.update(self: Internal, dt: number, now: number, batch: FrameBatch)
	if not self.IsDead then
		local thinkInterval = 1 / self.ThinkHz
		self._thinkAccumulator += dt
		if self._thinkAccumulator >= thinkInterval then
			self._thinkAccumulator = math.min(self._thinkAccumulator - thinkInterval, thinkInterval)
			self.Think:Fire()
			if self.IsDestroyed then
				return
			end
		end
	end

	-- Checked again, Think handlers can kill the NPC
	if not self.IsDead then
		local motionInterval = 1 / self.Config.MotionHz
		self._motionAccumulator += dt
		if self._motionAccumulator >= motionInterval then
			-- Step by the real time that passed, not a fixed interval. When the
			-- server runs slower than MotionHz, fixed steps would drop time and
			-- NPCs would walk slower than WalkSpeed, off from what clients
			-- extrapolate. Capped so a long hitch can't make one huge step.
			local stepDt = math.min(self._motionAccumulator, MAX_MOTION_STEP)
			self._motionAccumulator = 0
			if stepMotion(self, stepDt, now) then
				table.insert(batch.movedParts, self.Hitbox)
				table.insert(batch.movedCFrames, self.CFrame)
			end
			if self.IsDestroyed then
				return
			end
		end
	end

	local readyPlayers = Network.getReadyPlayers()

	if self._healthDirty then
		self._healthDirty = false
		for _, player in readyPlayers do
			Network.writeHealth(player, self.Id, self.Health, self.MaxHealth)
		end
	end

	if self._snapPending then
		self._snapPending = false
		self._repeatSend = false
		markSent(self, self.Position, Vector3.zero, now)
		for _, player in readyPlayers do
			if isVisibleTo(self, player) then
				Network.writeTransform(player, self.Id, self._sentPosition, Vector3.zero, self.Heading, true)
			end
		end
	end

	-- Scheduled on the shared server clock, not a per-NPC accumulator, so every
	-- NPC with the same ReplicationHz is due on the same frames and they share
	-- packets instead of each frame sending its own
	local replicationTick = math.floor(now * self.ReplicationHz)
	if replicationTick ~= self._replicationTick then
		self._replicationTick = replicationTick
		replicateTransform(self, now, batch, readyPlayers)
	end
end

function Methods.TakeDamage(record: NpcRecord, amount: number)
	local self = internalOf(record)
	assertNumber(amount, "amount")
	assert(amount >= 0, "amount can't be negative, use Heal")
	applyHealth(self, self.Health - amount)
end

function Methods.Heal(record: NpcRecord, amount: number)
	local self = internalOf(record)
	assertNumber(amount, "amount")
	assert(amount >= 0, "amount can't be negative, use TakeDamage")
	applyHealth(self, self.Health + amount)
end

function Methods.SetHealth(record: NpcRecord, health: number)
	local self = internalOf(record)
	assertNumber(health, "health")
	applyHealth(self, health)
end

function Methods.SetMaxHealth(record: NpcRecord, maxHealth: number)
	local self = internalOf(record)
	assertNumber(maxHealth, "maxHealth")
	assert(maxHealth > 0 and maxHealth < math.huge, "maxHealth must be positive and finite")
	if self.IsDestroyed or maxHealth == self.MaxHealth then
		return
	end
	self.MaxHealth = maxHealth
	self._healthDirty = true
	if self.Health > maxHealth then
		applyHealth(self, maxHealth)
	end
end

function Methods.Teleport(record: NpcRecord, cframe: CFrame)
	local self = internalOf(record)
	assert(typeof(cframe) == "CFrame", "cframe must be a CFrame")
	if self.IsDestroyed then
		return
	end

	local look = cframe.LookVector
	local heading = if math.abs(look.X) + math.abs(look.Z) > 1e-3 then headingFromDirection(look) else self.Heading
	setTransform(self, cframe.Position, heading)
	self.Hitbox.CFrame = self.CFrame
	self._verticalVelocity = 0
	self._motionVelocity = Vector3.zero
	self.IsGrounded = false
	self._snapPending = true
end

function Methods.MoveTo(record: NpcRecord, position: Vector3)
	local self = internalOf(record)
	assert(typeof(position) == "Vector3", "position must be a Vector3")
	if self.IsDestroyed or self.IsDead then
		return
	end
	self.MoveDirection = Vector3.zero
	self.MoveTarget = position
	self._moveToElapsed = 0
end

function Methods.Move(record: NpcRecord, direction: Vector3)
	local self = internalOf(record)
	assert(typeof(direction) == "Vector3", "direction must be a Vector3")
	if self.IsDestroyed or self.IsDead then
		return
	end
	finishMoveTo(self, false)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	self.MoveDirection = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zero
end

function Methods.Stop(record: NpcRecord)
	local self = internalOf(record)
	if self.IsDestroyed then
		return
	end
	self.MoveDirection = Vector3.zero
	finishMoveTo(self, false)
end

function Methods.SetHeading(record: NpcRecord, heading: number)
	local self = internalOf(record)
	assertNumber(heading, "heading")
	assert(heading > -math.huge and heading < math.huge, "heading must be finite")
	if self.IsDestroyed then
		return
	end
	if setTransform(self, self.Position, heading % TAU) then
		self.Hitbox.CFrame = self.CFrame
	end
end

function Methods.LookAt(record: NpcRecord, position: Vector3)
	assert(typeof(position) == "Vector3", "position must be a Vector3")
	local self = internalOf(record)
	local offset = position - self.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude > 1e-3 then
		Methods.SetHeading(record, headingFromDirection(flat))
	end
end

function Methods.SetWalkSpeed(record: NpcRecord, walkSpeed: number)
	local self = internalOf(record)
	assertNumber(walkSpeed, "walkSpeed")
	assert(walkSpeed >= 0 and walkSpeed < math.huge, "walkSpeed must be non-negative and finite")
	self.WalkSpeed = walkSpeed
end

function Methods.SetThinkHz(record: NpcRecord, hz: number)
	local self = internalOf(record)
	assertNumber(hz, "hz")
	assert(hz > 0 and hz < math.huge, "hz must be positive and finite")
	self.ThinkHz = hz
end

function Methods.SetReplicationHz(record: NpcRecord, hz: number)
	local self = internalOf(record)
	assertNumber(hz, "hz")
	assert(hz > 0 and hz < math.huge, "hz must be positive and finite")
	if self.IsDestroyed or hz == self.ReplicationHz then
		return
	end
	self.ReplicationHz = hz
	-- Clients size their interpolation buffer from this
	for _, player in Network.getReadyPlayers() do
		Network.writeReplicationRate(player, self.Id, hz)
	end
end

function Methods.SetVisibleFlag(record: NpcRecord, visible: boolean)
	local self = internalOf(record)
	assert(typeof(visible) == "boolean", "visible must be a boolean")
	if self.IsDestroyed or visible == self._visibleByDefault then
		return
	end
	self._visibleByDefault = visible
	for _, player in Network.getReadyPlayers() do
		if self._visibilityOverrides[player] == nil then
			sendVisibility(self, player, visible)
		end
	end
end

function Methods.SetPlayerVisibleFlag(record: NpcRecord, player: Player, visible: boolean?)
	local self = internalOf(record)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player")
	assert(visible == nil or typeof(visible) == "boolean", "visible must be a boolean or nil")
	-- A player who already left would never be cleaned up
	if self.IsDestroyed or player.Parent == nil then
		return
	end

	local before = isVisibleTo(self, player)
	if visible == nil then
		self._visibilityOverrides[player] = nil
	else
		self._visibilityOverrides[player] = visible
	end
	local after = isVisibleTo(self, player)
	if before ~= after and Network.isReady(player) then
		sendVisibility(self, player, after)
	end
end

function Methods.IsVisibleTo(record: NpcRecord, player: Player): boolean
	return isVisibleTo(internalOf(record), player)
end

function Methods.Destroy(record: NpcRecord)
	local self = internalOf(record)
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true
	self.MoveDirection = Vector3.zero
	self.MoveTarget = nil

	self.Cleanup:Fire()

	for _, player in Network.getReadyPlayers() do
		Network.writeDespawn(player, self.Id)
	end
	self._context.onDestroyed(self)

	self.Hitbox:Destroy()

	Templates.release(self._template)

	self.Think:Destroy()
	self.HealthChanged:Destroy()
	self.Died:Destroy()
	self.MoveToFinished:Destroy()
	self.Cleanup:Destroy()
end

return NpcRecord
