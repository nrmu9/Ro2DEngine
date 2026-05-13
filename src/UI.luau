local AssetService = game:GetService("AssetService")

local floor, max, min = math.floor, math.max, math.min
local writeu8, readu8 = buffer.writeu8, buffer.readu8

local UI = {
	LayerFrame = nil,
	Chunks = {},
	ChunkFrames = {},
	Width = 0,
	Height = 0,
	IsReady = false,
	CHUNK_SIZE = 1024 
}

function UI.Init(parentLayer: Frame, screenW: number, screenH: number, renderScale: number)
	UI.IsReady = false
	if UI.LayerFrame then UI.LayerFrame:Destroy() end

	UI.Width = screenW
	UI.Height = screenH
	table.clear(UI.Chunks)
	table.clear(UI.ChunkFrames)

	UI.LayerFrame = Instance.new("Frame")
	UI.LayerFrame.Name = "SoftwareUIBuffer"
	UI.LayerFrame.BackgroundTransparency = 1
	UI.LayerFrame.Size = UDim2.fromScale(1, 1)
	UI.LayerFrame.ZIndex = 100 
	UI.LayerFrame.Parent = parentLayer

	local chunksX = math.ceil(screenW / UI.CHUNK_SIZE)
	local chunksY = math.ceil(screenH / UI.CHUNK_SIZE)

	for y = 0, chunksY - 1 do
		UI.Chunks[y] = {}
		for x = 0, chunksX - 1 do
			local chunkW = min(UI.CHUNK_SIZE, screenW - (x * UI.CHUNK_SIZE))
			local chunkH = min(UI.CHUNK_SIZE, screenH - (y * UI.CHUNK_SIZE))

			local uiOffsetX = (x * UI.CHUNK_SIZE) / renderScale
			local uiOffsetY = (y * UI.CHUNK_SIZE) / renderScale
			local uiW = chunkW / renderScale
			local uiH = chunkH / renderScale

			local frame = Instance.new("ImageLabel")
			frame.Name = string.format("UIChunk_%d_%d", x, y)
			frame.BackgroundTransparency = 1
			frame.BorderSizePixel = 0
			frame.Position = UDim2.fromOffset(uiOffsetX, uiOffsetY)
			frame.Size = UDim2.fromOffset(uiW, uiH)
			frame.ResampleMode = Enum.ResamplerMode.Pixelated
			frame.Parent = UI.LayerFrame
			table.insert(UI.ChunkFrames, frame)

			local image = AssetService:CreateEditableImage({ Size = Vector2.new(chunkW, chunkH) })
			frame.ImageContent = Content.fromObject(image)

			local byteSize = chunkW * chunkH * 4
			local buf = buffer.create(byteSize)
			buffer.fill(buf, 0, 0, byteSize) 

			UI.Chunks[y][x] = {
				Image = image,
				Buffer = buf,
				Width = chunkW,
				Height = chunkH,
				ByteSize = byteSize,
				IsDirty = false
			}
		end
	end

	UI.IsReady = true
end

function UI.Clear()
	if not UI.IsReady then return end
	for y, row in pairs(UI.Chunks) do
		for x, chunk in pairs(row) do
			buffer.fill(chunk.Buffer, 0, 0, chunk.ByteSize)
			chunk.IsDirty = true
		end
	end
end

function UI.DrawFrame(screenX: number, screenY: number, w: number, h: number, r: number, g: number, b: number, a: number)
	if not UI.IsReady then return end
	a = a or 255
	if a == 0 then return end

	local startX = floor(screenX)
	local startY = floor(screenY)
	local endX = startX + w - 1
	local endY = startY + h - 1

	if startX >= UI.Width or startY >= UI.Height or endX < 0 or endY < 0 then return end

	startX = max(0, startX)
	startY = max(0, startY)
	endX = min(UI.Width - 1, endX)
	endY = min(UI.Height - 1, endY)

	local alphaRatio = a / 255
	local invAlpha = 1 - alphaRatio

	local startChunkX = floor(startX / UI.CHUNK_SIZE)
	local endChunkX = floor(endX / UI.CHUNK_SIZE)
	local startChunkY = floor(startY / UI.CHUNK_SIZE)
	local endChunkY = floor(endY / UI.CHUNK_SIZE)

	for cy = startChunkY, endChunkY do
		for cx = startChunkX, endChunkX do
			local chunk = UI.Chunks[cy] and UI.Chunks[cy][cx]
			if chunk then
				chunk.IsDirty = true

				local cStartX = max(startX, cx * UI.CHUNK_SIZE) - (cx * UI.CHUNK_SIZE)
				local cEndX = min(endX, (cx + 1) * UI.CHUNK_SIZE - 1) - (cx * UI.CHUNK_SIZE)
				local cStartY = max(startY, cy * UI.CHUNK_SIZE) - (cy * UI.CHUNK_SIZE)
				local cEndY = min(endY, (cy + 1) * UI.CHUNK_SIZE - 1) - (cy * UI.CHUNK_SIZE)

				for py = cStartY, cEndY do
					local rowOffset = py * chunk.Width
					for px = cStartX, cEndX do
						local index = (rowOffset + px) * 4

						if a == 255 then
							writeu8(chunk.Buffer, index, r)
							writeu8(chunk.Buffer, index + 1, g)
							writeu8(chunk.Buffer, index + 2, b)
							writeu8(chunk.Buffer, index + 3, 255)
						else
							local bgA = readu8(chunk.Buffer, index + 3)
							if bgA == 0 then
								writeu8(chunk.Buffer, index, r)
								writeu8(chunk.Buffer, index + 1, g)
								writeu8(chunk.Buffer, index + 2, b)
								writeu8(chunk.Buffer, index + 3, a)
							else
								local bgR = readu8(chunk.Buffer, index)
								local bgG = readu8(chunk.Buffer, index + 1)
								local bgB = readu8(chunk.Buffer, index + 2)
								writeu8(chunk.Buffer, index, floor((r * alphaRatio) + (bgR * invAlpha)))
								writeu8(chunk.Buffer, index + 1, floor((g * alphaRatio) + (bgG * invAlpha)))
								writeu8(chunk.Buffer, index + 2, floor((b * alphaRatio) + (bgB * invAlpha)))
								writeu8(chunk.Buffer, index + 3, max(bgA, a)) 
							end
						end
					end
				end
			end
		end
	end
end

function UI.Flush()
	if not UI.IsReady then return end

	for y, row in pairs(UI.Chunks) do
		for x, chunk in pairs(row) do
			if chunk.IsDirty then
				chunk.Image:WritePixelsBuffer(Vector2.zero, Vector2.new(chunk.Width, chunk.Height), chunk.Buffer)
				chunk.IsDirty = false 
			end
		end
	end
end

return UI