--!optimize 2
--!native

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local engine = script.Parent.Parent
local CommandBuffer = require(engine:WaitForChild("CommandBuffer"))
local FontCodec = require(script.Parent:WaitForChild("FontCodec"))
local ComputePool = require(script.Parent:WaitForChild("ComputePool"))
local DrawBounds = require(script.Parent:WaitForChild("DrawBounds"))

local floor, min, max, ceil = math.floor, math.min, math.max, math.ceil

local PR = {}
PR.Draw = {}
PR.System = {}
PR.Camera = { X = 0, Y = 0, Zoom = 1 }

local function zoomed(x: number, y: number, z: number): (number, number)
	local cam = PR.Camera
	local hw, hh = PR.Width * 0.5, PR.Height * 0.5
	return cam.X + hw + (x - cam.X - hw) * z, cam.Y + hh + (y - cam.Y - hh) * z
end
local spriteOpts = { Scale = 1, FlipX = false, FlipY = false }
local overlayWarned = false
local presentWarned = false
PR.Width = 0
PR.Height = 0
PR.IsReady = false
PR.Compute = ComputePool

local bands = {}
local nBands = 0
local ST = SharedTableRegistry:GetSharedTable("Ro2D_Frame")
local frameId = 0

local spriteReg, spriteList = {}, {}
local fontReg, fontList = {}, {}
local nextSpriteId, nextFontId = 1, 1
local workers = {}
local lastReady = 0
local layoutGen = 0
local cbPool = {}

local function broadcastSprite(id, sprite)
	local bytes = buffer.tostring(sprite.Buffer)
	for i = 1, #workers do
		workers[i].actor:SendMessage("sprite", id, bytes, sprite.Width, sprite.Height)
	end
end
local function broadcastFont(id, font)
	local encoded = FontCodec.encode(font)
	for i = 1, #workers do
		workers[i].actor:SendMessage("font", id, encoded)
	end
end
local function rebroadcastAll()
	for id, sprite in pairs(spriteList) do
		broadcastSprite(id, sprite)
	end
	for id, font in pairs(fontList) do
		broadcastFont(id, font)
	end
end
local function spriteIdOf(sprite)
	local id = spriteReg[sprite]
	if not id then
		id = nextSpriteId
		nextSpriteId += 1
		spriteReg[sprite] = id
		spriteList[id] = sprite
		broadcastSprite(id, sprite)
	end
	return id
end
local function fontIdOf(font)
	local id = fontReg[font]
	if not id then
		id = nextFontId
		nextFontId += 1
		fontReg[font] = id
		fontList[id] = font
		broadcastFont(id, font)
	end
	return id
end

local grid, cols, rows, tileW, tileH, over = {}, 1, 1, 1, 1, 1

local function span(ax: number, ay: number, bx: number, by: number): (number, number, number, number)
	local r0, r1 = (ay - over) // tileH, by // tileH
	if r0 < 0 then r0 = 0 end
	if r1 >= rows then r1 = rows - 1 end
	local c0, c1 = (ax - over) // tileW, bx // tileW
	if c0 < 0 then c0 = 0 end
	if c1 >= cols then c1 = cols - 1 end
	return r0, r1, c0, c1
end

local stepId, openedAt = 0, -1
local presenting = false
local presentingAt = -1
local bgHeld, bgAtOpen, bgTouched = false, false, false
local function openFrame()
	if presenting and stepId - presentingAt < 2 then return end
	if openedAt == stepId then return end
	openedAt = stepId
	bgAtOpen = bgHeld
	for i = 1, nBands do bands[i].cb:reset() end
end

function PR.Draw.Clear(r, g, b, a)
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	for i = 1, nBands do bands[i].cb:clear(r, g, b, a) end
end
function PR.Draw.SetClip(x, y, w, h)
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	if w <= 0 or h <= 0 then
		for i = 1, nBands do bands[i].cb:clip(0, 0, -1, -1) end
		return
	end
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		local x1, y1 = zoomed(x + w, y + h, z)
		x, y = zoomed(x, y, z)
		w, h = x1 - x, y1 - y
	end
	local x0, y0 = x - cam.X, y - cam.Y
	for i = 1, nBands do bands[i].cb:clip(x0, y0, x0 + w - 1, y0 + h - 1) end
end
function PR.Draw.ClearClip()
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	for i = 1, nBands do bands[i].cb:clip(0, 0, PR.Width - 1, PR.Height - 1) end
end
function PR.Draw.Rect(x, y, w, h, r, g, b, a)
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		local x1, y1 = zoomed(x + w, y + h, z)
		x, y = zoomed(x, y, z)
		w = max(1, floor(x1 - cam.X) - floor(x - cam.X))
		h = max(1, floor(y1 - cam.Y) - floor(y - cam.Y))
	else
		w = floor(x + w - cam.X) - floor(x - cam.X)
		h = floor(y + h - cam.Y) - floor(y - cam.Y)
		if w < 1 or h < 1 then return end
	end
	local x0, y0 = x - cam.X, y - cam.Y
	if nBands == 1 then
		bands[1].cb:rect(x0, y0, w, h, r, g, b, a)
		return
	end
	local ax, ay, bx, by = DrawBounds.rect(x0, y0, w, h)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:rect(x0, y0, w, h, r, g, b, a)
			end
		end
	end
end
function PR.Draw.RectRotated(x, y, w, h, angle, r, g, b, a)
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		x, y = zoomed(x, y, z)
		w, h = w * z, h * z
	end
	local x0, y0 = x - cam.X, y - cam.Y
	if nBands == 1 then
		bands[1].cb:rectRot(x0, y0, w, h, angle, r, g, b, a)
		return
	end
	local ax, ay, bx, by = DrawBounds.rectRot(x0, y0, w, h)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:rectRot(x0, y0, w, h, angle, r, g, b, a)
			end
		end
	end
end
function PR.Draw.BeginPoints()
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	for i = 1, nBands do bands[i].cb:beginPoints() end
end
function PR.Draw.Point(x, y, size, r, g, b, a)
	if not PR.IsReady then return end
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		x, y = zoomed(x, y, z)
		size = max(1, size * z)
	end
	local s = floor(size)
	if s <= 0 then return end
	if s > 255 then s = 255 end
	local x0 = x - s * 0.5 - cam.X
	local y0 = y - s * 0.5 - cam.Y
	a = a or 255
	if nBands == 1 then
		bands[1].cb:point(x0, y0, s, r, g, b, a)
		return
	end
	local ax, ay, bx, by = DrawBounds.point(x0, y0, s)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:point(x0, y0, s, r, g, b, a)
			end
		end
	end
end
function PR.Draw.EndPoints()
	if not PR.IsReady then return end
	for i = 1, nBands do bands[i].cb:endPoints() end
end
function PR.Draw.Sprite(x, y, sprite, flipX, flipY)
	if not (PR.IsReady and sprite) then return end
	local cam = PR.Camera
	if cam.Zoom ~= 1 then
		spriteOpts.FlipX, spriteOpts.FlipY = flipX == true, flipY == true
		PR.Draw.SpriteEx(x + sprite.Width * 0.5, y + sprite.Height * 0.5, sprite, spriteOpts)
		return
	end
	if openedAt ~= stepId then openFrame() end
	local x0, y0 = x - cam.X, y - cam.Y
	local id = spriteReg[sprite] or spriteIdOf(sprite)
	if nBands == 1 then
		bands[1].cb:sprite(x0, y0, id, flipX, flipY)
		return
	end
	local ax, ay, bx, by = DrawBounds.sprite(x0, y0, sprite.Width, sprite.Height)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:sprite(x0, y0, id, flipX, flipY)
			end
		end
	end
end
function PR.Draw.SpriteEx(x, y, sprite, opts)
	if not (PR.IsReady and sprite) then return end
	if openedAt ~= stepId then openFrame() end
	opts = opts or {}
	local scale, rot = opts.Scale or 1, opts.Rotation or 0
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		x, y = zoomed(x, y, z)
		scale *= z
	end
	local tr, tg, tb = opts.TintR or 255, opts.TintG or 255, opts.TintB or 255
	local al = opts.Alpha or 255
	local x0, y0 = x - cam.X, y - cam.Y
	local id = spriteReg[sprite] or spriteIdOf(sprite)
	if nBands == 1 then
		bands[1].cb:spriteEx(x0, y0, id, scale, rot, tr, tg, tb, al, opts.FlipX, opts.FlipY)
		return
	end
	local ax, ay, bx, by = DrawBounds.spriteEx(x0, y0, sprite.Width, sprite.Height, scale, rot)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:spriteEx(x0, y0, id, scale, rot, tr, tg, tb, al, opts.FlipX, opts.FlipY)
			end
		end
	end
end
function PR.Draw.Pixel(x, y, r, g, b, a)
	if PR.IsReady then PR.Draw.Rect(x, y, 1, 1, r, g, b, a) end
end
function PR.Draw.LineSDF(x0, y0, x1, y1, thickness, r, g, b)
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		x0, y0 = zoomed(x0, y0, z)
		x1, y1 = zoomed(x1, y1, z)
		thickness *= z
	end
	local ax0, ay0 = x0 - cam.X, y0 - cam.Y
	local ax1, ay1 = x1 - cam.X, y1 - cam.Y
	if nBands == 1 then
		bands[1].cb:line(ax0, ay0, ax1, ay1, thickness, r, g, b)
		return
	end
	local ax, ay, bx, by = DrawBounds.line(ax0, ay0, ax1, ay1, thickness)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:line(ax0, ay0, ax1, ay1, thickness, r, g, b)
			end
		end
	end
end
function PR.Draw.CircleSDF(x, y, radius, r, g, b, a)
	if not PR.IsReady then return end
	if openedAt ~= stepId then openFrame() end
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		x, y = zoomed(x, y, z)
		radius *= z
	end
	local cx, cy = x - cam.X, y - cam.Y
	if nBands == 1 then
		bands[1].cb:circle(cx, cy, radius, r, g, b, a)
		return
	end
	local ax, ay, bx, by = DrawBounds.circle(cx, cy, radius)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:circle(cx, cy, radius, r, g, b, a)
			end
		end
	end
end
local polyPts = buffer.create(512)
function PR.Draw.Polygon(xs, ys, r, g, b, a, ox, oy, count)
	if not PR.IsReady then return end
	local n = min(count or #xs, #xs, #ys, 65535)
	if n < 3 then return end
	if openedAt ~= stepId then openFrame() end
	local cam = PR.Camera
	local z = cam.Zoom
	ox, oy = ox or 0, oy or 0
	if buffer.len(polyPts) < n * 8 then polyPts = buffer.create(n * 16) end
	local pts = polyPts
	local ax, ay, bx, by = math.huge, math.huge, -math.huge, -math.huge
	for k = 1, n do
		local x, y = xs[k] + ox, ys[k] + oy
		if z ~= 1 then x, y = zoomed(x, y, z) end
		x, y = x - cam.X, y - cam.Y
		buffer.writef32(pts, k * 8 - 8, x)
		buffer.writef32(pts, k * 8 - 4, y)
		if x < ax then ax = x end
		if x > bx then bx = x end
		if y < ay then ay = y end
		if y > by then by = y end
	end
	if not (ax <= bx and ay <= by) then return end
	a = a or 255
	if nBands == 1 then
		bands[1].cb:poly(pts, 0, n, r, g, b, a)
		return
	end
	ax, ay, bx, by = DrawBounds.poly(ax, ay, bx, by)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:poly(pts, 0, n, r, g, b, a)
			end
		end
	end
end
function PR.Draw.MeasureText(text, font, scale)
	if not font then return 0 end
	local glyphs, space = font.Glyphs, font.SpaceAdvance
	local s = tostring(text)
	local w = 0
	for i = 1, #s do
		local g = glyphs[string.byte(s, i)]
		w += g and g.Adv or space
	end
	return w * (scale or 1)
end
function PR.Draw.Text(x, y, text, font, opts)
	if not (PR.IsReady and font and text) then return end
	if openedAt ~= stepId then openFrame() end
	local s = tostring(text)
	if s == "" then return end
	opts = opts or {}
	local scale = opts.Scale or 1
	if scale <= 0 then return end
	local cam = PR.Camera
	local z = cam.Zoom
	if z ~= 1 then
		x, y = zoomed(x, y, z)
		scale *= z
	end
	local align = opts.Align
	local width = nil
	if align == "center" then
		width = PR.Draw.MeasureText(s, font, scale)
		x -= width * 0.5
	elseif align == "right" then
		width = PR.Draw.MeasureText(s, font, scale)
		x -= width
	end
	if opts.VAlign == "center" then
		y -= (font.CapCenter or 0) * scale
	end
	local id = fontReg[font] or fontIdOf(font)
	local tr, tg, tb = opts.TintR or 255, opts.TintG or 255, opts.TintB or 255
	local al = opts.Alpha or 255
	local x0, y0 = x - cam.X, y - cam.Y
	if nBands == 1 then
		bands[1].cb:text(x0, y0, s, id, scale, tr, tg, tb, al)
		return
	end
	if width == nil then width = PR.Draw.MeasureText(s, font, scale) end
	local lo, hi = DrawBounds.textVSpan(s, font)
	local ax, ay, bx, by = DrawBounds.text(x0, y0, width, scale, lo, hi)
	local r0, r1, c0, c1 = span(ax, ay, bx, by)
	for row = r0, r1 do
		local base = row * cols + 1
		for col = c0, c1 do
			local bd = grid[base + col]
			if bd and bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
				bd.cb:text(x0, y0, s, id, scale, tr, tg, tb, al)
			end
		end
	end
end

local function buildWorkers(canvasFrame, targetW, targetH, displayScale, offX, offY, pixelated, workerCount)
	for i = 1, nBands do ST["c" .. i] = nil end
	for i = 1, nBands do cbPool[i] = bands[i].cb end
	bgHeld, bgAtOpen = false, false
	table.clear(bands)
	nBands = 0
	table.clear(spriteReg)
	table.clear(spriteList)
	nextSpriteId = 1
	local prevGen = layoutGen
	layoutGen += 1

	table.clear(grid)
	over = max(1, ceil(1 / max(displayScale, 1e-3)))
	cols = max(1, ceil(targetW / (1024 - over)))
	rows = max(ceil(targetH / (1024 - over)), ceil(workerCount / cols))
	tileW = ceil(targetW / cols)
	tileH = ceil(targetH / rows)

	local template = engine:WaitForChild("parallel"):WaitForChild("WorkerActor")
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local bx, by = c * tileW, r * tileH
			local bw = min(tileW, targetW - bx)
			local bh = min(tileH, targetH - by)
			if bw > 0 and bh > 0 then
				local vw, vh = bw, bh
				bw += min(over, targetW - bx - bw)
				bh += min(over, targetH - by - bh)
				nBands += 1
				local cb = cbPool[nBands] or CommandBuffer.new()
				cb:reset()
				bands[nBands] = { x0 = bx, y0 = by, x1 = bx + bw - 1, y1 = by + bh - 1, cb = cb }
				grid[r * cols + c + 1] = bands[nBands]
				local prior = workers[nBands] and workers[nBands].actor
				local kept = prior ~= nil and prior.Parent == canvasFrame and prior:GetAttribute("Applied") == prevGen
				if prior and not kept then prior:Destroy() end
				local a = if kept then prior else template:Clone()
				a:SetAttribute("BandIndex", nBands)
				a:SetAttribute("BandX", bx)
				a:SetAttribute("BandY", by)
				a:SetAttribute("BandW", bw)
				a:SetAttribute("BandH", bh)
				a:SetAttribute("BandVisW", vw)
				a:SetAttribute("BandVisH", vh)
				a:SetAttribute("DisplayScale", displayScale)
				a:SetAttribute("OffsetX", offX)
				a:SetAttribute("OffsetY", offY)
				a:SetAttribute("Pixelated", pixelated and 1 or 0)
				a:SetAttribute("Layout", layoutGen)
				if kept then
					a:SendMessage("layout", layoutGen)
				else
					a.Parent = canvasFrame
					workers[nBands] = { actor = a }
				end
			end
		end
	end
	for i = #workers, nBands + 1, -1 do
		workers[i].actor:Destroy()
		workers[i] = nil
	end
end

local stepConn, presentBound
local cfgFixed, cfgFill, cfgPixelated, cfgWorkerCount = nil, false, true, 4
local rebuild

function PR.System.Init(canvasFrame, config)
	config = config or {}

	local res = config.Resolution
	cfgFixed = (typeof(res) == "Vector2" and res.X >= 1 and res.Y >= 1) and res or nil
	cfgFill = config.Fill == true
	cfgPixelated = config.AntiAliasing ~= true
	cfgWorkerCount = config.WorkerCount or 4

	function rebuild()
		local size = canvasFrame.AbsoluteSize
		local cw, ch = size.X, size.Y
		if cw <= 0 or ch <= 0 then return end
		local targetW, targetH, displayScale, offX, offY
		if cfgFixed and cfgFill then
			targetH = floor(cfgFixed.Y)
			displayScale = ch / targetH
			targetW = max(1, floor(cw / displayScale))
			offX, offY = 0, 0
		elseif cfgFixed then
			targetW, targetH = floor(cfgFixed.X), floor(cfgFixed.Y)
			displayScale = min(cw / targetW, ch / targetH)
			offX = floor((cw - targetW * displayScale) * 0.5)
			offY = floor((ch - targetH * displayScale) * 0.5)
		else
			targetW, targetH, displayScale, offX, offY = floor(cw), floor(ch), 1, 0, 0
		end
		PR.Width, PR.Height = targetW, targetH
		PR._scale, PR._offX, PR._offY = displayScale, offX, offY
		buildWorkers(canvasFrame, targetW, targetH, displayScale, offX, offY, cfgPixelated, cfgWorkerCount)
		PR.IsReady = true
	end
	rebuild()

	local computeWorkers = config.ComputeWorkers or 0
	if computeWorkers > 0 then
		ComputePool.init(canvasFrame, computeWorkers, engine:WaitForChild("parallel"):WaitForChild("ComputeActor"))
	end
	canvasFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		task.wait(0.05)
		rebuild()
	end)

	local function presentFrame()
		local rdy = ST.ready or 0
		if rdy ~= lastReady then
			lastReady = rdy
			rebroadcastAll()
		end
		if (PR._tintA or 0) > 0 then
			for i = 1, nBands do bands[i].cb:tint(PR._tintR, PR._tintG, PR._tintB, PR._tintA) end
		end
		if (PR._fadeA or 0) > 0 then
			for i = 1, nBands do bands[i].cb:tint(0, 0, 0, PR._fadeA) end
		end
		if PR._overlay then
			local ocx, ocy, oz = PR.Camera.X, PR.Camera.Y, PR.Camera.Zoom
			PR.Camera.X, PR.Camera.Y, PR.Camera.Zoom = 0, 0, 1
			local ok, err = pcall(PR._overlay)
			PR.Camera.X, PR.Camera.Y, PR.Camera.Zoom = ocx, ocy, oz
			if not ok and not overlayWarned then
				overlayWarned = true
				warn("[Ro2D] overlay error, further errors suppressed: " .. tostring(err))
			end
		end
		ST.camX = 0
		ST.camY = 0
		ST.layout = layoutGen
		if openedAt == stepId then
			ST.keep = bgAtOpen
		else
			ST.keep = bgHeld
		end
		for i = 1, nBands do
			ST["c" .. i] = bands[i].cb:serialize()
		end
	end

	if stepConn then stepConn:Disconnect() end
	stepConn = RunService.RenderStepped:Connect(function()
		stepId += 1
	end)
	if presentBound then RunService:UnbindFromRenderStep("Ro2DParallelPresent") end
	presentBound = true
	RunService:BindToRenderStep("Ro2DParallelPresent", Enum.RenderPriority.Last.Value + 1, function()
		if not PR.IsReady then return end
		if PR._skip and not bgTouched then
			PR._skip = false
			for i = 1, nBands do bands[i].cb:reset() end
			return
		end
		PR._skip = false
		presenting = true
		presentingAt = stepId
		local ok, err = pcall(presentFrame)
		for i = 1, nBands do bands[i].cb:reset() end
		presenting = false
		if ok then
			frameId += 1
			ST.frame = frameId
		else
			if bgTouched then bgHeld = false end
			if not presentWarned then
				presentWarned = true
				warn("[Ro2D] frame dropped, further drops suppressed: " .. tostring(err))
			end
		end
		bgTouched = false
	end)
end

function PR.System.ImageError()
	for i = 1, nBands do
		local w = workers[i]
		local err = w and w.actor:GetAttribute("ImageError")
		if err then return err end
	end
	return nil
end

function PR.System.ScreenToCanvas(sx, sy)
	local inv = 1 / (PR._scale or 1)
	return floor((sx - (PR._offX or 0)) * inv), floor((sy - (PR._offY or 0)) * inv)
end

function PR.System.SetResolution(res, fill)
	local fixed = (typeof(res) == "Vector2" and res.X >= 1 and res.Y >= 1) and res or nil
	local newFill = if fill == nil then cfgFill else fill == true
	local same = newFill == cfgFill
		and ((fixed == nil and cfgFixed == nil)
			or (fixed ~= nil and cfgFixed ~= nil and fixed.X == cfgFixed.X and fixed.Y == cfgFixed.Y))
	if same then return end
	cfgFixed = fixed
	cfgFill = newFill
	if rebuild then
		PR.IsReady = false
		rebuild()
	end
end

function PR.System.SetTint(r, g, b, a)
	PR._tintR, PR._tintG, PR._tintB, PR._tintA = r, g, b, a or 0
end
function PR.System.SetOverlay(fn)
	PR._overlay = fn
end
function PR.System.SetFade(a)
	PR._fadeA = max(0, min(255, floor(a or 0)))
end
function PR.System.SetBackground(callback)
	if not PR.IsReady then
		if callback == nil then bgHeld = false end
		return false
	end
	openFrame()
	if callback then callback() end
	for i = 1, nBands do bands[i].cb:background(callback ~= nil) end
	bgHeld, bgTouched = callback ~= nil, true
	return true
end
function PR.System.BackgroundHeld()
	return bgHeld
end
function PR.System.SkipFrame()
	PR._skip = true
end

function PR.System.SetImmediateMode() end

return PR
