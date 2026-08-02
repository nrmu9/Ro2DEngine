--!optimize 2
--!native

local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local AssetService = game:GetService("AssetService")
local ContextActionService = game:GetService("ContextActionService")

local Input = require(script.Parent:WaitForChild("Input"))
local UI = require(script.Parent:WaitForChild("UI"))

local writeu32, readu32 = buffer.writeu32, buffer.readu32
local bcopy, bcreate = buffer.copy, buffer.create
local floor, sqrt, min, max, clamp = math.floor, math.sqrt, math.min, math.max, math.clamp
local cos, sin, abs = math.cos, math.sin, math.abs
local ceil = math.ceil
local strbyte = string.byte
local Vector2_new = Vector2.new
local V2_ZERO = Vector2.zero

local CHUNK_SIZE = 1024
local ALPHA_MASK = 0xFFFFFF
local txtColS = table.create(512, 0)
local txtColN = table.create(512, 0)
local txtColW = table.create(2048, 0)

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
		DisplayScale = 1,
		OffsetX = 0, OffsetY = 0,
		Width = 0, Height = 0,
		AntiAliasing = false,
		IsReady = false,
	},
	Resolution = Vector2_new(0, 0),
}

local Chunks = {}
local ChunkList = {}
local ChunkUIElements = {}
local CanvasFrame: Frame? = nil
local TintFrame: Frame? = nil
local FixedResolution: Vector2? = nil
local FillMode = false
local SkipRestore = false
local UploadBufferPool = {}
local DeveloperBackgroundCode = nil


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
	if FixedResolution and FillMode then
		targetHeight = floor(FixedResolution.Y)
		if targetHeight <= 0 then return end
		displayScale = canvasH / targetHeight
		targetWidth = max(1, floor(canvasW / displayScale))
		baseOffsetX, baseOffsetY = 0, 0
	elseif FixedResolution then
		targetWidth = floor(FixedResolution.X)
		targetHeight = floor(FixedResolution.Y)
		if targetWidth <= 0 or targetHeight <= 0 then return end
		displayScale = min(canvasW / targetWidth, canvasH / targetHeight)
		baseOffsetX = floor((canvasW - targetWidth * displayScale) * 0.5)
		baseOffsetY = floor((canvasH - targetHeight * displayScale) * 0.5)
	else
		targetWidth = floor(canvasW)
		targetHeight = floor(canvasH)
		displayScale = 1
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
	Renderer.ResetClip()
end

function Renderer.System.Init(canvasFrame: Frame, config: any)
	assert(typeof(canvasFrame) == "Instance" and canvasFrame:IsA("GuiObject"),
		"[Ro2D] System.Init expects a GuiObject (e.g. a Frame) as the canvas.")

	config = config or {}
	Renderer.Grid.AntiAliasing = config.AntiAliasing == true

	local res = config.Resolution
	FixedResolution = if typeof(res) == "Vector2" and res.X >= 1 and res.Y >= 1 then res else nil
	FillMode = config.Fill == true

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

function Renderer.System.SetResolution(res: Vector2?, fill: boolean?)
	local fixed = if typeof(res) == "Vector2" and res.X >= 1 and res.Y >= 1 then res else nil
	local newFill = if fill == nil then FillMode else fill == true
	if fixed == FixedResolution and newFill == FillMode then return end
	if fixed and FixedResolution and fixed.X == FixedResolution.X and fixed.Y == FixedResolution.Y and newFill == FillMode then return end
	FixedResolution = fixed
	FillMode = newFill
	if CanvasFrame then
		Renderer.Grid.IsReady = false
		rebuildGrid()
	end
end

function Renderer.System.SetTint(r: number, g: number, b: number, alpha: number)
	if not CanvasFrame then return end
	if not TintFrame then
		local f = Instance.new("Frame")
		f.Name = "Ro2DTint"
		f.Size = UDim2.fromScale(1, 1)
		f.Position = UDim2.fromScale(0, 0)
		f.BorderSizePixel = 0
		f.ZIndex = 5000
		f.Active = false
		f.Interactable = false
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BackgroundTransparency = 1
		f.Parent = CanvasFrame
		TintFrame = f
	end
	TintFrame.BackgroundColor3 = Color3.fromRGB(r, g, b)
	TintFrame.BackgroundTransparency = 1 - clamp(alpha, 0, 255) / 255
end

function Renderer.System.ScreenToCanvas(screenX: number, screenY: number): (number, number)
	local g = Renderer.Grid
	local inv = 1 / g.DisplayScale
	return floor((screenX - g.OffsetX) * inv), floor((screenY - g.OffsetY) * inv)
end

function Renderer.System.SetImmediateMode(on: boolean)
	SkipRestore = on and true or false
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

local Draw = Renderer.Draw
local Grid = Renderer.Grid
local Camera = Renderer.Camera

local EMPTY_OPTS = table.freeze({})

-- Scissor bounds in screen space, inclusive. Every primitive already clamped to
-- the surface, so clipping is that same clamp against tighter bounds -- there is
-- no cost when no clip is set, because the default IS the surface.
local clipX0, clipY0, clipX1, clipY1 = 0, 0, -1, -1
local function resetClip()
	clipX0, clipY0 = 0, 0
	clipX1, clipY1 = Grid.Width - 1, Grid.Height - 1
end
Renderer.ResetClip = resetClip

-- Restricts subsequent drawing to a rectangle, in the same world space the draw
-- calls use. A zero or negative size clips everything away until the clip is
-- cleared. Clears itself at the end of every frame, so a scene that errors
-- part-way through cannot leave the next one clipped.
function Draw.SetClip(worldX: number, worldY: number, w: number, h: number)
	if not Grid.IsReady then return end
	if w <= 0 or h <= 0 then
		clipX0, clipY0, clipX1, clipY1 = 0, 0, -1, -1
		return
	end
	local x0 = floor(worldX - Camera.X)
	local y0 = floor(worldY - Camera.Y)
	local x1 = x0 + floor(w) - 1
	local y1 = y0 + floor(h) - 1
	if x0 < 0 then x0 = 0 end
	if y0 < 0 then y0 = 0 end
	if x1 > Grid.Width - 1 then x1 = Grid.Width - 1 end
	if y1 > Grid.Height - 1 then y1 = Grid.Height - 1 end
	clipX0, clipY0, clipX1, clipY1 = x0, y0, x1, y1
end

function Draw.ClearClip()
	resetClip()
end

function Draw.Pixel(worldX: number, worldY: number, r: number, g: number, b: number, a: number?)
	if not Grid.IsReady then return end

	local x = floor(worldX - Camera.X)
	local y = floor(worldY - Camera.Y)
	if x < clipX0 or x > clipX1 or y < clipY0 or y > clipY1 then return end

	local chunkRow = Chunks[y // CHUNK_SIZE]
	if not chunkRow then return end
	local chunk = chunkRow[x // CHUNK_SIZE]
	if not chunk then return end

	local localX = x % CHUNK_SIZE
	local localY = y % CHUNK_SIZE
	if localX >= chunk.Width or localY >= chunk.Height then return end

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
	local solidFast = sprite.SolidRows and not flipX

	for y = 0, h - 1 do
		local readY = if flipY then (h - 1 - y) else y
		local row = bounds[readY]

		if row.MinX ~= -1 then
			local drawY = startY + y
			if drawY >= clipY0 and drawY <= clipY1 then
				local chunkRow = Chunks[drawY // CHUNK_SIZE]
				if chunkRow then
					local localY = drawY % CHUNK_SIZE
					local srcRowOffset = readY * w * 4

					if solidFast then
						local spanStart = startX + row.MinX
						local spanEnd = startX + row.MaxX
						if spanStart < clipX0 then spanStart = clipX0 end
						if spanEnd > clipX1 then spanEnd = clipX1 end

						local sx = spanStart
						while sx <= spanEnd do
							local chunk = chunkRow[sx // CHUNK_SIZE]
							local localX = sx % CHUNK_SIZE
							if chunk then
								local maxLocal = localX + (spanEnd - sx)
								if maxLocal > chunk.Width - 1 then maxLocal = chunk.Width - 1 end
								local copyCount = maxLocal - localX + 1

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
								sx += CHUNK_SIZE - localX
							end
						end
					else
						local destMinX = if flipX then (w - 1 - row.MaxX) else row.MinX
						local destMaxX = if flipX then (w - 1 - row.MinX) else row.MaxX

						local startDrawX = startX + destMinX
						local chunkX = startDrawX // CHUNK_SIZE
						local localX = startDrawX % CHUNK_SIZE
						local chunk = chunkRow[chunkX]

						for destX = destMinX, destMaxX do
							if startDrawX > clipX1 then break end
							if chunk and startDrawX >= clipX0 then
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

function Draw.SpriteEx(worldX: number, worldY: number, sprite: any, opts: any?)
	if not Grid.IsReady or sprite.IsEmpty then return end
	opts = opts or EMPTY_OPTS
	local rot = opts.Rotation or 0
	local scale = opts.Scale or 1
	if scale <= 0 then return end
	local tintR, tintG, tintB = opts.TintR, opts.TintG, opts.TintB
	local tinted = tintR ~= nil
	local alpha = opts.Alpha or 255
	local flipX, flipY = opts.FlipX == true, opts.FlipY == true

	local w, h, buf = sprite.Width, sprite.Height, sprite.Buffer
	local cx = worldX - Camera.X
	local cy = worldY - Camera.Y
	local ca, sa = cos(rot), sin(rot)
	local hw, hh = w * 0.5 * scale, h * 0.5 * scale
	local ex = abs(hw * ca) + abs(hh * sa)
	local ey = abs(hw * sa) + abs(hh * ca)

	local minX, maxX = floor(cx - ex), floor(cx + ex)
	local minY, maxY = floor(cy - ey), floor(cy + ey)
	if maxX < clipX0 or maxY < clipY0 or minX > clipX1 or minY > clipY1 then return end
	if minX < clipX0 then minX = clipX0 end
	if minY < clipY0 then minY = clipY0 end
	if maxX > clipX1 then maxX = clipX1 end
	if maxY > clipY1 then maxY = clipY1 end

	local invScale = 1 / scale
	local halfW, halfH = w * 0.5, h * 0.5

	if rot == 0 then
		for py = minY, maxY do
			local chunkRow = Chunks[py // CHUNK_SIZE]
			if chunkRow then
				local localY = py % CHUNK_SIZE
				local syp = floor((py - cy) * invScale + halfH)
				if flipY then syp = h - 1 - syp end
				if syp >= 0 and syp < h then
					local rowBase = syp * w
					for px = minX, maxX do
						local sxp = floor((px - cx) * invScale + halfW)
						if flipX then sxp = w - 1 - sxp end
						if sxp >= 0 and sxp < w then
							local src = readu32(buf, (rowBase + sxp) * 4)
							if src > ALPHA_MASK then
								local chunk = chunkRow[px // CHUNK_SIZE]
								if chunk then
									local localX = px % CHUNK_SIZE
									if localX < chunk.Width and localY < chunk.Height then
										local sr, sg, sb = src % 256, (src // 256) % 256, (src // 65536) % 256
										local oa = (src // 16777216) % 256
										if tinted then
											sr = (sr * tintR) // 255
											sg = (sg * tintG) // 255
											sb = (sb * tintB) // 255
										end
										if alpha ~= 255 then oa = (oa * alpha) // 255 end
										local off = (localY * chunk.Width + localX) * 4
										if oa >= 255 then
											writeu32(chunk.Buffer, off, sr + sg * 256 + sb * 65536 + 0xFF000000)
										else
											local dst = readu32(chunk.Buffer, off)
											local ia = 255 - oa
											writeu32(chunk.Buffer, off,
												(sr * oa + (dst % 256) * ia) // 255
												+ ((sg * oa + (dst // 256 % 256) * ia) // 255) * 256
												+ ((sb * oa + (dst // 65536 % 256) * ia) // 255) * 65536
												+ 0xFF000000)
										end
										if localX < chunk.MinX then chunk.MinX = localX end
										if localX > chunk.MaxX then chunk.MaxX = localX end
										if localY < chunk.MinY then chunk.MinY = localY end
										if localY > chunk.MaxY then chunk.MaxY = localY end
									end
								end
							end
						end
					end
				end
			end
		end
		return
	end

	for py = minY, maxY do
		local chunkRow = Chunks[py // CHUNK_SIZE]
		if chunkRow then
			local localY = py % CHUNK_SIZE
			local dyc = py - cy
			for px = minX, maxX do
				local dxc = px - cx
				local sxp = floor((dxc * ca + dyc * sa) * invScale + halfW)
				local syp = floor((dyc * ca - dxc * sa) * invScale + halfH)
				if flipX then sxp = w - 1 - sxp end
				if flipY then syp = h - 1 - syp end
				if sxp >= 0 and sxp < w and syp >= 0 and syp < h then
					local src = readu32(buf, (syp * w + sxp) * 4)
					if src > ALPHA_MASK then
						local chunk = chunkRow[px // CHUNK_SIZE]
						if chunk then
							local localX = px % CHUNK_SIZE
							if localX < chunk.Width and localY < chunk.Height then
								local sr, sg, sb = src % 256, (src // 256) % 256, (src // 65536) % 256
								local oa = (src // 16777216) % 256
								if tinted then
									sr = (sr * tintR) // 255
									sg = (sg * tintG) // 255
									sb = (sb * tintB) // 255
								end
								if alpha ~= 255 then oa = (oa * alpha) // 255 end
								local off = (localY * chunk.Width + localX) * 4
								if oa >= 255 then
									writeu32(chunk.Buffer, off, sr + sg * 256 + sb * 65536 + 0xFF000000)
								else
									local dst = readu32(chunk.Buffer, off)
									local ia = 255 - oa
									writeu32(chunk.Buffer, off,
										(sr * oa + (dst % 256) * ia) // 255
										+ ((sg * oa + (dst // 256 % 256) * ia) // 255) * 256
										+ ((sb * oa + (dst // 65536 % 256) * ia) // 255) * 65536
										+ 0xFF000000)
								end
								if localX < chunk.MinX then chunk.MinX = localX end
								if localX > chunk.MaxX then chunk.MaxX = localX end
								if localY < chunk.MinY then chunk.MinY = localY end
								if localY > chunk.MaxY then chunk.MaxY = localY end
							end
						end
					end
				end
			end
		end
	end
end

function Draw.MeasureText(text: string, font: any, scale: number?): number
	local glyphs, space = font.Glyphs, font.SpaceAdvance
	local w = 0
	for i = 1, #text do
		local g = glyphs[strbyte(text, i)]
		w += if g then g.Adv else space
	end
	return w * (scale or 1)
end

function Draw.Text(worldX: number, worldY: number, text: string, font: any, opts: any?)
	if not Grid.IsReady or text == "" then return end
	opts = opts or EMPTY_OPTS
	local scale = opts.Scale or 1
	if scale <= 0 then return end
	local tintR, tintG, tintB = opts.TintR, opts.TintG, opts.TintB
	local tinted = tintR ~= nil
	local alpha = opts.Alpha or 255
	local glyphs, atlas, aw, space = font.Glyphs, font.Buffer, font.Width, font.SpaceAdvance
	local invScale = 1 / scale

	local penX = worldX
	local align = opts.Align
	if align == "center" then
		penX -= Draw.MeasureText(text, font, scale) * 0.5
	elseif align == "right" then
		penX -= Draw.MeasureText(text, font, scale)
	end
	if opts.VAlign == "center" then
		worldY -= (font.CapCenter or 0) * scale
	end

	local sr = tinted and tintR or 255
	local sg = tinted and tintG or 255
	local sb = tinted and tintB or 255
	local areaInv = scale * scale
	for i = 1, #text do
		local g = glyphs[strbyte(text, i)]
		if g then
			local gx, gy = g.X, g.Y
			local gW, gH = g.W, g.H
			local ox = floor(penX + g.OX * scale - Camera.X)
			local oy = floor(worldY + g.OY * scale - Camera.Y)
			local dw, dh = floor(gW * scale), floor(gH * scale)
			local wIdx = 0
			for px = 0, dw - 1 do
				local fx0 = px * invScale
				local fx1 = fx0 + invScale
				if fx1 > gW then fx1 = gW end
				local sxA = floor(fx0)
				local sxB = ceil(fx1) - 1
				txtColS[px] = sxA
				txtColN[px] = sxB - sxA + 1
				local sx = sxA
				while sx <= sxB do
					local lo = sx > fx0 and sx or fx0
					local hi = sx + 1 < fx1 and sx + 1 or fx1
					txtColW[wIdx] = hi - lo
					wIdx += 1
					sx += 1
				end
			end
			for py = 0, dh - 1 do
				local screenY = oy + py
				if screenY >= clipY0 and screenY <= clipY1 then
					local chunkRow = Chunks[screenY // CHUNK_SIZE]
					if chunkRow then
						local localY = screenY % CHUNK_SIZE
						local fy0 = py * invScale
						local fy1 = fy0 + invScale
						if fy1 > gH then fy1 = gH end
						local syA = floor(fy0)
						local syB = ceil(fy1) - 1
						local wCol = 0
						for px = 0, dw - 1 do
							local screenX = ox + px
							local sxA, nS = txtColS[px], txtColN[px]
							if screenX >= clipX0 and screenX <= clipX1 then
								local oa
								if nS == 1 and syA == syB then
									oa = (readu32(atlas, ((gy + syA) * aw + gx + sxA) * 4) // 16777216) % 256
								else
									local acc = 0
									local sy = syA
									while sy <= syB do
										local wy = min(sy + 1, fy1) - (sy > fy0 and sy or fy0)
										if wy > 0 then
											local rowoff = (gy + sy) * aw + gx
											for k = 0, nS - 1 do
												local a = (readu32(atlas, (rowoff + sxA + k) * 4) // 16777216) % 256
												if a > 0 then acc += a * txtColW[wCol + k] * wy end
											end
										end
										sy += 1
									end
									oa = floor(acc * areaInv + 0.5)
									if oa > 255 then oa = 255 end
								end
								if alpha ~= 255 then oa = (oa * alpha) // 255 end
								if oa > 0 then
									local chunk = chunkRow[screenX // CHUNK_SIZE]
									if chunk then
										local localX = screenX % CHUNK_SIZE
										if localX < chunk.Width and localY < chunk.Height then
											local off = (localY * chunk.Width + localX) * 4
											if oa >= 255 then
												writeu32(chunk.Buffer, off, sr + sg * 256 + sb * 65536 + 0xFF000000)
											else
												local dst = readu32(chunk.Buffer, off)
												local ia = 255 - oa
												writeu32(chunk.Buffer, off,
													(sr * oa + (dst % 256) * ia) // 255
													+ ((sg * oa + (dst // 256 % 256) * ia) // 255) * 256
													+ ((sb * oa + (dst // 65536 % 256) * ia) // 255) * 65536
													+ 0xFF000000)
											end
											if localX < chunk.MinX then chunk.MinX = localX end
											if localX > chunk.MaxX then chunk.MaxX = localX end
											if localY < chunk.MinY then chunk.MinY = localY end
											if localY > chunk.MaxY then chunk.MaxY = localY end
										end
									end
								end
							end
							wCol += nS
						end
					end
				end
			end
			penX += g.Adv * scale
		else
			penX += space * scale
		end
	end
end

function Draw.Rect(worldX: number, worldY: number, w: number, h: number, r: number, g: number, b: number, a: number?)
	if not Grid.IsReady or w <= 0 or h <= 0 then return end

	local x0 = floor(worldX - Camera.X)
	local y0 = floor(worldY - Camera.Y)
	local x1 = x0 + w - 1
	local y1 = y0 + h - 1
	if x1 < clipX0 or y1 < clipY0 or x0 > clipX1 or y0 > clipY1 then return end

	if x0 < clipX0 then x0 = clipX0 end
	if y0 < clipY0 then y0 = clipY0 end
	if x1 > clipX1 then x1 = clipX1 end
	if y1 > clipY1 then y1 = clipY1 end

	local aa = a or 255

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
					if aa >= 255 then
						fillU32(chunk.Buffer, (localY * chunk.Width + localX) * 4, count, r + g * 256 + b * 65536 + 0xFF000000)
					else
						local cw, buf, ia = chunk.Width, chunk.Buffer, 255 - aa
						for lx = localX, spanEndLocal do
							local off = (localY * cw + lx) * 4
							local dst = readu32(buf, off)
							writeu32(buf, off,
								(r * aa + (dst % 256) * ia) // 255
								+ ((g * aa + (dst // 256 % 256) * ia) // 255) * 256
								+ ((b * aa + (dst // 65536 % 256) * ia) // 255) * 65536
								+ 0xFF000000)
						end
					end

					if localX < chunk.MinX then chunk.MinX = localX end
					if spanEndLocal > chunk.MaxX then chunk.MaxX = spanEndLocal end
					if localY < chunk.MinY then chunk.MinY = localY end
					if localY > chunk.MaxY then chunk.MaxY = localY end

					px += count
				else
					px += (CHUNK_SIZE - localX)
				end
			end
		end
	end
end

function Draw.RectRotated(worldX: number, worldY: number, w: number, h: number, angle: number, r: number, g: number, b: number, a: number?)
	if not Grid.IsReady or w <= 0 or h <= 0 then return end
	local cx = worldX - Camera.X
	local cy = worldY - Camera.Y
	local ca, sa = cos(angle), sin(angle)
	local hw, hh = w * 0.5, h * 0.5
	local ex = abs(hw * ca) + abs(hh * sa)
	local ey = abs(hw * sa) + abs(hh * ca)

	local minX, maxX = floor(cx - ex), floor(cx + ex)
	local minY, maxY = floor(cy - ey), floor(cy + ey)
	if maxX < clipX0 or maxY < clipY0 or minX > clipX1 or minY > clipY1 then return end
	if minX < clipX0 then minX = clipX0 end
	if minY < clipY0 then minY = clipY0 end
	if maxX > clipX1 then maxX = clipX1 end
	if maxY > clipY1 then maxY = clipY1 end

	a = a or 255
	local blend = a < 255
	local packed = r + g * 256 + b * 65536 + a * 16777216
	local ar, ag, ab, ia = r * a, g * a, b * a, 255 - a

	if angle == 0 then
		for py = minY, maxY do
			local chunkRow = Chunks[py // CHUNK_SIZE]
			if chunkRow then
				local localY = py % CHUNK_SIZE
				for px = minX, maxX do
					local chunk = chunkRow[px // CHUNK_SIZE]
					if chunk then
						local localX = px % CHUNK_SIZE
						if localX < chunk.Width and localY < chunk.Height then
							local off = (localY * chunk.Width + localX) * 4
							if blend then
								local dst = readu32(chunk.Buffer, off)
								writeu32(chunk.Buffer, off,
									(ar + (dst % 256) * ia) // 255
									+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
									+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
									+ 0xFF000000)
							else
								writeu32(chunk.Buffer, off, packed)
							end
							if localX < chunk.MinX then chunk.MinX = localX end
							if localX > chunk.MaxX then chunk.MaxX = localX end
							if localY < chunk.MinY then chunk.MinY = localY end
							if localY > chunk.MaxY then chunk.MaxY = localY end
						end
					end
				end
			end
		end
		return
	end

	for py = minY, maxY do
		local chunkRow = Chunks[py // CHUNK_SIZE]
		if chunkRow then
			local localY = py % CHUNK_SIZE
			local dyc = py - cy
			for px = minX, maxX do
				local dxc = px - cx
				local lx = dxc * ca + dyc * sa
				local ly = dyc * ca - dxc * sa
				if lx >= -hw and lx <= hw and ly >= -hh and ly <= hh then
					local chunk = chunkRow[px // CHUNK_SIZE]
					if chunk then
						local localX = px % CHUNK_SIZE
						if localX < chunk.Width and localY < chunk.Height then
							local off = (localY * chunk.Width + localX) * 4
							if blend then
								local dst = readu32(chunk.Buffer, off)
								writeu32(chunk.Buffer, off,
									(ar + (dst % 256) * ia) // 255
									+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
									+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
									+ 0xFF000000)
							else
								writeu32(chunk.Buffer, off, packed)
							end
							if localX < chunk.MinX then chunk.MinX = localX end
							if localX > chunk.MaxX then chunk.MaxX = localX end
							if localY < chunk.MinY then chunk.MinY = localY end
							if localY > chunk.MaxY then chunk.MaxY = localY end
						end
					end
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
			local coverage = radius - dist + 0.5
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

local overlayFn = nil
-- One report per session for a failing overlay: it runs every frame.
local overlayWarned = false
function Renderer.System.SetOverlay(fn) overlayFn = fn end

local wasReady = false
RunService:BindToRenderStep("Ro2DEngineFlush", Enum.RenderPriority.Last.Value, function()
	Input.Flush()
	UI.Flush()
	if not Grid.IsReady then
		wasReady = false
		return
	end

	if not wasReady then
		wasReady = true
		if DeveloperBackgroundCode then Renderer.System.SetBackground(DeveloperBackgroundCode) end
	end

	if overlayFn then
		-- An overlay is screen space by definition: it is drawn after the world and
		-- has nothing to do with where the camera is looking. Every draw call bakes
		-- the camera in, so it is zeroed for the duration.
		local ocx, ocy = Camera.X, Camera.Y
		Camera.X, Camera.Y = 0, 0
		local ok, err = pcall(overlayFn)
		Camera.X, Camera.Y = ocx, ocy
		if not ok and not overlayWarned then
			overlayWarned = true
			warn("[Ro2D] overlay error, further errors suppressed: " .. tostring(err))
		end
	end
	-- End of frame: scissor state is per frame, so the next one starts unclipped
	-- even if a scene set a clip and never cleared it.
	resetClip()

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

			if hasCurrent and not SkipRestore then
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
end)

return Renderer
