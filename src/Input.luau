--!optimize 2
-- Ro2D :: Input
-- Polls keyboard/mouse state. Per-frame state (pressed-this-frame, scroll delta)
-- is reset by Flush(), which the renderer calls at the end of every frame.

local UserInputService = game:GetService("UserInputService")

local KEYBOARD = Enum.UserInputType.Keyboard
local MB1 = Enum.UserInputType.MouseButton1
local MB2 = Enum.UserInputType.MouseButton2
local WHEEL = Enum.UserInputType.MouseWheel

local Input = {
	KeysDown = {},
	KeysPressedThisFrame = {},
	Mouse = { X = 0, Y = 0, LeftDown = false, RightDown = false, ScrollDelta = 0 },
}

local keysDown = Input.KeysDown
local keysPressed = Input.KeysPressedThisFrame
local mouse = Input.Mouse

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	local t = input.UserInputType
	if t == KEYBOARD then
		keysDown[input.KeyCode] = true
		keysPressed[input.KeyCode] = true
	elseif t == MB1 then
		mouse.LeftDown = true
	elseif t == MB2 then
		mouse.RightDown = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local t = input.UserInputType
	if t == KEYBOARD then
		keysDown[input.KeyCode] = false
	elseif t == MB1 then
		mouse.LeftDown = false
	elseif t == MB2 then
		mouse.RightDown = false
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType == WHEEL then
		mouse.ScrollDelta += input.Position.Z
	end
end)

function Input.Flush()
	table.clear(keysPressed)
	mouse.ScrollDelta = 0
	local pos = UserInputService:GetMouseLocation()
	mouse.X = pos.X
	mouse.Y = pos.Y
end

return Input
