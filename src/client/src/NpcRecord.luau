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
	-- Replicated template rigs, named by template id
	templates: Folder,
	-- Where detached rigs wait, outside the world
	rigs: Folder,
	-- Where visible rigs are rendered
	render: Folder,
}

-- The real state behind an NpcRecord. Public fields are read through the
-- record proxy, fields starting with _ are private.
export type Internal = {
	Id: number,
	CustomData: Types.CustomData,
	Variant: number,
	TemplateId: number,
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
	IsCulled: boolean,
	IsRendered: boolean,
	CullingEnabled: boolean,
	CullDistance: number?,
	ReplicationHz: number,
	StateMachine: Types.StateMachine,

	MovementStarted: Signal.Signal<number>,
	MovementStopped: Signal.Signal<()>,
	HealthChanged: Signal.Signal<number, number>,
	Died: Signal.Signal<()>,
	VisibilityChanged: Signal.Signal<boolean>,
	RenderedChanged: Signal.Signal<boolean>,
	ModelAdded: Signal.Signal<Model>,

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
	-- Culling state, owned by the Culling module
	_cullCellKey: number?,
	_nextCullCheck: number,
	_cullSettingsChanged: boolean,
	-- Set when the render timeline passes a teleport
	_teleported: boolean,
	_humanoid: Humanoid?,
	-- Where the rig's pivot goes, in the template pivot's space
	_rigOffset: Vector3,
	-- Where the rig physically is, owned by the Rendering module
	_placement: Placement,
	-- When a parked rig gets detached, in os.clock() time
	_detachAt: number,
	-- Set once the rig is known to move as one piece with its PrimaryPart, so
	-- it can be moved with BulkMoveTo instead of PivotTo
	_bulkRoot: BasePart?,
	-- Inverse of the root's PivotOffset: root CFrame = pivot * this
	_rootOffset: CFrame,
	_bulkChecked: boolean,
}

-- Detached: in the server's rig folder. Attached: shown in the world.
-- Parked: still in the world but moved out of sight, so showing it again is
-- just a move.
export type Placement = "Detached" | "Attached" | "Parked"

-- Root parts and target CFrames, moved in one Workspace:BulkMoveTo per frame
export type MoveBatch = {
	parts: { BasePart },
	cframes: { CFrame },
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

local function targetDelay(self: Internal, latency: number): number
	return latency + INTERPOLATION_INTERVALS / self.ReplicationHz
end

-- Whether the rig should be shown. The Rendering module acts on it.
local function setVisible(self: Internal, visible: boolean)
	if self.Visible == visible then
		return
	end
	self.Visible = visible
	self.VisibilityChanged:Fire(visible)
end

-- Mirrors health onto the rig's Humanoid, if it has one, for health bars and
-- anything else that reads it
local function syncHumanoidHealth(self: Internal)
	local humanoid = self._humanoid
	if humanoid then
		-- MaxHealth first, Health is clamped to it
		humanoid.MaxHealth = self.MaxHealth
		humanoid.Health = self.Health
	end
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
	syncHumanoidHealth(self)
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
	customData: Types.CustomData,
	context: Context,
	latency: number
): (Internal, NpcRecord)
	local internal: Internal = {
		Id = id,
		CustomData = table.freeze(customData),
		Variant = variant,
		TemplateId = templateId,
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
		-- Culled until the first culling check says otherwise
		IsCulled = true,
		IsRendered = false,
		CullingEnabled = true,
		CullDistance = nil,
		ReplicationHz = replicationHz,
		StateMachine = StateMachine.new(),

		MovementStarted = Signal.new(),
		MovementStopped = Signal.new(),
		HealthChanged = Signal.new(),
		Died = Signal.new(),
		VisibilityChanged = Signal.new(),
		RenderedChanged = Signal.new(),
		ModelAdded = Signal.new(),

		_context = context,
		_keyframes = { { t = t, position = position, velocity = velocity, heading = heading, snap = true } },
		_events = {},
		_spawnTime = t,
		_delay = 0,
		_renderTime = -math.huge,
		_modelConnection = nil,
		_stateMachineStarted = false,
		_cullCellKey = nil,
		_nextCullCheck = 0,
		_cullSettingsChanged = false,
		_teleported = false,
		_humanoid = nil,
		_rigOffset = rigOffset,
		_placement = "Detached",
		_detachAt = 0,
		_bulkRoot = nil,
		_rootOffset = CFrame.identity,
		_bulkChecked = false,
	}
	setmetatable(internal :: any, InternalMeta)
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
	internals[record] = internal

	return internal, record
end

-- Clones this NPC's rig from its template, lined up with the hitbox. Returns
-- nil while the template hasn't replicated yet. Called by the Rendering
-- module the first time the NPC is shown, so NPCs never shown cost nothing.
function NpcRecord.createModel(self: Internal): Model?
	local template = self._context.templates:FindFirstChild(tostring(self.TemplateId))
	if template == nil or not template:IsA("Model") then
		return nil
	end

	local model = template:Clone()
	model.Name = tostring(self.Id)
	model:SetAttribute("NpcId", self.Id)

	local rigOffset = self._rigOffset
	if rigOffset ~= Vector3.zero then
		local aligned = model:GetPivot() * CFrame.new(rigOffset)
		local primaryPart = model.PrimaryPart
		if primaryPart then
			primaryPart.PivotOffset = primaryPart.CFrame:ToObjectSpace(aligned)
		else
			model.WorldPivot = aligned
		end
	end

	self.Model = model
	self._bulkChecked = false
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self._humanoid = humanoid
		self.StateMachine.WalkSpeed = humanoid.WalkSpeed
		syncHumanoidHealth(self)
	end
	self._modelConnection = model.Destroying:Connect(function()
		if self.Model == model then
			self.Model = nil
			self._humanoid = nil
			self._bulkRoot = nil
		end
	end)
	return model
end

-- Decides once, after the rig first enters the world, whether moving its
-- PrimaryPart moves the whole rig. That holds when every part is in the root's
-- assembly (welded or jointed to it), which is what lets BulkMoveTo replace
-- PivotTo. Assemblies are only known inside the world, hence the timing.
function NpcRecord.prepareBulkMove(self: Internal, model: Model)
	if self._bulkChecked then
		return
	end
	self._bulkChecked = true

	local root = model.PrimaryPart
	if root == nil or not root.Anchored then
		return
	end
	local assembly = root.AssemblyRootPart
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.AssemblyRootPart ~= assembly then
			return
		end
	end
	self._bulkRoot = root
	self._rootOffset = root.PivotOffset:Inverse()
end

-- Puts the rig's pivot at `cframe`, batched when the rig allows it.
function NpcRecord.placeModel(self: Internal, model: Model, cframe: CFrame, batch: MoveBatch)
	local root = self._bulkRoot
	if root then
		table.insert(batch.parts, root)
		table.insert(batch.cframes, cframe * self._rootOffset)
	else
		model:PivotTo(cframe)
	end
end

-- Called by the Culling module.
function NpcRecord.setCulled(self: Internal, culled: boolean)
	self.IsCulled = culled
end

-- Called by the Rendering module when the rig is shown or hidden.
function NpcRecord.setRendered(self: Internal, rendered: boolean)
	if self.IsRendered == rendered then
		return
	end
	self.IsRendered = rendered

	-- Start where a Humanoid starts, once the rig is in the world and whatever
	-- drives its animations has had the chance to connect
	if rendered and not self._stateMachineStarted then
		self._stateMachineStarted = true
		self.StateMachine:SetState(Enum.HumanoidStateType.Running)
		self.StateMachine.Running:Fire(self.MoveSpeed)
	end

	self.RenderedChanged:Fire(rendered)
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
function NpcRecord.update(self: Internal, now: number, latency: number, dt: number, batch: MoveBatch): boolean
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
		if keyframes[2].snap then
			self._teleported = true
		end
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
		if model and self.IsRendered then
			NpcRecord.placeModel(self, model, self.CFrame, batch)
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
	self.RenderedChanged:Destroy()
	self.ModelAdded:Destroy()
	StateMachine.destroy(self.StateMachine)
end

function Methods.SetCullingEnabled(record: NpcRecord, enabled: boolean)
	assert(typeof(enabled) == "boolean", "enabled must be a boolean")
	local self = internalOf(record)
	if self.CullingEnabled == enabled then
		return
	end
	self.CullingEnabled = enabled
	self._cullSettingsChanged = true
end

function Methods.SetCullDistance(record: NpcRecord, distance: number?)
	assert(
		distance == nil or (typeof(distance) == "number" and distance >= 0 and distance < math.huge),
		"distance must be a non-negative finite number or nil"
	)
	local self = internalOf(record)
	if self.CullDistance == distance then
		return
	end
	self.CullDistance = distance
	self._cullSettingsChanged = true
end

return NpcRecord
