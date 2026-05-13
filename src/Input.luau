local UserInputService = game:GetService("UserInputService")

local Input = {
	KeysDown = {},
	KeysPressedThisFrame = {},
	Mouse = { X = 0, Y = 0, LeftDown = false, RightDown = false, ScrollDelta = 0 }
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		Input.KeysDown[input.KeyCode] = true
		Input.KeysPressedThisFrame[input.KeyCode] = true
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		Input.Mouse.LeftDown = true
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		Input.Mouse.RightDown = true
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		Input.KeysDown[input.KeyCode] = false
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		Input.Mouse.LeftDown = false
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		Input.Mouse.RightDown = false
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		Input.Mouse.ScrollDelta += input.Position.Z
	end
end)

function Input.Flush()
	table.clear(Input.KeysPressedThisFrame)
	Input.Mouse.ScrollDelta = 0
	local mPos = UserInputService:GetMouseLocation()
	Input.Mouse.X = mPos.X
	Input.Mouse.Y = mPos.Y
end

return Input