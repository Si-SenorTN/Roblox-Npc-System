--!strict
-- Client-side distance culling. NPCs are binned into a uniform grid of XZ
-- cells. Only cells around the focus can hold NPCs within render distance,
-- so everything outside them is culled without a distance check. NPCs inside
-- get a distance check, and the next one is scheduled for the earliest moment
-- they could cross the cull edge: often near the edge, rarely far from it.

local Workspace = game:GetService("Workspace")

local NpcRecord = require(script.Parent.NpcRecord)

type Internal = NpcRecord.Internal

local CELL_SIZE = 64
local DEFAULT_CULL_DISTANCE = 300
-- Rendered NPCs are culled this far past their cull distance, so one walking
-- along the edge doesn't flicker in and out
local HYSTERESIS = 10
-- The focus moving further than this in one frame counts as a teleport, and
-- every NPC is re-checked right away
local TELEPORT_DISTANCE = 64
-- Studs per second added on top of the speeds assumed when scheduling checks
local SPEED_MARGIN = 8
-- Every NPC near the focus is checked at least this often, in seconds
local MAX_CHECK_INTERVAL = 1
-- How fast the focus speed estimate decays, per second
local FOCUS_SPEED_DECAY = 2
-- Cell coordinates are offset to keep keys positive and unique
local KEY_OFFSET = 2 ^ 20
local KEY_STRIDE = 2 ^ 21

-- Vector3 is the native vector type at runtime, but the type definitions
-- still treat them as different types
local magnitude: (Vector3) -> number = vector.magnitude :: any

local Culling = {}

local cells: { [number]: { [Internal]: true } } = {}
local activeCells: { [number]: true } = {}
local tracked: { [Internal]: true } = {}

local defaultDistance = DEFAULT_CULL_DISTANCE
local maxDistance = DEFAULT_CULL_DISTANCE
local activeRadius = -1
local distancesDirty = false
local refreshAll = false

local function cameraFocus(): Vector3
	local camera = Workspace.CurrentCamera
	return if camera then camera.CFrame.Position else Vector3.zero
end

local getFocus: () -> Vector3 = cameraFocus
local focus = Vector3.zero
local hasFocus = false
local focusCellX = math.huge
local focusCellZ = math.huge
local focusSpeed = 0
local now = 0

local function cellKey(position: Vector3): number
	local x = math.floor(position.X / CELL_SIZE)
	local z = math.floor(position.Z / CELL_SIZE)
	return (x + KEY_OFFSET) * KEY_STRIDE + (z + KEY_OFFSET)
end

local function removeFromCell(internal: Internal)
	local key = internal._cullCellKey
	if key == nil then
		return
	end
	internal._cullCellKey = nil
	local cell = cells[key]
	if cell then
		cell[internal] = nil
		if next(cell) == nil then
			cells[key] = nil
		end
	end
end

local function addToCell(internal: Internal, key: number)
	local cell = cells[key]
	if cell == nil then
		cell = {}
		cells[key] = cell
	end
	cell[internal] = true
	internal._cullCellKey = key
end

local function recomputeMaxDistance()
	local largest = defaultDistance
	for internal in tracked do
		local distance = internal.CullDistance
		if distance and distance > largest then
			largest = distance
		end
	end
	maxDistance = largest
end

local function updateActiveCells(centerKey: number)
	-- A cell outside this square is at least (radius - 1) cells away from the
	-- focus horizontally, which is past every NPC's cull distance
	local radius = math.ceil((maxDistance + HYSTERESIS) / CELL_SIZE) + 1
	activeRadius = radius

	local active: { [number]: true } = {}
	for dx = -radius, radius do
		for dz = -radius, radius do
			active[centerKey + dx * KEY_STRIDE + dz] = true
		end
	end

	for key in activeCells do
		if not active[key] then
			local cell = cells[key]
			if cell then
				for internal in cell do
					if internal.CullingEnabled then
						NpcRecord.setCulled(internal, true)
					end
				end
			end
		end
	end
	for key in active do
		if not activeCells[key] then
			local cell = cells[key]
			if cell then
				for internal in cell do
					internal._nextCullCheck = 0
				end
			end
		end
	end
	activeCells = active
end

local function check(internal: Internal)
	local cullDistance = internal.CullDistance or defaultDistance
	local distance = magnitude(internal.Position - focus)
	local culled = if internal.IsCulled then distance > cullDistance else distance > cullDistance + HYSTERESIS
	if culled ~= internal.IsCulled then
		NpcRecord.setCulled(internal, culled)
	end

	-- The soonest this NPC could cross the edge, if it and the focus head
	-- straight at each other
	local edge = if culled then cullDistance else cullDistance + HYSTERESIS
	local npcSpeed = math.max(internal.MoveSpeed, internal.StateMachine.WalkSpeed)
	local closingSpeed = npcSpeed + focusSpeed + SPEED_MARGIN
	internal._nextCullCheck = now + math.min(math.abs(distance - edge) / closingSpeed, MAX_CHECK_INTERVAL)
end

-- Sets the cull distance for NPCs without their own.
function Culling.setDefaultDistance(distance: number)
	defaultDistance = distance
	distancesDirty = true
	refreshAll = true
end

-- Sets where distances are measured from. nil measures from the camera.
function Culling.setFocus(getter: (() -> Vector3)?)
	getFocus = getter or cameraFocus
	refreshAll = true
end

-- Where distances were measured from this frame.
function Culling.getFocus(): Vector3
	return focus
end

function Culling.track(internal: Internal)
	tracked[internal] = true
	internal._nextCullCheck = 0
	if internal.CullDistance then
		distancesDirty = true
	end
end

function Culling.untrack(internal: Internal)
	tracked[internal] = nil
	removeFromCell(internal)
	if internal.CullDistance then
		distancesDirty = true
	end
end

-- Runs once per frame before any NPC is updated.
function Culling.beginFrame(currentTime: number, dt: number)
	now = currentTime

	local newFocus = getFocus()
	if hasFocus then
		local moved = magnitude(newFocus - focus)
		if moved > TELEPORT_DISTANCE then
			refreshAll = true
		elseif dt > 0 then
			local speed = moved / dt
			-- Checks scheduled for a slower focus could now be too late
			if speed > focusSpeed + SPEED_MARGIN then
				refreshAll = true
			end
			focusSpeed = math.max(speed, focusSpeed * (1 - math.min(dt * FOCUS_SPEED_DECAY, 1)))
		end
	end
	focus = newFocus
	hasFocus = true

	if distancesDirty then
		distancesDirty = false
		recomputeMaxDistance()
	end

	local centerKey = cellKey(focus)
	local x, z = math.floor(focus.X / CELL_SIZE), math.floor(focus.Z / CELL_SIZE)
	local radius = math.ceil((maxDistance + HYSTERESIS) / CELL_SIZE) + 1
	if x ~= focusCellX or z ~= focusCellZ or radius ~= activeRadius then
		focusCellX, focusCellZ = x, z
		updateActiveCells(centerKey)
	end

	if refreshAll then
		refreshAll = false
		for internal in tracked do
			internal._nextCullCheck = 0
		end
	end
end

-- Runs once per frame for every NPC, after its transform is updated.
function Culling.updateRecord(internal: Internal)
	if internal._cullSettingsChanged then
		internal._cullSettingsChanged = false
		internal._nextCullCheck = 0
		distancesDirty = true
	end
	if internal._teleported then
		internal._teleported = false
		internal._nextCullCheck = 0
	end

	local key = cellKey(internal.Position)
	if key ~= internal._cullCellKey then
		removeFromCell(internal)
		addToCell(internal, key)
		internal._nextCullCheck = 0
	end

	if not internal.CullingEnabled then
		if internal.IsCulled then
			NpcRecord.setCulled(internal, false)
		end
	elseif not activeCells[key] then
		if not internal.IsCulled then
			NpcRecord.setCulled(internal, true)
		end
	elseif now >= internal._nextCullCheck then
		check(internal)
	end
end

return Culling
