--!strict
-- Humanoid-like state machine for animation controllers like SimpleAnimate.

local Signal = require(script.Parent.Parent.Signal)
local Types = require(script.Parent.clientNpcTypes)

type StateMachine = Types.StateMachine

local DEFAULT_WALK_SPEED = 16

local StateMachine = {}

local function setState(self: StateMachine, state: Enum.HumanoidStateType)
	assert(
		typeof(state) == "EnumItem" and state.EnumType == Enum.HumanoidStateType,
		"state must be an Enum.HumanoidStateType"
	)
	local old = self.State
	if state == old then
		return
	end
	self.State = state
	self.StateChanged:Fire(old, state)
end

local function getState(self: StateMachine): Enum.HumanoidStateType
	return self.State
end

function StateMachine.new(): StateMachine
	return {
		Running = Signal.new(),
		Jumping = Signal.new(),
		Climbing = Signal.new(),
		Swimming = Signal.new(),
		StateChanged = Signal.new(),
		WalkSpeed = DEFAULT_WALK_SPEED,
		State = Enum.HumanoidStateType.None,
		SetState = setState,
		GetState = getState,
	}
end

function StateMachine.destroy(self: StateMachine)
	self.Running:Destroy()
	self.Jumping:Destroy()
	self.Climbing:Destroy()
	self.Swimming:Destroy()
	self.StateChanged:Destroy()
end

return StateMachine
