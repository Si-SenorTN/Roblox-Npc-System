--!strict
local Signal = require(script.Parent.Parent.Signal)
local Protocol = require(script.Parent.Protocol)
local StateMachine = require(script.Parent.StateMachine)
local Types = require(script.Parent.clientNpcTypes)

type NpcRecord = Types.NpcRecord

type Keyframe = {
	t: number,
	position: Vector3,
	velocity: Vector3,
	heading: number,
	-- Jump straight to this keyframe instead of interpolating into it
	snap: boolean,
}

type TimelineEvent =
	{ kind: "Health", t: number, health: number, maxHealth: number }
	| { kind: "Visibility", t: number, visible: boolean }
	| { kind: "Despawn", t: number }

export type Context = {
	-- Where hidden rigs live (the folder the server puts them in)
	rigs: Folder,
	-- Where visible rigs are rendered
	render: Folder,
}

-- The real state behind an NpcRecord. Public fields are read through the
-- record proxy, fields starting with _ are private.
export type Internal = {
	Id: number,
	CustomData: Types.CustomData,
	Model: Model?,
	CFrame: CFrame,
	Position: Vector3,
	Heading: number,
	Velocity: Vector3,
	MoveSpeed: number,
	IsMoving: boolean,
	Health: number,
	MaxHealth: number,
	IsDead: boolean,
	Visible: boolean,
	ReplicationHz: number,
	StateMachine: Types.StateMachine,

	MovementStarted: Signal.Signal<number>,
	MovementStopped: Signal.Signal<()>,
	HealthChanged: Signal.Signal<number, number>,
	Died: Signal.Signal<()>,
	VisibilityChanged: Signal.Signal<boolean>,

	_context: Context,
	-- Server timestamped transforms, oldest first. keyframes[1] is the last
	-- one at or before the render time.
	_keyframes: { Keyframe },
	-- Server timestamped state changes waiting for the render time to reach them
	_events: { TimelineEvent },
	_spawnTime: number,
	-- How far behind the server clock this NPC is rendered
	_delay: number,
	_renderTime: number,
	_modelConnection: RBXScriptConnection?,
	_stateMachineStarted: boolean,
}

local TAU = 2 * math.pi
-- Render this many replication intervals behind (on top of latency): one for
-- the gap between snapshots, one to ride out a dropped packet.
local INTERPOLATION_INTERVALS = 2
-- How quickly the render delay follows changes in latency or ReplicationHz
local DELAY_SMOOTHING = 2
local MAX_KEYFRAMES = 64
-- Stop extrapolating a keyframe after this long without a newer one. Only
-- reached if packets were lost, the server sends moving NPCs every keepalive.
local MAX_EXTRAPOLATION = Protocol.KEEPALIVE_INTERVAL * 2
-- Slower than this counts as standing still, in studs per second
local MIN_MOVE_SPEED = 0.05

local NpcRecord = {}

local function rejectWrite(_: unknown, key: unknown)
	error(`NpcRecord.{tostring(key)} is read-only`, 2)
end

local function targetDelay(self: Internal, latency: number): number
	return latency + INTERPOLATION_INTERVALS / self.ReplicationHz
end

local function setVisible(self: Internal, visible: boolean)
	if self.Visible == visible then
		return
	end
	self.Visible = visible

	-- Start where a Humanoid starts, once the rig is in the world and whatever
	-- drives its animations has had the chance to connect
	if visible and not self._stateMachineStarted then
		self._stateMachineStarted = true
		self.StateMachine:SetState(Enum.HumanoidStateType.Running)
		self.StateMachine.Running:Fire(self.MoveSpeed)
	end

	local model = self.Model
	if model then
		if visible then
			model:PivotTo(self.CFrame)
			model.Parent = self._context.render
		else
			model.Parent = self._context.rigs
		end
	end

	self.VisibilityChanged:Fire(visible)
end

local function updateMoveSpeed(self: Internal, velocity: Vector3)
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if speed < MIN_MOVE_SPEED then
		speed = 0
	end
	if speed == self.MoveSpeed then
		return
	end
	self.MoveSpeed = speed

	local moving = speed > 0
	if moving ~= self.IsMoving then
		self.IsMoving = moving
		if moving then
			self.MovementStarted:Fire(speed)
		else
			self.MovementStopped:Fire()
		end
	end

	if self._stateMachineStarted then
		self.StateMachine.Running:Fire(speed)
	end
end

local function applyHealth(self: Internal, health: number, maxHealth: number)
	local old = self.Health
	self.Health = health
	self.MaxHealth = maxHealth
	if health ~= old then
		self.HealthChanged:Fire(health, old)
	end
	if health <= 0 and not self.IsDead then
		self.IsDead = true
		self.Died:Fire()
	end
end

function NpcRecord.new(
	id: number,
	t: number,
	position: Vector3,
	velocity: Vector3,
	heading: number,
	health: number,
	maxHealth: number,
	replicationHz: number,
	visible: boolean,
	customData: Types.CustomData,
	context: Context,
	latency: number
): (Internal, NpcRecord)
	local internal: Internal = {
		Id = id,
		CustomData = table.freeze(customData),
		Model = nil,
		CFrame = CFrame.new(position) * CFrame.Angles(0, heading, 0),
		Position = position,
		Heading = heading,
		Velocity = Vector3.zero,
		MoveSpeed = 0,
		IsMoving = false,
		Health = health,
		MaxHealth = maxHealth,
		IsDead = health <= 0,
		-- Applied through the timeline below, like every later change
		Visible = false,
		ReplicationHz = replicationHz,
		StateMachine = StateMachine.new(),

		MovementStarted = Signal.new(),
		MovementStopped = Signal.new(),
		HealthChanged = Signal.new(),
		Died = Signal.new(),
		VisibilityChanged = Signal.new(),

		_context = context,
		_keyframes = { { t = t, position = position, velocity = velocity, heading = heading, snap = true } },
		_events = {},
		_spawnTime = t,
		_delay = 0,
		_renderTime = -math.huge,
		_modelConnection = nil,
		_stateMachineStarted = false,
	}
	internal._delay = targetDelay(internal, latency)
	if visible then
		local event: TimelineEvent = { kind = "Visibility", t = t, visible = true }
		table.insert(internal._events, event)
	end

	local record: NpcRecord = setmetatable({}, {
		__index = internal,
		__newindex = rejectWrite,
		__tostring = function()
			return `NpcRecord({id})`
		end,
		__metatable = "The metatable is locked",
	}) :: any

	return internal, record
end

function NpcRecord.attachModel(self: Internal, model: Model)
	self.Model = model
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self.StateMachine.WalkSpeed = humanoid.WalkSpeed
	end
	self._modelConnection = model.Destroying:Connect(function()
		if self.Model == model then
			self.Model = nil
		end
	end)
	if self.Visible then
		model:PivotTo(self.CFrame)
		model.Parent = self._context.render
	end
end

function NpcRecord.addKeyframe(
	self: Internal,
	t: number,
	position: Vector3,
	velocity: Vector3,
	heading: number,
	snap: boolean
)
	-- Older than the spawn: meant for a previous NPC with this id
	if t < self._spawnTime then
		return
	end

	local keyframes = self._keyframes
	local index = #keyframes
	while index >= 1 and keyframes[index].t > t do
		index -= 1
	end

	local keyframe = { t = t, position = position, velocity = velocity, heading = heading, snap = snap }
	if index >= 1 and keyframes[index].t == t then
		-- Same server frame on both channels: a snap wins
		if snap or not keyframes[index].snap then
			keyframes[index] = keyframe
		end
		return
	end

	table.insert(keyframes, index + 1, keyframe)
	if #keyframes > MAX_KEYFRAMES then
		table.remove(keyframes, 1)
	end
end

function NpcRecord.addEvent(self: Internal, event: TimelineEvent)
	local events = self._events
	local index = #events
	while index >= 1 and events[index].t > event.t do
		index -= 1
	end
	table.insert(events, index + 1, event)
end

function NpcRecord.addHealthEvent(self: Internal, t: number, health: number, maxHealth: number)
	NpcRecord.addEvent(self, { kind = "Health", t = t, health = health, maxHealth = maxHealth })
end

function NpcRecord.addVisibilityEvent(self: Internal, t: number, visible: boolean)
	NpcRecord.addEvent(self, { kind = "Visibility", t = t, visible = visible })
end

function NpcRecord.addDespawnEvent(self: Internal, t: number)
	NpcRecord.addEvent(self, { kind = "Despawn", t = t })
end

function NpcRecord.setReplicationHz(self: Internal, replicationHz: number)
	if replicationHz > 0 then
		self.ReplicationHz = replicationHz
	end
end

-- Advances the NPC to the current render time. Returns true once its despawn
-- has been reached, after which the caller should destroy it.
function NpcRecord.update(self: Internal, now: number, latency: number, dt: number): boolean
	self._delay += (targetDelay(self, latency) - self._delay) * math.min(dt * DELAY_SMOOTHING, 1)
	-- Never step backwards in time when the delay grows
	local renderTime = math.max(now - self._delay, self._renderTime)
	self._renderTime = renderTime

	local events = self._events
	while #events > 0 and events[1].t <= renderTime do
		local event = table.remove(events, 1) :: TimelineEvent
		if event.kind == "Health" then
			applyHealth(self, event.health, event.maxHealth)
		elseif event.kind == "Visibility" then
			setVisible(self, event.visible)
		else
			return true
		end
	end

	local keyframes = self._keyframes
	while #keyframes >= 2 and keyframes[2].t <= renderTime do
		table.remove(keyframes, 1)
	end

	local from = keyframes[1]
	local to = keyframes[2]

	-- Follow the latest keyframe's velocity. The server sends again as soon as
	-- that stops being accurate, and at least every keepalive.
	local elapsed = math.clamp(renderTime - from.t, 0, MAX_EXTRAPOLATION)
	local position = from.position + from.velocity * elapsed
	local heading = from.heading
	local velocity = if elapsed < MAX_EXTRAPOLATION then from.velocity else Vector3.zero
	-- The velocity the server reported for this moment, without the blending below
	local reportedVelocity = velocity

	if to and not to.snap then
		-- Whatever `to` reports changed at most one replication interval
		-- before it was sent, so keep extrapolating until then and blend
		-- into it over that last interval
		local start = math.max(from.t, to.t - 1 / self.ReplicationHz)
		if renderTime > start then
			local startPosition = from.position + from.velocity * math.min(start - from.t, MAX_EXTRAPOLATION)
			local span = to.t - start
			local alpha = (renderTime - start) / span
			position = startPosition:Lerp(to.position, alpha)
			local turn = (to.heading - from.heading + math.pi) % TAU - math.pi
			heading = (from.heading + turn * alpha) % TAU
			velocity = (to.position - startPosition) / span
			reportedVelocity = to.velocity
		end
	end

	self.Velocity = velocity
	updateMoveSpeed(self, reportedVelocity)
	if position ~= self.Position or heading ~= self.Heading then
		self.Position = position
		self.Heading = heading
		self.CFrame = CFrame.new(position) * CFrame.Angles(0, heading, 0)
		local model = self.Model
		if model and self.Visible then
			model:PivotTo(self.CFrame)
		end
	end

	return false
end

function NpcRecord.destroy(self: Internal)
	local connection = self._modelConnection
	if connection then
		connection:Disconnect()
		self._modelConnection = nil
	end

	-- Only removes the local copy, the server destroys the real rig shortly after
	local model = self.Model
	self.Model = nil
	if model then
		model:Destroy()
	end

	self.MovementStarted:Destroy()
	self.MovementStopped:Destroy()
	self.HealthChanged:Destroy()
	self.Died:Destroy()
	self.VisibilityChanged:Destroy()
	StateMachine.destroy(self.StateMachine)
end

return NpcRecord
