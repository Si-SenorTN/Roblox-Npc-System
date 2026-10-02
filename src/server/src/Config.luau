--!strict
local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.serverNpcTypes)

type NpcConfig = Types.NpcConfig
type ResolvedNpcConfig = Types.ResolvedNpcConfig

local KNOWN_KEYS: { [string]: boolean } = {
	SpawnCFrame = true,
	ThinkHz = true,
	ReplicationHz = true,
	MotionHz = true,
	HitboxSize = true,
	BlockcastSize = true,
	CustomData = true,
	MaxHealth = true,
	Health = true,
	WalkSpeed = true,
	StepHeight = true,
	Gravity = true,
	AutoRotate = true,
	TurnSpeed = true,
	MoveToTimeout = true,
	Visible = true,
	CollisionGroup = true,
	AlignRigToHitbox = true,
}

local Config = {}

-- table.freeze that keeps the original type, the new solver otherwise makes
-- every property read-only and the table stops matching its declared type
local function freeze<T>(value: T): T
	table.freeze(value :: any)
	return value
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function positive(value: number?, default: number, name: string): number
	local resolved = if value == nil then default else value
	assert(
		typeof(resolved) == "number" and isFiniteNumber(resolved) and resolved > 0,
		`NpcConfig.{name} must be a positive number`
	)
	return resolved
end

local function nonNegative(value: number?, default: number, name: string): number
	local resolved = if value == nil then default else value
	assert(
		typeof(resolved) == "number" and isFiniteNumber(resolved) and resolved >= 0,
		`NpcConfig.{name} must be a non-negative number`
	)
	return resolved
end

local function size(value: Vector3?, default: Vector3, name: string): Vector3
	local resolved = if value == nil then default else value
	assert(
		typeof(resolved) == "Vector3" and resolved.X > 0 and resolved.Y > 0 and resolved.Z > 0,
		`NpcConfig.{name} must be a Vector3 with positive components`
	)
	return resolved
end

local function flag(value: boolean?, default: boolean, name: string): boolean
	local resolved = if value == nil then default else value
	assert(typeof(resolved) == "boolean", `NpcConfig.{name} must be a boolean`)
	return resolved
end

function Config.resolve(input: NpcConfig?, template: Model): ResolvedNpcConfig
	local config: NpcConfig = input or {}
	assert(typeof(config) == "table", "NpcConfig must be a table")
	for key in config :: { [any]: any } do
		assert(KNOWN_KEYS[key], `Unknown NpcConfig key "{tostring(key)}"`)
	end

	local spawnCFrame = if config.SpawnCFrame == nil then template:GetPivot() else config.SpawnCFrame
	assert(typeof(spawnCFrame) == "CFrame", "NpcConfig.SpawnCFrame must be a CFrame")

	local hitboxSize = size(config.HitboxSize, template:GetExtentsSize(), "HitboxSize")
	local maxHealth = positive(config.MaxHealth, 100, "MaxHealth")
	local health = nonNegative(config.Health, maxHealth, "Health")
	assert(health <= maxHealth, "NpcConfig.Health can't exceed MaxHealth")

	local customData = if config.CustomData == nil then {} else config.CustomData
	assert(typeof(customData) == "table", "NpcConfig.CustomData must be a table")

	-- math.huge is allowed and turns instantly
	local turnSpeed = if config.TurnSpeed == nil then 4 * math.pi else config.TurnSpeed
	assert(typeof(turnSpeed) == "number" and turnSpeed > 0, "NpcConfig.TurnSpeed must be a positive number")

	local collisionGroup = if config.CollisionGroup == nil then "Default" else config.CollisionGroup
	assert(typeof(collisionGroup) == "string", "NpcConfig.CollisionGroup must be a string")

	local resolved: ResolvedNpcConfig = {
		SpawnCFrame = spawnCFrame,
		ThinkHz = positive(config.ThinkHz, 10, "ThinkHz"),
		ReplicationHz = positive(config.ReplicationHz, 20, "ReplicationHz"),
		MotionHz = positive(config.MotionHz, 30, "MotionHz"),
		HitboxSize = hitboxSize,
		BlockcastSize = size(config.BlockcastSize, hitboxSize, "BlockcastSize"),
		CustomData = freeze(table.clone(customData)),
		MaxHealth = maxHealth,
		Health = health,
		WalkSpeed = nonNegative(config.WalkSpeed, 16, "WalkSpeed"),
		StepHeight = nonNegative(config.StepHeight, math.min(2, hitboxSize.Y * 0.4), "StepHeight"),
		Gravity = nonNegative(config.Gravity, Workspace.Gravity, "Gravity"),
		AutoRotate = flag(config.AutoRotate, true, "AutoRotate"),
		TurnSpeed = turnSpeed,
		MoveToTimeout = positive(config.MoveToTimeout, 8, "MoveToTimeout"),
		Visible = flag(config.Visible, true, "Visible"),
		CollisionGroup = collisionGroup,
		AlignRigToHitbox = flag(config.AlignRigToHitbox, true, "AlignRigToHitbox"),
	}

	return freeze(resolved)
end

return Config
