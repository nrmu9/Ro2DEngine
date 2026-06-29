--!optimize 2
--!native
-- Ro2D :: UI
-- Persistent overlay layer rendered above the world. Unlike the world buffers it is
-- not auto-cleared each frame; it tracks dirty sub-rectangles so Flush only uploads
-- the pixels that actually changed since the last frame.

local AssetService = game:GetService("AssetService")

local floor, max, min = math.floor, math.max, math.min
local writeu8, readu8 = buffer.writeu8, buffer.readu8
local writeu32 = buffer.writeu32
local bcreate, bfill, bcopy = buffer.create, buffer.fill, buffer.copy
local Vector2_new = Vector2.new

local CHUNK_SIZE = 1024

local UI = {
	LayerFrame = nil,
	Chunks = {},     -- [y][x] -> chunk
	ChunkList = {},  -- flat array
	Width = 0,
	Height = 0,
	IsReady = false,
	CHUNK_SIZE = CHUNK_SIZE,
}

local UploadBufferPool = {}

local function markFull(chunk)
	chunk.MinX = 0; chunk.MaxX = chunk.Width - 1
	chunk.MinY = 0; chunk.MaxY = chunk.Height - 1
end

local function resetDirty(chunk)
	chunk.MinX = chunk.Width; chunk.MaxX = -1
	chunk.MinY = chunk.Height; chunk.MaxY = -1
end

function UI.Init(parentLayer: Frame, screenW: number, screenH: number, renderScale: number)
	UI.IsReady = false
	if UI.LayerFrame then UI.LayerFrame:Destroy() end

	UI.Width = screenW
	UI.Height = screenH
	table.clear(UI.Chunks)
	table.clear(UI.ChunkList)

	local layer = Instance.new("Frame")
	layer.Name = "SoftwareUIBuffer"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 100
	layer.Parent = parentLayer
	UI.LayerFrame = layer

	local chunksX = math.ceil(screenW / CHUNK_SIZE)
	local chunksY = math.ceil(screenH / CHUNK_SIZE)
	local invScale = 1 / renderScale

	for y = 0, chunksY - 1 do
		local row = {}
		UI.Chunks[y] = row
		local offsetY = y * CHUNK_SIZE
		local chunkH = min(CHUNK_SIZE, screenH - offsetY)

		for x = 0, chunksX - 1 do
			local offsetX = x * CHUNK_SIZE
			local chunkW = min(CHUNK_SIZE, screenW - offsetX)

			local frame = Instance.new("ImageLabel")
			frame.Name = string.format("UIChunk_%d_%d", x, y)
			frame.BackgroundTransparency = 1
			frame.BorderSizePixel = 0
			frame.Position = UDim2.fromOffset(offsetX * invScale, offsetY * invScale)
			frame.Size = UDim2.fromOffset(chunkW * invScale, chunkH * invScale)
			frame.ResampleMode = Enum.ResamplerMode.Pixelated
			frame.Parent = layer

			local image = AssetService:CreateEditableImage({ Size = Vector2_new(chunkW, chunkH) })
			frame.ImageContent = Content.fromObject(image)

			local byteSize = chunkW * chunkH * 4
			local buf = bcreate(byteSize) -- zero-initialized

			local chunk = {
				Image = image,
				Buffer = buf,
				Width = chunkW,
				Height = chunkH,
				ByteSize = byteSize,
				SizeVec = Vector2_new(chunkW, chunkH),
				MinX = chunkW, MaxX = -1, MinY = chunkH, MaxY = -1,
			}
			row[x] = chunk
			table.insert(UI.ChunkList, chunk)
		end
	end

	UI.IsReady = true
end

function UI.Clear()
	if not UI.IsReady then return end
	for i = 1, #UI.ChunkList do
		local chunk = UI.ChunkList[i]
		bfill(chunk.Buffer, 0, 0, chunk.ByteSize)
		markFull(chunk)
	end
end

function UI.DrawFrame(screenX: number, screenY: number, w: number, h: number, r: number, g: number, b: number, a: number?)
	if not UI.IsReady then return end
	a = a or 255
	if a == 0 or w <= 0 or h <= 0 then return end

	local startX = floor(screenX)
	local startY = floor(screenY)
	local endX = startX + w - 1
	local endY = startY + h - 1

	if startX >= UI.Width or startY >= UI.Height or endX < 0 or endY < 0 then return end

	if startX < 0 then startX = 0 end
	if startY < 0 then startY = 0 end
	if endX >= UI.Width then endX = UI.Width - 1 end
	if endY >= UI.Height then endY = UI.Height - 1 end

	local opaque = a == 255
	local packed = r + g * 256 + b * 65536 + 255 * 16777216
	local alphaRatio = a / 255
	local invAlpha = 1 - alphaRatio

	local startChunkX = startX // CHUNK_SIZE
	local endChunkX = endX // CHUNK_SIZE
	local startChunkY = startY // CHUNK_SIZE
	local endChunkY = endY // CHUNK_SIZE

	for cy = startChunkY, endChunkY do
		local chunkRowTbl = UI.Chunks[cy]
		if chunkRowTbl then
			local chunkBaseY = cy * CHUNK_SIZE
			for cx = startChunkX, endChunkX do
				local chunk = chunkRowTbl[cx]
				if chunk then
					local chunkBaseX = cx * CHUNK_SIZE
					local lsx = max(startX, chunkBaseX) - chunkBaseX
					local lex = min(endX, chunkBaseX + chunk.Width - 1) - chunkBaseX
					local lsy = max(startY, chunkBaseY) - chunkBaseY
					local ley = min(endY, chunkBaseY + chunk.Height - 1) - chunkBaseY

					local buf = chunk.Buffer
					local cw = chunk.Width

					for py = lsy, ley do
						local rowBase = py * cw
						if opaque then
							for px = lsx, lex do
								writeu32(buf, (rowBase + px) * 4, packed)
							end
						else
							for px = lsx, lex do
								local index = (rowBase + px) * 4
								local bgA = readu8(buf, index + 3)
								if bgA == 0 then
									writeu8(buf, index, r)
									writeu8(buf, index + 1, g)
									writeu8(buf, index + 2, b)
									writeu8(buf, index + 3, a)
								else
									writeu8(buf, index, floor(r * alphaRatio + readu8(buf, index) * invAlpha))
									writeu8(buf, index + 1, floor(g * alphaRatio + readu8(buf, index + 1) * invAlpha))
									writeu8(buf, index + 2, floor(b * alphaRatio + readu8(buf, index + 2) * invAlpha))
									writeu8(buf, index + 3, max(bgA, a))
								end
							end
						end
					end

					-- Expand the chunk's dirty rectangle.
					if lsx < chunk.MinX then chunk.MinX = lsx end
					if lex > chunk.MaxX then chunk.MaxX = lex end
					if lsy < chunk.MinY then chunk.MinY = lsy end
					if ley > chunk.MaxY then chunk.MaxY = ley end
				end
			end
		end
	end
end

function UI.Flush()
	if not UI.IsReady then return end

	for i = 1, #UI.ChunkList do
		local chunk = UI.ChunkList[i]
		if chunk.MinX <= chunk.MaxX then
			local cw = chunk.Width
			local rectW = chunk.MaxX - chunk.MinX + 1
			local rectH = chunk.MaxY - chunk.MinY + 1
			local buf = chunk.Buffer

			if rectW == cw and rectH == chunk.Height then
				chunk.Image:WritePixelsBuffer(Vector2.zero, chunk.SizeVec, buf)
			else
				local requiredBytes = rectW * rectH * 4
				local tempBuf = UploadBufferPool[requiredBytes]
				if not tempBuf then
					tempBuf = bcreate(requiredBytes)
					UploadBufferPool[requiredBytes] = tempBuf
				end

				local rowBytes = rectW * 4
				for row = 0, rectH - 1 do
					bcopy(tempBuf, row * rowBytes, buf, ((chunk.MinY + row) * cw + chunk.MinX) * 4, rowBytes)
				end
				chunk.Image:WritePixelsBuffer(Vector2_new(chunk.MinX, chunk.MinY), Vector2_new(rectW, rectH), tempBuf)
			end

			resetDirty(chunk)
		end
	end
end

return UI
