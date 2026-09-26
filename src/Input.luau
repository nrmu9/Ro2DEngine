--!optimize 2

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local KEYBOARD = Enum.UserInputType.Keyboard
local MB1 = Enum.UserInputType.MouseButton1
local MB2 = Enum.UserInputType.MouseButton2
local MB3 = Enum.UserInputType.MouseButton3
local WHEEL = Enum.UserInputType.MouseWheel
local MOUSEMOVE = Enum.UserInputType.MouseMovement
local TOUCH = Enum.UserInputType.Touch
local PADS = {}
for i = 1, 8 do
	local t = Enum.UserInputType["Gamepad" .. i]
	if t then PADS[t] = true end
end
local BUTTON_A = Enum.KeyCode.ButtonA
local THUMB1 = Enum.KeyCode.Thumbstick1
local THUMB2 = Enum.KeyCode.Thumbstick2

local Actions = require(script.Parent:WaitForChild("Actions"))

local Input = {
	KeysDown = {},
	KeysPressedThisFrame = {},
	Mouse = { X = 0, Y = 0, LeftDown = false, RightDown = false, ScrollDelta = 0 },
	GamepadActive = false,
	PadCursorX = 0,
	PadCursorY = 0,
	PadDown = false,
	PointerVisible = true,
	PointerParked = false,
}

local keysDown = Input.KeysDown
local keysPressed = Input.KeysPressedThisFrame
local keysArriving = {}
local wheelArriving = 0
local mouse = Input.Mouse
local mb1Down = false
local mb3Down = false
local padHeld = {}
local sticks = { 0, 0, 0, 0 }
local ptr, ptrShown, ptrEnded = nil, false, false
local pend, pendEnded = nil, false
local touchDown, touchX, touchY, touchLast = false, 0, 0, false
local padInit = false
local prevLive = false
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
local PAD_RESCAN = 0.1
local PAD_SWITCH_MARGIN = 0.25
local rescanAt = 0

local function stickOf(pad): (number, number, number, number)
	local ok, states = pcall(function() return UserInputService:GetGamepadState(pad) end)
	if not ok or not states then return 0, 0, 0, 0 end
	local lx, ly, rx, ry = 0, 0, 0, 0
	for _, o in ipairs(states) do
		if o.KeyCode == THUMB1 then
			lx, ly = o.Position.X, o.Position.Y
		elseif o.KeyCode == THUMB2 then
			rx, ry = o.Position.X, o.Position.Y
		end
	end
	return lx, ly, rx, ry
end

local function deflection(sx, sy, rx, ry)
	return math.max(sx * sx + sy * sy, rx * rx + ry * ry)
end

local function pollPads(now: number)
	local held = 0
	if activePad then
		local sx, sy, rx, ry = stickOf(activePad)
		sticks[1], sticks[2], sticks[3], sticks[4] = sx, sy, rx, ry
		held = deflection(sx, sy, rx, ry)
		if sx * sx + sy * sy > PAD_DEADZONE_SQ then Input.GamepadActive = true end
	else
		sticks[1], sticks[2], sticks[3], sticks[4] = 0, 0, 0, 0
	end
	if activePad and now < rescanAt then return end
	rescanAt = now + PAD_RESCAN
	local ok, pads = pcall(function() return UserInputService:GetConnectedGamepads() end)
	if not ok or pads == nil then return end
	local best, bestMag = nil, math.max(PAD_DEADZONE_SQ, held + PAD_SWITCH_MARGIN)
	local bx, by, brx, bry = 0, 0, 0, 0
	for _, pad in ipairs(pads) do
		if pad ~= activePad then
			local sx, sy, rx, ry = stickOf(pad)
			local mag = deflection(sx, sy, rx, ry)
			if mag > bestMag then
				best, bestMag = pad, mag
				bx, by, brx, bry = sx, sy, rx, ry
			end
		end
	end
	if best then
		activePad = best
		sticks[1], sticks[2], sticks[3], sticks[4] = bx, by, brx, bry
		Input.GamepadActive = true
		return
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
		if not activePad then activePad = t end
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

local function touchPos(input)
	local inset = GuiService:GetGuiInset()
	return input.Position.X + inset.X, input.Position.Y + inset.Y
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	local t = input.UserInputType
	local isPad = PADS[t]
	if isPad then activePad = t end
	local key, device = nil, nil
	if t == KEYBOARD or isPad then
		key, device = input.KeyCode.Name, isPad and "pad" or "kbm"
	elseif t == MB1 then key, device = "MouseLeftButton", "kbm"
	elseif t == MB2 then key, device = "MouseRightButton", "kbm"
	elseif t == MB3 then key, device = "MouseMiddleButton", "kbm" end
	if key and Actions.press(key, device, gameProcessed) then return end
	if isPad then padHeld[input.KeyCode] = true end
	if input.KeyCode == BUTTON_A then Input.PadDown = not Input.PointerParked end
	if gameProcessed then return end
	if t == KEYBOARD then
		keysDown[input.KeyCode] = true
		keysArriving[input.KeyCode] = true
	elseif t == MB1 then
		mb1Down = true
		mouse.LeftDown = true
		touchLast = touchLast and not UserInputService.MouseEnabled
	elseif t == MB2 then
		mouse.RightDown = true
		touchLast = touchLast and not UserInputService.MouseEnabled
	elseif t == MB3 then
		mb3Down = true
		touchLast = touchLast and not UserInputService.MouseEnabled
	elseif t == TOUCH then
		touchLast = true
		if ptr == nil and pend == nil then
			ptr, ptrShown, ptrEnded = input, false, false
			touchX, touchY = touchPos(input)
		else
			pend, pendEnded = input, false
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == BUTTON_A then Input.PadDown = false end
	local t = input.UserInputType
	if PADS[t] then padHeld[input.KeyCode] = nil end
	if t == KEYBOARD then
		keysDown[input.KeyCode] = false
	elseif t == MB1 then
		mb1Down = false
		mouse.LeftDown = touchDown
	elseif t == MB2 then
		mouse.RightDown = false
	elseif t == MB3 then
		mb3Down = false
	elseif t == TOUCH then
		if input == ptr then
			ptrEnded = true
			touchX, touchY = touchPos(input)
		elseif input == pend then
			pendEnded = true
		end
	end
end)

local BEGIN, CHANGE = Enum.UserInputState.Begin, Enum.UserInputState.Change
local function verifyHeld()
	if mb1Down and not UserInputService:IsMouseButtonPressed(MB1) then mb1Down = false end
	if mouse.RightDown and not UserInputService:IsMouseButtonPressed(MB2) then mouse.RightDown = false end
	if mb3Down and not UserInputService:IsMouseButtonPressed(MB3) then mb3Down = false end
	if next(padHeld) then
		local ok, pads = pcall(function() return UserInputService:GetConnectedGamepads() end)
		if not ok or pads == nil or #pads == 0 then
			table.clear(padHeld)
		else
			for kc in pairs(padHeld) do
				local down = false
				for _, pad in ipairs(pads) do
					local okB, v = pcall(UserInputService.IsGamepadButtonDown, UserInputService, pad, kc)
					if okB and v == true then
						down = true
						break
					end
				end
				if not down then padHeld[kc] = nil end
			end
		end
	end
	for kc, down in pairs(keysDown) do
		if down and not UserInputService:IsKeyDown(kc) then keysDown[kc] = false end
	end
end

local function stale(obj): boolean
	local st = obj.UserInputState
	return st ~= BEGIN and st ~= CHANGE
end

local function pointerStep()
	if ptr and not ptrEnded and stale(ptr) then ptrEnded = true end
	if pend and not pendEnded and stale(pend) then pendEnded = true end
	local off = false
	touchDown = false
	if ptr then
		if ptrEnded and ptrShown then
			ptr = nil
		elseif ptrEnded or not pend then
			if not ptrEnded then touchX, touchY = touchPos(ptr) end
			touchDown, ptrShown = true, true
		else
			ptr, off = nil, true
		end
	elseif pend then
		ptr, ptrShown, ptrEnded = pend, true, pendEnded
		pend, pendEnded = nil, false
		touchX, touchY = touchPos(ptr)
		touchDown = true
	end
	mouse.LeftDown = mb1Down or touchDown
	if off then
		mouse.X, mouse.Y = -100000, -100000
	elseif touchLast then
		mouse.X, mouse.Y = touchX, touchY
	else
		local pos = UserInputService:GetMouseLocation()
		mouse.X, mouse.Y = pos.X, pos.Y
	end
end

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if input.UserInputType == MOUSEMOVE and UserInputService.MouseEnabled then touchLast = false end
	if gameProcessed then return end
	if input.UserInputType == WHEEL then
		wheelArriving += input.Position.Z
	end
end)

function Input.Flush()
	table.clear(keysPressed)
	for code in pairs(keysArriving) do
		keysPressed[code] = true
	end
	table.clear(keysArriving)
	mouse.ScrollDelta = wheelArriving
	wheelArriving = 0
	verifyHeld()
	pointerStep()

	local now = os.clock()
	local dt = math.min(now - lastClock, 0.1)
	lastClock = now
	pollPads(now)
	local live = Input.GamepadActive and Input.PointerVisible
	if live and not prevLive then centerCursor() end
	prevLive = live
	if not Input.GamepadActive then Input.PointerParked = false end
	if live then
		if not padInit then centerCursor() end
		local sx, sy = readStick()
		if sx * sx + sy * sy > 0.0225 then
			Input.PointerParked = false
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
			Input.PadCursorX = math.clamp(Input.PadCursorX + sx * GAMEPAD_SPEED * dt, 0, vp.X)
			Input.PadCursorY = math.clamp(Input.PadCursorY - sy * GAMEPAD_SPEED * dt, 0, vp.Y)
		end
		ensureCursor()
	end
	local show = live and not Input.PointerParked
	if cursorGui then
		cursorGui.Enabled = show
		if show and cursorDot then
			cursorDot.Position = UDim2.fromOffset(Input.PadCursorX, Input.PadCursorY)
		end
	end
end

Actions.attach({
	keysDown = keysDown,
	padHeld = padHeld,
	sticks = sticks,
	mouseHeld = function(n: number): boolean
		if n == 1 then return mb1Down end
		if n == 2 then return mouse.RightDown end
		return n == 3 and mb3Down
	end,
})
Input.Actions = Actions

return Input
