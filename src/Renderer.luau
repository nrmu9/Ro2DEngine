--!optimize 2
--!native
-- Ro2D :: Renderer
-- Chunked software rasterizer that maps contiguous RGBA buffers onto EditableImages.
-- Uses dirty-region tracking + a persistent background buffer so only changed pixels
-- are ever pushed to the GPU, and old sprite positions are auto-erased to the background.

local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local AssetService = game:GetService("AssetService")

local Input = require(script.Parent:WaitForChild("Input"))
local UI = require(script.Parent:WaitForChild("UI"))

-- Localize hot builtins (fastcall-friendly).
local writeu32, readu32 = buffer.writeu32, buffer.readu32
local bcopy, bcreate = buffer.copy, buffer.create
local floor, sqrt, min, max, clamp = math.floor, math.sqrt, math.min, math.max, math.clamp
local Vector2_new = Vector2.new
local V2_ZERO = Vector2.zero

local CHUNK_SIZE = 1024
local ALPHA_MASK = 0xFFFFFF -- value > this  <=>  alpha byte > 0 (little-endian RGBA)

type Chunk = {
	Image: EditableImage,
	Buffer: buffer,
	BgBuffer: buffer,
	Width: number, Height: number,
	SizeVec: Vector2,
	MinX: number, MaxX: number, MinY: number, MaxY: number,
	PrevMinX: number, PrevMaxX: number, PrevMinY: number, PrevMaxY: number,
}

local Renderer = {
	System = {},
	Draw = {},
	Camera = { X = 0, Y = 0 },
	Grid = {
		ChunksX = 0, ChunksY = 0,
		Scale = 1,
		DisplayScale = 1, -- canvas (screen) pixels per one render/buffer pixel
		OffsetX = 0, OffsetY = 0, -- letterbox offset of the rendered image within the canvas
		Width = 0, Height = 0, -- render resolution in pixels (cached)
		AntiAliasing = false,
		IsReady = false,
	},
	Resolution = Vector2_new(0, 0),
}

local Chunks = {}        -- [y][x] -> Chunk  (spatial lookup)
local ChunkList = {}     -- flat array of Chunk (order-independent iteration)
local ChunkUIElements = {}
local CanvasFrame: Frame? = nil
local FixedResolution: Vector2? = nil -- when set, render at exactly this size (letterboxed)
local UploadBufferPool = {}
local DeveloperBackgroundCode = nil

-- =========================================================================
-- INTERNAL HELPERS
-- =========================================================================

-- Fills `count` consecutive u32 (pixel) values with `packed`, starting at
-- byte offset `start`, using exponential doubling memcpys instead of a
-- per-element loop. Fills ~N bytes in log2(N) native copies.
local function fillU32(buf: buffer, start: number, count: number, packed: number)
	if count <= 0 then return end
	writeu32(buf, start, packed)
	local filled = 1
	while filled < count do
		local n = min(filled, count - filled)
		bcopy(buf, start + filled * 4, buf, start, n * 4)
		filled += n
	end
end

local function clearMemory()
	for i = 1, #ChunkUIElements do
		ChunkUIElements[i]:Destroy()
	end
	table.clear(Chunks)
	table.clear(ChunkList)
	table.clear(ChunkUIElements)
	Renderer.Grid.Width = 0
	Renderer.Grid.Height = 0
end

local function rebuildGrid()
	if not CanvasFrame then return end
	clearMemory()
	Renderer.Grid.IsReady = false

	local canvasW, canvasH = Renderer.Resolution.X, Renderer.Resolution.Y
	if canvasW <= 0 or canvasH <= 0 then return end

	local targetWidth, targetHeight, displayScale, baseOffsetX, baseOffsetY
	if FixedResolution then
		-- Fixed internal resolution: render exactly this many pixels, then fit into
		-- the canvas preserving aspect (letterbox). RenderScale is ignored here.
		targetWidth = floor(FixedResolution.X)
		targetHeight = floor(FixedResolution.Y)
		if targetWidth <= 0 or targetHeight <= 0 then return end
		displayScale = min(canvasW / targetWidth, canvasH / targetHeight)
		baseOffsetX = floor((canvasW - targetWidth * displayScale) * 0.5)
		baseOffsetY = floor((canvasH - targetHeight * displayScale) * 0.5)
	else
		-- Scale mode: render at canvas size * RenderScale and fill the canvas exactly.
		local scale = Renderer.Grid.Scale
		targetWidth = floor(canvasW * scale)
		targetHeight = floor(canvasH * scale)
		if targetWidth <= 0 or targetHeight <= 0 then return end
		displayScale = 1 / scale
		baseOffsetX, baseOffsetY = 0, 0
	end

	Renderer.Grid.Width = targetWidth
	Renderer.Grid.Height = targetHeight
	Renderer.Grid.DisplayScale = displayScale
	Renderer.Grid.OffsetX = baseOffsetX
	Renderer.Grid.OffsetY = baseOffsetY

	local chunksX = math.ceil(targetWidth / CHUNK_SIZE)
	local chunksY = math.ceil(targetHeight / CHUNK_SIZE)
	Renderer.Grid.ChunksX, Renderer.Grid.ChunksY = chunksX, chunksY

	local filterMode = Renderer.Grid.AntiAliasing and Enum.ResamplerMode.Default or Enum.ResamplerMode.Pixelated

	for y = 0, chunksY - 1 do
		local row = {}
		Chunks[y] = row
		local offsetY = y * CHUNK_SIZE
		local chunkH = min(CHUNK_SIZE, targetHeight - offsetY)

		for x = 0, chunksX - 1 do
			local offsetX = x * CHUNK_SIZE
			local chunkW = min(CHUNK_SIZE, targetWidth - offsetX)

			local frame = Instance.new("ImageLabel")
			frame.Name = string.format("Chunk_%d_%d", x, y)
			frame.BackgroundTransparency = 1
			frame.BorderSizePixel = 0
			frame.Position = UDim2.fromOffset(baseOffsetX + offsetX * displayScale, baseOffsetY + offsetY * displayScale)
			frame.Size = UDim2.fromOffset(chunkW * displayScale, chunkH * displayScale)
			frame.ResampleMode = filterMode
			frame.Parent = CanvasFrame
			table.insert(ChunkUIElements, frame)

			local image = AssetService:CreateEditableImage({ Size = Vector2_new(chunkW, chunkH) })
			frame.ImageContent = Content.fromObject(image)

			local bytes = chunkW * chunkH * 4
			local chunk: Chunk = {
				Image = image,
				Buffer = bcreate(bytes),
				BgBuffer = bcreate(bytes),
				Width = chunkW, Height = chunkH,
				SizeVec = Vector2_new(chunkW, chunkH),
				MinX = chunkW, MaxX = -1, MinY = chunkH, MaxY = -1,
				PrevMinX = chunkW, PrevMaxX = -1, PrevMinY = chunkH, PrevMaxY = -1,
			}
			row[x] = chunk
			table.insert(ChunkList, chunk)
		end
	end

	UI.Init(CanvasFrame, targetWidth, targetHeight, displayScale, baseOffsetX, baseOffsetY)
	Renderer.Grid.IsReady = true
end

-- =========================================================================
-- SYSTEM NAMESPACE
-- =========================================================================
function Renderer.System.Init(canvasFrame: Frame, config: any)
	assert(typeof(canvasFrame) == "Instance" and canvasFrame:IsA("GuiObject"),
		"[Ro2D] System.Init expects a GuiObject (e.g. a Frame) as the canvas.")

	config = config or {}
	Renderer.Grid.Scale = clamp(config.RenderScale or 1, 0.1, 1)
	Renderer.Grid.AntiAliasing = config.AntiAliasing == true

	-- Optional fixed internal resolution: render at exactly this size regardless of
	-- screen, letterboxed to fit. Keeps the playfield + perf consistent across monitors.
	local res = config.Resolution
	FixedResolution = if typeof(res) == "Vector2" and res.X >= 1 and res.Y >= 1 then res else nil

	if config.Isolate2D then
		pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false) end)
		local camera = workspace.CurrentCamera
		if camera then camera.CameraType = Enum.CameraType.Scriptable end

		local player = Players.LocalPlayer
		-- Lock out Roblox controls irrelevant to a 2D canvas game: no shift-lock,
		-- and no user switching of camera/movement mode (we own the camera + input).
		pcall(function()
			player.DevEnableMouseLock = false
			player.DevComputerCameraMovementMode = Enum.DevComputerCameraMovementMode.Classic
			player.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
			player.DevTouchMovementMode = Enum.DevTouchMovementMode.Scriptable
		end)
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
		local size = (CanvasFrame :: Frame).AbsoluteSize
		if size.X > 0 and size.Y > 0 then
			Renderer.Resolution = size
			clearMemory()
			Renderer.Grid.IsReady = false
			if resizeThread then task.cancel(resizeThread) end
			resizeThread = task.delay(0.05, rebuildGrid)
		end
	end

	canvasFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncResolution)
	syncResolution()
end

function Renderer.System.ScreenToCanvas(screenX: number, screenY: number): (number, number)
	local g = Renderer.Grid
	local inv = 1 / g.DisplayScale
	return floor((screenX - g.OffsetX) * inv), floor((screenY - g.OffsetY) * inv)
end

function Renderer.System.SetBackground(callback)
	DeveloperBackgroundCode = callback
	if not callback or not Renderer.Grid.IsReady then return end

	callback()

	for i = 1, #ChunkList do
		local chunk = ChunkList[i]
		local len = chunk.Width * chunk.Height * 4
		bcopy(chunk.BgBuffer, 0, chunk.Buffer, 0, len)
		chunk.Image:WritePixelsBuffer(V2_ZERO, chunk.SizeVec, chunk.Buffer)

		chunk.MinX = chunk.Width; chunk.MaxX = -1
		chunk.MinY = chunk.Height; chunk.MaxY = -1
		chunk.PrevMinX = chunk.Width; chunk.PrevMaxX = -1
		chunk.PrevMinY = chunk.Height; chunk.PrevMaxY = -1
	end
end

-- =========================================================================
-- DRAW NAMESPACE
-- =========================================================================
local Draw = Renderer.Draw
local Grid = Renderer.Grid
local Camera = Renderer.Camera

function Draw.Pixel(worldX: number, worldY: number, r: number, g: number, b: number, a: number?)
	if not Grid.IsReady then return end

	local x = floor(worldX - Camera.X)
	local y = floor(worldY - Camera.Y)
	if x < 0 or x >= Grid.Width or y < 0 or y >= Grid.Height then return end

	local chunkRow = Chunks[y // CHUNK_SIZE]
	if not chunkRow then return end
	local chunk = chunkRow[x // CHUNK_SIZE]
	if not chunk then return end

	local localX = x % CHUNK_SIZE
	local localY = y % CHUNK_SIZE
	if localX >= chunk.Width or localY >= chunk.Height then return end

	-- Pack RGBA into one u32 (little-endian) and write in a single op.
	local packed = r + g * 256 + b * 65536 + (a or 255) * 16777216
	writeu32(chunk.Buffer, (localY * chunk.Width + localX) * 4, packed)

	if localX < chunk.MinX then chunk.MinX = localX end
	if localX > chunk.MaxX then chunk.MaxX = localX end
	if localY < chunk.MinY then chunk.MinY = localY end
	if localY > chunk.MaxY then chunk.MaxY = localY end
end

function Draw.Sprite(worldX: number, worldY: number, sprite: any, flipX: boolean?, flipY: boolean?)
	if not Grid.IsReady or sprite.IsEmpty then return end

	local startX = floor(worldX - Camera.X)
	local startY = floor(worldY - Camera.Y)
	local w, h, buf, bounds = sprite.Width, sprite.Height, sprite.Buffer, sprite.RowBounds
	local screenW, screenH = Grid.Width, Grid.Height

	-- Fast path: sprites whose rows have no interior transparency (and aren't
	-- mirrored horizontally) can be blitted one whole row-span at a time with a
	-- native buffer.copy instead of pixel-by-pixel. Huge win for dense, small,
	-- opaque sprites (e.g. bullets). flipY is fine — it only reorders rows.
	local solidFast = sprite.SolidRows and not flipX

	for y = 0, h - 1 do
		local readY = if flipY then (h - 1 - y) else y
		local row = bounds[readY]

		if row.MinX ~= -1 then
			local drawY = startY + y
			if drawY >= 0 and drawY < screenH then
				local chunkRow = Chunks[drawY // CHUNK_SIZE]
				if chunkRow then
					local localY = drawY % CHUNK_SIZE
					local srcRowOffset = readY * w * 4

					if solidFast then
						-- Contiguous opaque span on screen, clipped to canvas width.
						local spanStart = startX + row.MinX
						local spanEnd = startX + row.MaxX
						if spanStart < 0 then spanStart = 0 end
						if spanEnd >= screenW then spanEnd = screenW - 1 end

						local sx = spanStart
						while sx <= spanEnd do
							local chunk = chunkRow[sx // CHUNK_SIZE]
							local localX = sx % CHUNK_SIZE
							if chunk then
								local maxLocal = localX + (spanEnd - sx)
								if maxLocal > chunk.Width - 1 then maxLocal = chunk.Width - 1 end
								local copyCount = maxLocal - localX + 1

								-- src x for screen x `sx` is (sx - startX); the span lives
								-- inside [row.MinX, row.MaxX], so reads stay in bounds.
								bcopy(
									chunk.Buffer, (localY * chunk.Width + localX) * 4,
									buf, srcRowOffset + (sx - startX) * 4,
									copyCount * 4
								)

								if localX < chunk.MinX then chunk.MinX = localX end
								if maxLocal > chunk.MaxX then chunk.MaxX = maxLocal end
								if localY < chunk.MinY then chunk.MinY = localY end
								if localY > chunk.MaxY then chunk.MaxY = localY end

								sx += copyCount
							else
								sx += CHUNK_SIZE - localX -- skip to next chunk boundary
							end
						end
					else
						-- Per-pixel path: handles flipX and interior transparency.
						local destMinX = if flipX then (w - 1 - row.MaxX) else row.MinX
						local destMaxX = if flipX then (w - 1 - row.MinX) else row.MaxX

						local startDrawX = startX + destMinX
						local chunkX = startDrawX // CHUNK_SIZE
						local localX = startDrawX % CHUNK_SIZE
						local chunk = chunkRow[chunkX]

						for destX = destMinX, destMaxX do
							if startDrawX >= screenW then break end
							if chunk and startDrawX >= 0 then
								local readX = if flipX then (w - 1 - destX) else destX
								local src = readu32(buf, srcRowOffset + readX * 4)
								if src > ALPHA_MASK then
									writeu32(chunk.Buffer, (localY * chunk.Width + localX) * 4, src)
									if localX < chunk.MinX then chunk.MinX = localX end
									if localX > chunk.MaxX then chunk.MaxX = localX end
									if localY < chunk.MinY then chunk.MinY = localY end
									if localY > chunk.MaxY then chunk.MaxY = localY end
								end
							end
							startDrawX += 1
							localX += 1
							if localX >= CHUNK_SIZE then
								localX = 0
								chunkX += 1
								chunk = chunkRow[chunkX]
							end
						end
					end
				end
			end
		end
	end
end

-- Filled, world-space rectangle. Fills contiguous spans with a single packed
-- color using doubling memcpys, walking across chunk boundaries.
function Draw.Rect(worldX: number, worldY: number, w: number, h: number, r: number, g: number, b: number, a: number?)
	if not Grid.IsReady or w <= 0 or h <= 0 then return end

	local screenW, screenH = Grid.Width, Grid.Height
	local x0 = floor(worldX - Camera.X)
	local y0 = floor(worldY - Camera.Y)
	local x1 = x0 + w - 1
	local y1 = y0 + h - 1
	if x1 < 0 or y1 < 0 or x0 >= screenW or y0 >= screenH then return end

	if x0 < 0 then x0 = 0 end
	if y0 < 0 then y0 = 0 end
	if x1 >= screenW then x1 = screenW - 1 end
	if y1 >= screenH then y1 = screenH - 1 end

	local packed = r + g * 256 + b * 65536 + (a or 255) * 16777216

	for y = y0, y1 do
		local chunkRow = Chunks[y // CHUNK_SIZE]
		if chunkRow then
			local localY = y % CHUNK_SIZE
			local px = x0
			while px <= x1 do
				local chunk = chunkRow[px // CHUNK_SIZE]
				local localX = px % CHUNK_SIZE
				if chunk then
					local spanEndLocal = min(chunk.Width - 1, localX + (x1 - px))
					local count = spanEndLocal - localX + 1
					fillU32(chunk.Buffer, (localY * chunk.Width + localX) * 4, count, packed)

					if localX < chunk.MinX then chunk.MinX = localX end
					if spanEndLocal > chunk.MaxX then chunk.MaxX = spanEndLocal end
					if localY < chunk.MinY then chunk.MinY = localY end
					if localY > chunk.MaxY then chunk.MaxY = localY end

					px += count
				else
					-- skip to next chunk boundary
					px += (CHUNK_SIZE - localX)
				end
			end
		end
	end
end

function Draw.LineSDF(worldX0: number, worldY0: number, worldX1: number, worldY1: number, thickness: number, r: number, g: number, b: number)
	if not Grid.IsReady then return end
	local pixel = Draw.Pixel
	local camX, camY = Camera.X, Camera.Y

	local x0 = worldX0 - camX
	local y0 = worldY0 - camY
	local x1 = worldX1 - camX
	local y1 = worldY1 - camY

	local halfThick = thickness * 0.5
	local dx, dy = x1 - x0, y1 - y0
	local lenSq = dx * dx + dy * dy
	local invLenSq = if lenSq > 0 then 1 / lenSq else 0

	local minX = floor(min(x0, x1) - halfThick - 1)
	local maxX = floor(max(x0, x1) + halfThick + 1)
	local minY = floor(min(y0, y1) - halfThick - 1)
	local maxY = floor(max(y0, y1) + halfThick + 1)
	local edge = halfThick + 1

	for py = minY, maxY do
		for px = minX, maxX do
			local t = clamp(((px - x0) * dx + (py - y0) * dy) * invLenSq, 0, 1)
			local ex = px - (x0 + t * dx)
			local ey = py - (y0 + t * dy)
			local dist = sqrt(ex * ex + ey * ey)

			if dist <= edge then
				local a = 255
				if dist > halfThick then a = floor(255 * (1 - (dist - halfThick))) end
				if a > 5 then pixel(px + camX, py + camY, r, g, b, a) end
			end
		end
	end
end

-- True anti-aliased circle via signed distance coverage.
function Draw.CircleSDF(worldX: number, worldY: number, radius: number, r: number, g: number, b: number, a: number?)
	if not Grid.IsReady or radius <= 0 then return end
	a = a or 255
	local pixel = Draw.Pixel

	local startX = floor(worldX - radius - 1)
	local startY = floor(worldY - radius - 1)
	local endX = floor(worldX + radius + 1)
	local endY = floor(worldY + radius + 1)

	for py = startY, endY do
		local dy = py - worldY
		local dySq = dy * dy
		for px = startX, endX do
			local dx = px - worldX
			local dist = sqrt(dx * dx + dySq)
			local coverage = radius - dist + 0.5 -- 1 inside, 0 outside, fractional on the edge
			if coverage > 0 then
				local pa = if coverage >= 1 then a else floor(a * coverage)
				if pa > 0 then pixel(px, py, r, g, b, pa) end
			end
		end
	end
end

function Draw.Clear(r: number, g: number, b: number, a: number?)
	if not Grid.IsReady then return end
	local packed = r + g * 256 + b * 65536 + (a or 255) * 16777216

	for i = 1, #ChunkList do
		local chunk = ChunkList[i]
		fillU32(chunk.Buffer, 0, chunk.Width * chunk.Height, packed)
		chunk.MinX = 0; chunk.MaxX = chunk.Width - 1
		chunk.MinY = 0; chunk.MaxY = chunk.Height - 1
	end
end

-- =========================================================================
-- GPU AUTO-RENDER LOOP
-- =========================================================================
local wasReady = false
RunService:BindToRenderStep("Ro2DEngineFlush", Enum.RenderPriority.Last.Value, function()
	if not Grid.IsReady then
		wasReady = false
		return
	end

	if not wasReady then
		wasReady = true
		if DeveloperBackgroundCode then Renderer.System.SetBackground(DeveloperBackgroundCode) end
	end

	for i = 1, #ChunkList do
		local chunk = ChunkList[i]
		local cw = chunk.Width
		local hasCurrent = chunk.MinX <= chunk.MaxX
		local hasPrev = chunk.PrevMinX <= chunk.PrevMaxX

		if hasCurrent or hasPrev then
			local uMinX, uMaxX = cw, -1
			local uMinY, uMaxY = chunk.Height, -1

			if hasCurrent then
				if chunk.MinX < uMinX then uMinX = chunk.MinX end
				if chunk.MaxX > uMaxX then uMaxX = chunk.MaxX end
				if chunk.MinY < uMinY then uMinY = chunk.MinY end
				if chunk.MaxY > uMaxY then uMaxY = chunk.MaxY end
			end
			if hasPrev then
				if chunk.PrevMinX < uMinX then uMinX = chunk.PrevMinX end
				if chunk.PrevMaxX > uMaxX then uMaxX = chunk.PrevMaxX end
				if chunk.PrevMinY < uMinY then uMinY = chunk.PrevMinY end
				if chunk.PrevMaxY > uMaxY then uMaxY = chunk.PrevMaxY end
			end

			local rectW = uMaxX - uMinX + 1
			local rectH = uMaxY - uMinY + 1
			local buf = chunk.Buffer

			if rectW == cw and rectH == chunk.Height then
				chunk.Image:WritePixelsBuffer(V2_ZERO, chunk.SizeVec, buf)
			else
				local requiredBytes = rectW * rectH * 4
				local tempBuf = UploadBufferPool[requiredBytes]
				if not tempBuf then
					tempBuf = bcreate(requiredBytes)
					UploadBufferPool[requiredBytes] = tempBuf
				end

				local rowBytes = rectW * 4
				for row = 0, rectH - 1 do
					bcopy(tempBuf, row * rowBytes, buf, ((uMinY + row) * cw + uMinX) * 4, rowBytes)
				end
				chunk.Image:WritePixelsBuffer(Vector2_new(uMinX, uMinY), Vector2_new(rectW, rectH), tempBuf)
			end

			-- Restore the background into the region we just drew so the next frame
			-- starts clean (auto-erase). BgBuffer is zero by default, or the snapshot
			-- captured by System.SetBackground.
			if hasCurrent then
				local bg = chunk.BgBuffer
				local copyBytes = (chunk.MaxX - chunk.MinX + 1) * 4
				for row = chunk.MinY, chunk.MaxY do
					local offset = (row * cw + chunk.MinX) * 4
					bcopy(buf, offset, bg, offset, copyBytes)
				end
			end

			chunk.PrevMinX = chunk.MinX; chunk.PrevMaxX = chunk.MaxX
			chunk.PrevMinY = chunk.MinY; chunk.PrevMaxY = chunk.MaxY
			chunk.MinX = cw; chunk.MaxX = -1
			chunk.MinY = chunk.Height; chunk.MaxY = -1
		end
	end

	Input.Flush()
	UI.Flush()
end)

return Renderer
