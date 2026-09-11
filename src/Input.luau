--!optimize 2

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local KEYBOARD = Enum.UserInputType.Keyboard
local MB1 = Enum.UserInputType.MouseButton1
local MB2 = Enum.UserInputType.MouseButton2
local WHEEL = Enum.UserInputType.MouseWheel
local TOUCH = Enum.UserInputType.Touch
local PADS = {}
for i = 1, 8 do
	local t = Enum.UserInputType["Gamepad" .. i]
	if t then PADS[t] = true end
end
local BUTTON_A = Enum.KeyCode.ButtonA
local THUMB1 = Enum.KeyCode.Thumbstick1

local Input = {
	KeysDown = {},
	KeysPressedThisFrame = {},
	Mouse = { X = 0, Y = 0, LeftDown = false, RightDown = false, ScrollDelta = 0 },
	GamepadActive = false,
	PadCursorX = 0,
	PadCursorY = 0,
	PadDown = false,
	PointerVisible = true,
}

local keysDown = Input.KeysDown
local keysPressed = Input.KeysPressedThisFrame
local mouse = Input.Mouse
local mb1Down = false
local touchCount = 0
local padInit = false
local prevShow = false
local lastClock = os.clock()
local GAMEPAD_SPEED = 1100

local activePad = nil
local function firstPad()
	local ok, pads = pcall(function() return UserInputService:GetNavigationGamepads() end)
	if ok and pads ~= nil and #pads > 0 then return pads[1] end
	ok, pads = pcall(function() return UserInputService:GetConnectedGamepads() end)
	if ok and pads ~= nil and #pads > 0 then return pads[1] end
	return nil
end

local PAD_DEADZONE_SQ = 0.15 * 0.15
local PAD_RESCAN = 0.25
local rescanAt = 0

local function stickOf(pad): (number, number)
	local ok, states = pcall(function() return UserInputService:GetGamepadState(pad) end)
	if not ok or not states then return 0, 0 end
	for _, o in ipairs(states) do
		if o.KeyCode == THUMB1 then return o.Position.X, o.Position.Y end
	end
	return 0, 0
end

local function pollPads(now: number)
	if activePad then
		local sx, sy = stickOf(activePad)
		if sx * sx + sy * sy > PAD_DEADZONE_SQ then
			Input.GamepadActive = true
			return
		end
	end
	if activePad and now < rescanAt then return end
	rescanAt = now + PAD_RESCAN
	local ok, pads = pcall(function() return UserInputService:GetConnectedGamepads() end)
	if not ok or pads == nil then return end
	for _, pad in ipairs(pads) do
		if pad ~= activePad then
			local sx, sy = stickOf(pad)
			if sx * sx + sy * sy > PAD_DEADZONE_SQ then
				activePad = pad
				Input.GamepadActive = true
				return
			end
		end
	end
	if not activePad and #pads > 0 then activePad = firstPad() end
end

local function readStick()
	if not activePad then activePad = firstPad() end
	if not activePad then return 0, 0 end
	local ok, states = pcall(function() return UserInputService:GetGamepadState(activePad) end)
	if ok and states then
		for _, o in ipairs(states) do
			if o.KeyCode == THUMB1 then return o.Position.X, o.Position.Y end
		end
	end
	return 0, 0
end

local cursorGui, cursorDot
local function ensureCursor()
	if cursorGui then return end
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return end
	cursorGui = Instance.new("ScreenGui")
	cursorGui.Name = "Ro2DPadCursor"
	cursorGui.DisplayOrder = 2000000
	cursorGui.IgnoreGuiInset = true
	cursorGui.ResetOnSpawn = false
	cursorGui.Enabled = false
	cursorDot = Instance.new("Frame")
	cursorDot.Name = "Ro2DCursorDot"
	cursorDot.Size = UDim2.fromOffset(16, 16)
	cursorDot.AnchorPoint = Vector2.new(0.5, 0.5)
	cursorDot.BackgroundColor3 = Color3.new(1, 1, 1)
	cursorDot.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.Name = "Ro2DCursorCorner"
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = cursorDot
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Ro2DCursorStroke"
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = cursorDot
	cursorDot.Parent = cursorGui
	cursorGui.Parent = pg
end

local function centerCursor()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	Input.PadCursorX, Input.PadCursorY = vp.X * 0.5, vp.Y * 0.5
	padInit = true
end

UserInputService.LastInputTypeChanged:Connect(function(t)
	if PADS[t] then
		activePad = t
		Input.GamepadActive = true
		if not padInit then centerCursor() end
	elseif t == Enum.UserInputType.MouseMovement or t == MB1 or t == TOUCH or t == KEYBOARD then
		Input.GamepadActive = false
	end
end)

UserInputService.GamepadConnected:Connect(function(gamepad)
	activePad = (gamepad ~= nil and PADS[gamepad] and gamepad) or firstPad()
end)
UserInputService.GamepadDisconnected:Connect(function()
	activePad = firstPad()
end)

local touches = {}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if PADS[input.UserInputType] then activePad = input.UserInputType end
	if input.KeyCode == BUTTON_A then Input.PadDown = true end
	if gameProcessed then return end
	local t = input.UserInputType
	if t == KEYBOARD then
		keysDown[input.KeyCode] = true
		keysPressed[input.KeyCode] = true
	elseif t == MB1 then
		mb1Down = true
		mouse.LeftDown = true
	elseif t == MB2 then
		mouse.RightDown = true
	elseif t == TOUCH then
		if not touches[input] then
			touches[input] = true
			touchCount += 1
		end
		mouse.LeftDown = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == BUTTON_A then Input.PadDown = false end
	local t = input.UserInputType
	if t == KEYBOARD then
		keysDown[input.KeyCode] = false
	elseif t == MB1 then
		mb1Down = false
		mouse.LeftDown = touchCount > 0
	elseif t == MB2 then
		mouse.RightDown = false
	elseif t == TOUCH then
		if touches[input] then
			touches[input] = nil
			touchCount -= 1
		end
		mouse.LeftDown = mb1Down or touchCount > 0
	end
end)

local BEGIN, CHANGE = Enum.UserInputState.Begin, Enum.UserInputState.Change
local function verifyHeld()
	if mb1Down and not UserInputService:IsMouseButtonPressed(MB1) then mb1Down = false end
	if mouse.RightDown and not UserInputService:IsMouseButtonPressed(MB2) then mouse.RightDown = false end
	if touchCount > 0 then
		for obj in pairs(touches) do
			local st = obj.UserInputState
			if st ~= BEGIN and st ~= CHANGE then
				touches[obj] = nil
				touchCount -= 1
			end
		end
		if touchCount < 0 then touchCount = 0 end
	end
	mouse.LeftDown = mb1Down or touchCount > 0
	for kc, down in pairs(keysDown) do
		if down and not UserInputService:IsKeyDown(kc) then keysDown[kc] = false end
	end
end

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType == WHEEL then
		mouse.ScrollDelta += input.Position.Z
	end
end)

function Input.Flush()
	table.clear(keysPressed)
	mouse.ScrollDelta = 0
	verifyHeld()
	local pos = UserInputService:GetMouseLocation()
	mouse.X = pos.X
	mouse.Y = pos.Y

	local now = os.clock()
	local dt = math.min(now - lastClock, 0.1)
	lastClock = now
	pollPads(now)
	local show = Input.GamepadActive and Input.PointerVisible
	if show and not prevShow then centerCursor() end
	prevShow = show
	if show then
		if not padInit then centerCursor() end
		local sx, sy = readStick()
		if sx * sx + sy * sy > 0.0225 then
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
			Input.PadCursorX = math.clamp(Input.PadCursorX + sx * GAMEPAD_SPEED * dt, 0, vp.X)
			Input.PadCursorY = math.clamp(Input.PadCursorY - sy * GAMEPAD_SPEED * dt, 0, vp.Y)
		end
		ensureCursor()
	end
	if cursorGui then
		cursorGui.Enabled = show
		if show and cursorDot then
			cursorDot.Position = UDim2.fromOffset(Input.PadCursorX, Input.PadCursorY)
		end
	end
end

return Input
