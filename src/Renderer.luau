local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local AssetService = game:GetService("AssetService")

local Input = require(script.Parent:WaitForChild("Input"))
local UI = require(script.Parent:WaitForChild("UI"))

local writeu8, readu8, copy, create = buffer.writeu8, buffer.readu8, buffer.copy, buffer.create
local floor, sqrt, min, max, clamp = math.floor, math.sqrt, math.min, math.max, math.clamp
local V2_ZERO = Vector2.zero 

local Renderer = {
	System = {},
	Draw = {},
	Camera = { X = 0, Y = 0 },
	Grid = { ChunksX = 0, ChunksY = 0, Scale = 1, AntiAliasing = false, IsReady = false },
	Resolution = Vector2.new(0, 0)
}

local CHUNK_SIZE = 1024
local MAX_BUFFER_SIZE = CHUNK_SIZE * CHUNK_SIZE * 4
local Chunks = {}
local ChunkUIElements = {}
local CanvasFrame = nil
local UploadBufferPool = {}
local ClearCache = {}
local DeveloperBackgroundCode = nil

-- INTERNAL CHUNK LOGIC
local function ClearMemory()
	for _, element in ipairs(ChunkUIElements) do element:Destroy() end
	table.clear(Chunks)
	table.clear(ChunkUIElements)
end

local function RebuildGrid()
	if not CanvasFrame then return end
	ClearMemory()
	Renderer.Grid.IsReady = false

	local targetWidth = floor(Renderer.Resolution.X * Renderer.Grid.Scale)
	local targetHeight = floor(Renderer.Resolution.Y * Renderer.Grid.Scale)
	if targetWidth <= 0 or targetHeight <= 0 then return end

	local chunksX = math.ceil(targetWidth / CHUNK_SIZE)
	local chunksY = math.ceil(targetHeight / CHUNK_SIZE)
	Renderer.Grid.ChunksX, Renderer.Grid.ChunksY = chunksX, chunksY

	local filterMode = Renderer.Grid.AntiAliasing and Enum.ResamplerMode.Default or Enum.ResamplerMode.Pixelated

	for y = 0, chunksY - 1 do
		Chunks[y] = {}
		for x = 0, chunksX - 1 do
			local offsetX = x * CHUNK_SIZE
			local offsetY = y * CHUNK_SIZE
			local chunkW = min(CHUNK_SIZE, targetWidth - offsetX)
			local chunkH = min(CHUNK_SIZE, targetHeight - offsetY)

			local uiOffsetX = offsetX / Renderer.Grid.Scale
			local uiOffsetY = offsetY / Renderer.Grid.Scale
			local uiW = chunkW / Renderer.Grid.Scale
			local uiH = chunkH / Renderer.Grid.Scale

			local frame = Instance.new("ImageLabel")
			frame.Name = string.format("Chunk_%d_%d", x, y)
			frame.BackgroundTransparency = 1
			frame.BorderSizePixel = 0
			frame.Position = UDim2.fromOffset(uiOffsetX, uiOffsetY)
			frame.Size = UDim2.fromOffset(uiW, uiH)
			frame.ResampleMode = filterMode
			frame.Parent = CanvasFrame
			table.insert(ChunkUIElements, frame)

			local image = AssetService:CreateEditableImage({ Size = Vector2.new(chunkW, chunkH) })
			frame.ImageContent = Content.fromObject(image)

			Chunks[y][x] = {
				Image = image,
				Buffer = create(chunkW * chunkH * 4),
				BgBuffer = create(chunkW * chunkH * 4),
				Width = chunkW, Height = chunkH,
				MinX = chunkW, MaxX = -1, MinY = chunkH, MaxY = -1,
				PrevMinX = chunkW, PrevMaxX = -1, PrevMinY = chunkH, PrevMaxY = -1,
			}
		end
	end
	
	UI.Init(CanvasFrame, targetWidth, targetHeight, Renderer.Grid.Scale)
	
	Renderer.Grid.IsReady = true
end

-- SYSTEM NAMESPACE
function Renderer.System.Init(canvasFrame: Frame, config: any)
	config = config or {}
	Renderer.Grid.Scale = clamp(config.RenderScale or 1, 0.1, 1)
	Renderer.Grid.AntiAliasing = config.AntiAliasing or false

	if config.Isolate2D then
		pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false) end)
		local camera = workspace.CurrentCamera
		if camera then camera.CameraType = Enum.CameraType.Scriptable end

		local player = Players.LocalPlayer
		if player.Character then player.Character:Destroy() end
		player.CharacterAdded:Connect(function(char) char:Destroy() end)
	end

	canvasFrame.ClipsDescendants = true
	canvasFrame.BackgroundTransparency = 0 
	canvasFrame.BackgroundColor3 = Color3.new(0, 0, 0) 
	canvasFrame.BorderSizePixel = 0
	canvasFrame.Active = false
	canvasFrame.Interactable = false 
	for _, child in ipairs(canvasFrame:GetChildren()) do
		if child:IsA("UILayout") then child:Destroy() end
	end
	if canvasFrame.Parent and canvasFrame.Parent:IsA("ScreenGui") then
		canvasFrame.Parent.IgnoreGuiInset = true
	end

	CanvasFrame = canvasFrame

	local resizeThread = nil
	local function syncResolution()
		local currentSize = CanvasFrame.AbsoluteSize
		if currentSize.X > 0 and currentSize.Y > 0 then
			Renderer.Resolution = currentSize
			ClearMemory()
			Renderer.Grid.IsReady = false
			if resizeThread then task.cancel(resizeThread) end
			resizeThread = task.delay(0.05, RebuildGrid)
		end
	end

	CanvasFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncResolution)
	syncResolution() 
end

function Renderer.System.ScreenToCanvas(screenX: number, screenY: number)
	local scale = Renderer.Grid.Scale
	return floor(screenX * scale), floor(screenY * scale)
end

function Renderer.System.SetBackground(callback)
	DeveloperBackgroundCode = callback
	if not DeveloperBackgroundCode or not Renderer.Grid.IsReady then return end

	DeveloperBackgroundCode() 

	for y = 0, Renderer.Grid.ChunksY - 1 do
		for x = 0, Renderer.Grid.ChunksX - 1 do
			local chunk = Chunks[y] and Chunks[y][x]
			if chunk then
				local len = chunk.Width * chunk.Height * 4
				copy(chunk.BgBuffer, 0, chunk.Buffer, 0, len)

				if not chunk.FullSizeVector then chunk.FullSizeVector = Vector2.new(chunk.Width, chunk.Height) end
				chunk.Image:WritePixelsBuffer(V2_ZERO, chunk.FullSizeVector, chunk.Buffer)

				chunk.MinX = chunk.Width; chunk.MaxX = -1
				chunk.MinY = chunk.Height; chunk.MaxY = -1
				chunk.PrevMinX = chunk.Width; chunk.PrevMaxX = -1
				chunk.PrevMinY = chunk.Height; chunk.PrevMaxY = -1
			end
		end
	end
end

-- DRAW NAMESPACE
function Renderer.Draw.Pixel(worldX: number, worldY: number, r: number, g: number, b: number, a: number)
	if not Renderer.Grid.IsReady then return end

	local screenX = worldX - Renderer.Camera.X
	local screenY = worldY - Renderer.Camera.Y
	local scale = Renderer.Grid.Scale
	local x, y = floor(screenX), floor(screenY)

	if x < 0 or x >= floor(Renderer.Resolution.X * scale) or y < 0 or y >= floor(Renderer.Resolution.Y * scale) then return end

	local chunk = Chunks[floor(y / CHUNK_SIZE)] and Chunks[floor(y / CHUNK_SIZE)][floor(x / CHUNK_SIZE)]
	if not chunk then return end

	local localX, localY = x % CHUNK_SIZE, y % CHUNK_SIZE
	if localX >= chunk.Width or localY >= chunk.Height then return end

	local index = ((localY * chunk.Width) + localX) * 4
	writeu8(chunk.Buffer, index, r)
	writeu8(chunk.Buffer, index + 1, g)
	writeu8(chunk.Buffer, index + 2, b)
	writeu8(chunk.Buffer, index + 3, a or 255)

	if localX < chunk.MinX then chunk.MinX = localX end
	if localX > chunk.MaxX then chunk.MaxX = localX end
	if localY < chunk.MinY then chunk.MinY = localY end
	if localY > chunk.MaxY then chunk.MaxY = localY end
end

function Renderer.Draw.Sprite(worldX: number, worldY: number, sprite: any, flipX: boolean?, flipY: boolean?)
	if not Renderer.Grid.IsReady or sprite.IsEmpty then return end

	local startX = floor(worldX - Renderer.Camera.X)
	local startY = floor(worldY - Renderer.Camera.Y)
	local w, h, buf, bounds = sprite.Width, sprite.Height, sprite.Buffer, sprite.RowBounds
	local scale = Renderer.Grid.Scale
	local screenW = floor(Renderer.Resolution.X * scale)
	local screenH = floor(Renderer.Resolution.Y * scale)

	for y = 0, h - 1 do
		local readY = flipY and (h - 1 - y) or y
		local row = bounds[readY]

		if row.MinX ~= -1 then
			local drawY = startY + y
			if drawY >= 0 and drawY < screenH then
				local chunkY = floor(drawY / CHUNK_SIZE)
				local localY = drawY % CHUNK_SIZE
				local chunkRow = Chunks[chunkY]

				if chunkRow then
					local srcRowOffset = (readY * w) * 4
					local destMinX = flipX and (w - 1 - row.MaxX) or row.MinX
					local destMaxX = flipX and (w - 1 - row.MinX) or row.MaxX

					local startDrawX = startX + destMinX
					local chunkX = floor(startDrawX / CHUNK_SIZE)
					local localX = startDrawX % CHUNK_SIZE
					local chunk = chunkRow[chunkX]

					for destX = destMinX, destMaxX do
						local readX = flipX and (w - 1 - destX) or destX
						if startDrawX >= 0 and startDrawX < screenW then
							local index = srcRowOffset + (readX * 4)
							local a = readu8(buf, index + 3)

							if a > 0 and chunk then
								local destIndex = ((localY * chunk.Width) + localX) * 4
								writeu8(chunk.Buffer, destIndex, readu8(buf, index))
								writeu8(chunk.Buffer, destIndex + 1, readu8(buf, index + 1))
								writeu8(chunk.Buffer, destIndex + 2, readu8(buf, index + 2))
								writeu8(chunk.Buffer, destIndex + 3, a)

								if localX < chunk.MinX then chunk.MinX = localX end
								if localX > chunk.MaxX then chunk.MaxX = localX end
								if localY < chunk.MinY then chunk.MinY = localY end
								if localY > chunk.MaxY then chunk.MaxY = localY end
							end
						end
						startDrawX = startDrawX + 1
						localX = localX + 1
						if localX >= CHUNK_SIZE then
							localX = 0
							chunkX = chunkX + 1
							chunk = chunkRow[chunkX]
						end
					end
				end
			end
		end
	end
end

function Renderer.Draw.LineSDF(worldX0: number, worldY0: number, worldX1: number, worldY1: number, thickness: number, r: number, g: number, b: number)
	if not Renderer.Grid.IsReady then return end

	local x0 = worldX0 - Renderer.Camera.X
	local y0 = worldY0 - Renderer.Camera.Y
	local x1 = worldX1 - Renderer.Camera.X
	local y1 = worldY1 - Renderer.Camera.Y

	local halfThick = thickness / 2
	local dx, dy = x1 - x0, y1 - y0
	local lengthSquared = (dx * dx) + (dy * dy)

	local minX = floor(min(x0, x1) - halfThick - 1)
	local maxX = floor(max(x0, x1) + halfThick + 1)
	local minY = floor(min(y0, y1) - halfThick - 1)
	local maxY = floor(max(y0, y1) + halfThick + 1)

	for py = minY, maxY do
		for px = minX, maxX do
			local t = 0
			if lengthSquared > 0 then t = max(0, min(1, ((px - x0) * dx + (py - y0) * dy) / lengthSquared)) end
			local dist = sqrt((px - (x0 + t * dx))^2 + (py - (y0 + t * dy))^2)

			if dist <= halfThick + 1 then
				local a = 255
				if dist > halfThick then a = floor(255 * (1 - (dist - halfThick))) end
				if a > 5 then Renderer.Draw.Pixel(px + Renderer.Camera.X, py + Renderer.Camera.Y, r, g, b, a) end
			end
		end
	end
end

function Renderer.Draw.CircleSDF(worldX: number, worldY: number, radius: number, r: number, g: number, b: number, a: number?)
	if not Renderer.Grid.IsReady then return end
	a = a or 255

	local startX = floor(worldX - radius)
	local startY = floor(worldY - radius)
	local endX = floor(worldX + radius)
	local endY = floor(worldY + radius)

	local radSq = radius * radius

	for py = startY, endY do
		for px = startX, endX do
			local dx = px - worldX
			local dy = py - worldY
			if (dx * dx) + (dy * dy) <= radSq then
				Renderer.Draw.Pixel(px, py, r, g, b, a)
			end
		end
	end
end

function Renderer.Draw.Clear(r: number, g: number, b: number, a: number)
	if not Renderer.Grid.IsReady then return end
	a = a or 255
	local colorKey = string.format("%d_%d_%d_%d", r, g, b, a)

	if not ClearCache[colorKey] then
		local temp = create(MAX_BUFFER_SIZE)
		for i = 0, MAX_BUFFER_SIZE - 1, 4 do
			writeu8(temp, i, r)
			writeu8(temp, i+1, g)
			writeu8(temp, i+2, b)
			writeu8(temp, i+3, a)
		end
		ClearCache[colorKey] = temp
	end

	for y = 0, Renderer.Grid.ChunksY - 1 do
		for x = 0, Renderer.Grid.ChunksX - 1 do
			local chunk = Chunks[y] and Chunks[y][x]
			if chunk then
				copy(chunk.Buffer, 0, ClearCache[colorKey], 0, chunk.Width * chunk.Height * 4)
				chunk.MinX = 0; chunk.MaxX = chunk.Width - 1
				chunk.MinY = 0; chunk.MaxY = chunk.Height - 1
			end
		end
	end
end

-- GPU AUTO-RENDER LOOP
local wasReady = false
RunService:BindToRenderStep("Ro2DEngineFlush", Enum.RenderPriority.Last.Value, function()
	if not Renderer.Grid.IsReady then 
		wasReady = false
		return 
	end

	if not wasReady then
		wasReady = true
		if DeveloperBackgroundCode then Renderer.System.SetBackground(DeveloperBackgroundCode) end
	end

	for y = 0, Renderer.Grid.ChunksY - 1 do
		for x = 0, Renderer.Grid.ChunksX - 1 do
			local chunk = Chunks[y] and Chunks[y][x]
			if chunk then
				local hasCurrent = chunk.MinX <= chunk.MaxX
				local hasPrev = chunk.PrevMinX <= chunk.PrevMaxX

				if hasCurrent or hasPrev then
					local uMinX = chunk.Width
					local uMaxX = -1
					local uMinY = chunk.Height
					local uMaxY = -1

					if hasCurrent then
						uMinX = min(uMinX, chunk.MinX); uMaxX = max(uMaxX, chunk.MaxX)
						uMinY = min(uMinY, chunk.MinY); uMaxY = max(uMaxY, chunk.MaxY)
					end
					if hasPrev then
						uMinX = min(uMinX, chunk.PrevMinX); uMaxX = max(uMaxX, chunk.PrevMaxX)
						uMinY = min(uMinY, chunk.PrevMinY); uMaxY = max(uMaxY, chunk.PrevMaxY)
					end

					local rectW = uMaxX - uMinX + 1
					local rectH = uMaxY - uMinY + 1

					if rectW == chunk.Width and rectH == chunk.Height then
						if not chunk.FullSizeVector then chunk.FullSizeVector = Vector2.new(chunk.Width, chunk.Height) end
						chunk.Image:WritePixelsBuffer(V2_ZERO, chunk.FullSizeVector, chunk.Buffer)
					else
						local requiredBytes = rectW * rectH * 4
						local tempBuf = UploadBufferPool[requiredBytes]
						if not tempBuf then
							tempBuf = create(requiredBytes)
							UploadBufferPool[requiredBytes] = tempBuf
						end

						for row = 0, rectH - 1 do
							local srcOffset = (((uMinY + row) * chunk.Width) + uMinX) * 4
							copy(tempBuf, (row * rectW) * 4, chunk.Buffer, srcOffset, rectW * 4)
						end
						chunk.Image:WritePixelsBuffer(Vector2.new(uMinX, uMinY), Vector2.new(rectW, rectH), tempBuf)
					end

					if hasCurrent then
						for row = chunk.MinY, chunk.MaxY do
							local offset = (((row * chunk.Width) + chunk.MinX) * 4)
							local len = (chunk.MaxX - chunk.MinX + 1) * 4
							copy(chunk.Buffer, offset, chunk.BgBuffer, offset, len)
						end
					end

					chunk.PrevMinX = chunk.MinX; chunk.PrevMaxX = chunk.MaxX
					chunk.PrevMinY = chunk.MinY; chunk.PrevMaxY = chunk.MaxY
					chunk.MinX = chunk.Width; chunk.MaxX = -1
					chunk.MinY = chunk.Height; chunk.MaxY = -1
				end
			end
		end
	end

	Input.Flush()
	UI.Flush()
end)

return Renderer