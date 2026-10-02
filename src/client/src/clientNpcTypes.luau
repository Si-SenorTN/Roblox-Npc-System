--!strict
local Signal = require(script.Parent.Parent.Signal)

-- Metadata the server attached when it created the NPC.
export type CustomData = { [string]: any }

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
	-- Interpolated velocity, handy for driving animations
	Velocity: Vector3,
	Health: number,
	MaxHealth: number,
	IsDead: boolean,
	Visible: boolean,
	ReplicationHz: number,

	-- (newHealth, oldHealth)
	HealthChanged: Signal.Signal<number, number>,
	Died: Signal.Signal<()>,
	VisibilityChanged: Signal.Signal<boolean>,
}

return nil
