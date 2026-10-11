--!strict
local Signal = require(script.Parent.Parent.Signal)

-- Metadata replicated to clients once, when the NPC is created. String keys
-- and remote-serializable values only.
export type CustomData = { [string]: any }

export type NpcConfig = {
	-- Where the NPC spawns. Defaults to the template's pivot.
	SpawnCFrame: CFrame?,
	-- How often Think fires. Default 10. Capped at the server frame rate.
	ThinkHz: number?,
	-- How often a moving NPC's transform is sent to clients. Default 20.
	ReplicationHz: number?,
	-- How often movement and gravity are simulated. Default 30.
	MotionHz: number?,
	-- Size of the server-only hitbox part. Defaults to the template's extents.
	HitboxSize: Vector3?,
	-- Box swept for movement collision. Defaults to HitboxSize.
	BlockcastSize: Vector3?,
	CustomData: CustomData?,
	-- Default 100.
	MaxHealth: number?,
	-- Defaults to MaxHealth.
	Health: number?,
	-- Studs per second. Default 16.
	WalkSpeed: number?,
	-- Obstacles shorter than this are walked over. Default min(2, 40% of hitbox height).
	StepHeight: number?,
	-- Defaults to Workspace.Gravity at creation.
	Gravity: number?,
	-- Phase through objects. Good for never getting stuck on things.
	Phase: boolean?,
	-- Turn to face the movement direction. Default true.
	AutoRotate: boolean?,
	-- Radians per second when AutoRotate turns the NPC. Default 4π.
	TurnSpeed: number?,
	-- Seconds before an unfinished MoveTo gives up. Default 8.
	MoveToTimeout: number?,
	-- Visibility for players without a per-player override. Default true.
	Visible: boolean?,
	-- Collision group used by movement casts. Default "Default".
	CollisionGroup: string?,
	-- Move the rig's pivot so its bounding box bottom sits on the hitbox bottom.
	-- Default true.
	AlignRigToHitbox: boolean?,
	-- A number sent to clients once, when the NPC is created. Cheaper than
	-- CustomData for things like picking an appearance. Whole number from 0 to
	-- 4294967295, default 0.
	Variant: number?,
}

export type ResolvedNpcConfig = {
	SpawnCFrame: CFrame,
	ThinkHz: number,
	ReplicationHz: number,
	MotionHz: number,
	HitboxSize: Vector3,
	BlockcastSize: Vector3,
	CustomData: CustomData,
	MaxHealth: number,
	Health: number,
	WalkSpeed: number,
	StepHeight: number,
	Gravity: number,
	Phase: boolean,
	AutoRotate: boolean,
	TurnSpeed: number,
	MoveToTimeout: number,
	Visible: boolean,
	CollisionGroup: string,
	AlignRigToHitbox: boolean,
	Variant: number,
}

-- Every property is read-only, writing one errors. Use the methods instead.
export type NpcRecord = {
	Id: number,
	-- Free table for your own server-side state. Never replicated.
	Data: { [any]: any },
	CustomData: CustomData,
	Config: ResolvedNpcConfig,
	-- The model passed to NpcService.create. It's replicated once per template,
	-- not per NPC, and clients render their own clones of it. There is no
	-- per-NPC rig on the server.
	Template: Model,
	Variant: number,
	-- Server-only anchored part used for motion and hit detection.
	Hitbox: Part,
	-- Center of the hitbox, rotated by Heading.
	CFrame: CFrame,
	Position: Vector3,
	-- Yaw in radians, [0, 2π). 0 faces -Z.
	Heading: number,
	Health: number,
	MaxHealth: number,
	IsDead: boolean,
	WalkSpeed: number,
	-- Unit horizontal direction set by Move, or zero.
	MoveDirection: Vector3,
	-- Target of the active MoveTo, if any.
	MoveTarget: Vector3?,
	IsGrounded: boolean,
	ThinkHz: number,
	ReplicationHz: number,
	IsDestroyed: boolean,

	Think: Signal.Signal<()>,
	-- (newHealth, oldHealth)
	HealthChanged: Signal.Signal<number, number>,
	Died: Signal.Signal<()>,
	-- (reached) false when timed out, cancelled or interrupted by death.
	MoveToFinished: Signal.Signal<boolean>,
	-- Fires once, before the record is torn down.
	Cleanup: Signal.Signal<()>,

	TakeDamage: (self: NpcRecord, amount: number) -> (),
	Heal: (self: NpcRecord, amount: number) -> (),
	SetHealth: (self: NpcRecord, health: number) -> (),
	SetMaxHealth: (self: NpcRecord, maxHealth: number) -> (),
	Teleport: (self: NpcRecord, cframe: CFrame) -> (),
	MoveTo: (self: NpcRecord, position: Vector3) -> (),
	Move: (self: NpcRecord, direction: Vector3) -> (),
	Stop: (self: NpcRecord) -> (),
	SetHeading: (self: NpcRecord, heading: number) -> (),
	LookAt: (self: NpcRecord, position: Vector3) -> (),
	SetWalkSpeed: (self: NpcRecord, walkSpeed: number) -> (),
	SetThinkHz: (self: NpcRecord, hz: number) -> (),
	SetReplicationHz: (self: NpcRecord, hz: number) -> (),
	-- Visibility for every player without a per-player override.
	SetVisibleFlag: (self: NpcRecord, visible: boolean) -> (),
	-- Per-player override. nil removes it.
	SetPlayerVisibleFlag: (self: NpcRecord, player: Player, visible: boolean?) -> (),
	IsVisibleTo: (self: NpcRecord, player: Player) -> boolean,
	Destroy: (self: NpcRecord) -> (),
}

return nil
