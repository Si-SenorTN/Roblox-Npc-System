--!strict
local Signal = require(script.Parent.Parent.Signal)

-- Metadata the server attached when it created the NPC.
export type CustomData = { [string]: any }

-- Humanoid-like state machine for animation controllers like SimpleAnimate.
-- Only movement is tracked: Running fires with the NPC's horizontal speed
-- whenever it changes. Jumping, Climbing and Swimming exist for compatibility
-- and never fire on their own.
export type StateMachine = {
	-- (speed)
	Running: Signal.Signal<number>,
	Jumping: Signal.Signal<()>,
	-- (speed)
	Climbing: Signal.Signal<number>,
	-- (speed)
	Swimming: Signal.Signal<number>,
	-- (oldState, newState)
	StateChanged: Signal.Signal<Enum.HumanoidStateType, Enum.HumanoidStateType>,
	-- Read from the rig's Humanoid when it replicates, 16 without one. Writable.
	WalkSpeed: number,
	-- Current state. Change it with SetState so StateChanged fires.
	State: Enum.HumanoidStateType,

	-- Fires StateChanged(oldState, newState) unless the state is unchanged
	SetState: (self: StateMachine, state: Enum.HumanoidStateType) -> (),
	GetState: (self: StateMachine) -> Enum.HumanoidStateType,
}

-- Client-side view of an NPC. Every property is read-only, writing one errors.
-- State changes are applied on the NPC's render timeline: slightly behind the
-- server, in step with what is drawn.
export type NpcRecord = {
	Id: number,
	CustomData: CustomData,
	-- The rig, once it has replicated. nil after it's destroyed.
	Model: Model?,
	-- Interpolated center of the server hitbox, rotated by Heading
	CFrame: CFrame,
	Position: Vector3,
	-- Yaw in radians, [0, 2π). 0 faces -Z.
	Heading: number,
	-- Interpolated velocity of the rendered rig
	Velocity: Vector3,
	-- Horizontal speed in studs per second, taken from the velocity the server
	-- reported, so it holds steady instead of following render corrections
	MoveSpeed: number,
	IsMoving: boolean,
	-- Health and MaxHealth are copied onto the rig's Humanoid, if it has one
	Health: number,
	MaxHealth: number,
	IsDead: boolean,
	-- The server's visibility flag for this player (SetPlayerVisibleFlag)
	Visible: boolean,
	-- Too far from the camera to render. Always false with culling disabled.
	IsCulled: boolean,
	-- The rig is shown in the world. Follows Visible and not IsCulled, but
	-- showing can trail by a few frames when many rigs appear at once (see
	-- NpcController.setRenderBudget). Only rendered rigs are moved each frame.
	IsRendered: boolean,
	-- Default true. Change with SetCullingEnabled.
	CullingEnabled: boolean,
	-- This NPC's cull distance, or nil for NpcController's default. Change
	-- with SetCullDistance.
	CullDistance: number?,
	ReplicationHz: number,
	-- Starts in Running (firing StateChanged) the first time the NPC is
	-- rendered, so connect to it from NpcAdded
	StateMachine: StateMachine,

	-- (speed)
	MovementStarted: Signal.Signal<number>,
	MovementStopped: Signal.Signal<()>,
	-- (newHealth, oldHealth)
	HealthChanged: Signal.Signal<number, number>,
	Died: Signal.Signal<()>,
	VisibilityChanged: Signal.Signal<boolean>,
	-- (isRendered) The rig entered or left the world
	RenderedChanged: Signal.Signal<boolean>,

	-- false keeps the NPC rendered at any distance (while Visible)
	SetCullingEnabled: (self: NpcRecord, enabled: boolean) -> (),
	-- nil goes back to NpcController's default
	SetCullDistance: (self: NpcRecord, distance: number?) -> (),
}

return nil
