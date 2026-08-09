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
local abs, cos, sin = math.abs, math.cos, math.sin

local PR = {}
PR.Draw = {}
PR.System = {}
PR.Camera = { X = 0, Y = 0 }
-- One report per session for a failing overlay: it runs every frame.
local overlayWarned = false
PR.Width = 0
PR.Height = 0
PR.IsReady = false
PR.Compute = ComputePool

-- One command stream PER BAND, and the canvas rectangle each one covers.
--
-- There used to be a single stream that every worker copied and walked in full.
-- That is the real cost of this renderer: a command is decoded once per worker
-- whether or not it lands anywhere near that worker's band, so eight workers meant
-- eight times the decode work for a scene, and seven eighths of it produced
-- nothing. On a heavy frame that is what exhausts a parallel resumption's time
-- budget -- the errors name whichever primitive the clock happened to stop in,
-- which is why they name a different one every time.
--
-- Now each command is bounded once, here, on the main thread, and written only
-- into the bands it actually touches. The test moves from N workers to one place,
-- and a band's stream carries its own share of the scene instead of all of it.
--
-- State commands -- clear, tint, clip -- have no position and go to every band.
-- Order within a band is preserved because every band is appended to in the same
-- order the calls arrive, so a clip still precedes what it clips.
local bands = {}
local nBands = 0
local ST = SharedTableRegistry:GetSharedTable("Ro2D_Frame")
local frameId = 0

local spriteReg, spriteList = {}, {}
local fontReg, fontList = {}, {}
local nextAssetId = 1
local workers = {}
local lastReady = 0

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
		id = nextAssetId
		nextAssetId += 1
		spriteReg[sprite] = id
		spriteList[id] = sprite
		broadcastSprite(id, sprite)
	end
	return id
end
local function fontIdOf(font)
	local id = fontReg[font]
	if not id then
		id = nextAssetId
		nextAssetId += 1
		fontReg[font] = id
		fontList[id] = font
		broadcastFont(id, font)
	end
	return id
end

-- ------------------------------------------------------------- routing ------

-- Bounds are canvas-space and INCLUSIVE, matching how the rasteriser clamps.
-- Every one below is conservative: a band may be handed a command that turns out
-- to paint nothing in it, and that costs a wasted decode. The opposite mistake --
-- a band NOT handed a command that does touch it -- is a hole in the picture at a
-- band seam, so every bound here rounds outwards.

-- The scene has one band on most canvases, and the whole test is skipped there.
local function only()
	return nBands == 1 and bands[1].cb or nil
end

function PR.Draw.Clear(r, g, b, a)
	if not PR.IsReady then return end
	for i = 1, nBands do bands[i].cb:clear(r, g, b, a) end
end
-- Restricts subsequent drawing to a rectangle, in the same world space the draw
-- calls use. Resets to the whole surface at the start of every frame, so a scene
-- that errors part-way through cannot leave the next one clipped.
--
-- Broadcast rather than routed. A clip is state: a band that is handed the shapes
-- but not the clip in front of them draws them unclipped.
function PR.Draw.SetClip(x, y, w, h)
	if not PR.IsReady then return end
	if w <= 0 or h <= 0 then
		-- empty: nothing draws until the clip is cleared
		for i = 1, nBands do bands[i].cb:clip(0, 0, -1, -1) end
		return
	end
	local x0, y0 = x - PR.Camera.X, y - PR.Camera.Y
	for i = 1, nBands do bands[i].cb:clip(x0, y0, x0 + w - 1, y0 + h - 1) end
end
function PR.Draw.ClearClip()
	if not PR.IsReady then return end
	for i = 1, nBands do bands[i].cb:clip(0, 0, PR.Width - 1, PR.Height - 1) end
end
function PR.Draw.Rect(x, y, w, h, r, g, b, a)
	if not PR.IsReady then return end
	local x0, y0 = x - PR.Camera.X, y - PR.Camera.Y
	local one = only()
	if one then
		one:rect(x0, y0, w, h, r, g, b, a)
		return
	end
	local ax, ay, bx, by = DrawBounds.rect(x0, y0, w, h)
	for i = 1, nBands do
		local bd = bands[i]
		if bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
			bd.cb:rect(x0, y0, w, h, r, g, b, a)
		end
	end
end
function PR.Draw.RectRotated(x, y, w, h, angle, r, g, b, a)
	if not PR.IsReady then return end
	local x0, y0 = x - PR.Camera.X, y - PR.Camera.Y
	local one = only()
	if one then
		one:rectRot(x0, y0, w, h, angle, r, g, b, a)
		return
	end
	local ax, ay, bx, by = DrawBounds.rectRot(x0, y0, w, h)
	for i = 1, nBands do
		local bd = bands[i]
		if bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
			bd.cb:rectRot(x0, y0, w, h, angle, r, g, b, a)
		end
	end
end
-- Many small squares as one command. Bracket the run with Begin/End and call
-- Point for each; see CommandBuffer.beginPoints for why a particle field is worth
-- a command of its own.
--
-- Routed per POINT rather than per run, which is the whole reason this matters
-- for a particle field: a band ends up carrying its own particles and no others.
--
-- `size` is the side in pixels and is floored, which is exactly what a Rect of a
-- fractional size already covered.
function PR.Draw.BeginPoints()
	if not PR.IsReady then return end
	for i = 1, nBands do bands[i].cb:beginPoints() end
end
function PR.Draw.Point(x, y, size, r, g, b, a)
	if not PR.IsReady then return end
	local s = floor(size)
	if s <= 0 then return end
	if s > 255 then s = 255 end
	-- Offset by the side that will actually be DRAWN, not by the one asked for.
	--
	-- The square is `s` pixels wide because the extent is floored, but the corner
	-- was being placed half of the unfloored `size` back -- so a 2.6-wide particle
	-- drew two pixels centred a third of a pixel left and up of where it was meant
	-- to be. Small, constant, and in one direction, which is exactly how it read: a
	-- trail sitting slightly off the back of the bullet rather than behind it.
	local x0 = x - s * 0.5 - PR.Camera.X
	local y0 = y - s * 0.5 - PR.Camera.Y
	a = a or 255
	local one = only()
	if one then
		one:point(x0, y0, s, r, g, b, a)
		return
	end
	local ax, ay, bx, by = DrawBounds.point(x0, y0, s)
	for i = 1, nBands do
		local bd = bands[i]
		if bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
			bd.cb:point(x0, y0, s, r, g, b, a)
		end
	end
end
function PR.Draw.EndPoints()
	if not PR.IsReady then return end
	for i = 1, nBands do bands[i].cb:endPoints() end
end
function PR.Draw.Sprite(x, y, sprite, flipX, flipY)
	if not (PR.IsReady and sprite) then return end
	local x0, y0 = x - PR.Camera.X, y - PR.Camera.Y
	local id = spriteIdOf(sprite)
	local one = only()
	if one then
		one:sprite(x0, y0, id, flipX, flipY)
		return
	end
	-- The rasteriser treats this position as the TOP LEFT.
	local ax, ay, bx, by = DrawBounds.sprite(x0, y0, sprite.Width, sprite.Height)
	for i = 1, nBands do
		local bd = bands[i]
		if bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
			bd.cb:sprite(x0, y0, id, flipX, flipY)
		end
	end
end
function PR.Draw.SpriteEx(x, y, sprite, opts)
	if not (PR.IsReady and sprite) then return end
	opts = opts or {}
	local scale, rot = opts.Scale or 1, opts.Rotation or 0
	local tr, tg, tb = opts.TintR or 255, opts.TintG or 255, opts.TintB or 255
	local al = opts.Alpha or 255
	local x0, y0 = x - PR.Camera.X, y - PR.Camera.Y
	local id = spriteIdOf(sprite)
	local one = only()
	if one then
		one:spriteEx(x0, y0, id, scale, rot, tr, tg, tb, al, opts.FlipX, opts.FlipY)
		return
	end
	-- Centred here, unlike Sprite.
	local ax, ay, bx, by = DrawBounds.spriteEx(x0, y0, sprite.Width, sprite.Height, scale, rot)
	for i = 1, nBands do
		local bd = bands[i]
		if bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
			bd.cb:spriteEx(x0, y0, id, scale, rot, tr, tg, tb, al, opts.FlipX, opts.FlipY)
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
	local s = tostring(text)
	if s == "" then return end
	opts = opts or {}
	local scale = opts.Scale or 1
	if scale <= 0 then return end
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
	local id = fontIdOf(font)
	local tr, tg, tb = opts.TintR or 255, opts.TintG or 255, opts.TintB or 255
	local al = opts.Alpha or 255
	local x0, y0 = x - PR.Camera.X, y - PR.Camera.Y
	local one = only()
	if one then
		one:text(x0, y0, s, id, scale, tr, tg, tb, al)
		return
	end
	if width == nil then width = PR.Draw.MeasureText(s, font, scale) end
	local lo, hi = DrawBounds.textVSpan(s, font)
	local ax, ay, bx, by = DrawBounds.text(x0, y0, width, scale, lo, hi)
	for i = 1, nBands do
		local bd = bands[i]
		if bx >= bd.x0 and by >= bd.y0 and ax <= bd.x1 and ay <= bd.y1 then
			bd.cb:text(x0, y0, s, id, scale, tr, tg, tb, al)
		end
	end
end

local canvasRef
local function buildWorkers(canvasFrame, targetW, targetH, displayScale, offX, offY, pixelated, workerCount)
	for i = 1, #workers do
		workers[i].actor:Destroy()
	end
	for _, ch in canvasFrame:GetChildren() do
		if ch:IsA("ImageLabel") and string.sub(ch.Name, 1, 8) == "PWorker_" then
			ch:Destroy()
		end
	end
	table.clear(workers)
	-- Drop the streams of the layout being replaced. A resolution change can leave
	-- fewer bands than before, and a key nothing reads any more is still a copy of
	-- a frame held in the shared table for the rest of the session.
	for i = 1, nBands do ST["c" .. i] = nil end
	table.clear(bands)
	nBands = 0
	table.clear(spriteReg)
	table.clear(spriteList)
	table.clear(fontReg)
	table.clear(fontList)
	nextAssetId = 1
	lastReady = 0

	local cols = max(1, ceil(targetW / 1024))
	local rows = max(ceil(targetH / 1024), ceil(workerCount / cols))
	local tileW = ceil(targetW / cols)
	local tileH = ceil(targetH / rows)

	local template = engine:WaitForChild("parallel"):WaitForChild("WorkerActor")
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local bx, by = c * tileW, r * tileH
			local bw = min(tileW, targetW - bx)
			local bh = min(tileH, targetH - by)
			if bw > 0 and bh > 0 then
				local a = template:Clone()
				-- Its own stream, and the canvas rectangle that decides what goes into
				-- it. The index is what the worker reads its stream back by.
				nBands += 1
				bands[nBands] = { x0 = bx, y0 = by, x1 = bx + bw - 1, y1 = by + bh - 1,
					cb = CommandBuffer.new() }
				a:SetAttribute("BandIndex", nBands)
				a:SetAttribute("BandX", bx)
				a:SetAttribute("BandY", by)
				a:SetAttribute("BandW", bw)
				a:SetAttribute("BandH", bh)
				a:SetAttribute("DisplayScale", displayScale)
				a:SetAttribute("OffsetX", offX)
				a:SetAttribute("OffsetY", offY)
				a:SetAttribute("Pixelated", pixelated and 1 or 0)
				a.Parent = canvasFrame
				workers[#workers + 1] = { actor = a }
			end
		end
	end
end

local presentConn
local cfgFixed, cfgFill, cfgPixelated, cfgWorkerCount = nil, false, true, 4
local rebuild

function PR.System.Init(canvasFrame, config)
	config = config or {}
	canvasRef = canvasFrame

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

	if presentConn then presentConn:Disconnect() end
	presentConn = RunService:BindToRenderStep("Ro2DParallelPresent", Enum.RenderPriority.Last.Value + 1, function()
		if not PR.IsReady then return end
		-- A frame the caller says is identical to the last one is not presented at
		-- all: the workers keep the pixels they already wrote, so nothing is
		-- decoded and nothing is uploaded. See System.SkipFrame.
		if PR._skip then
			PR._skip = false
			for i = 1, nBands do bands[i].cb:reset() end
			return
		end
		local rdy = ST.ready or 0
		if rdy ~= lastReady then
			lastReady = rdy
			rebroadcastAll()
		end
		-- Full-surface state, so every band gets both.
		if (PR._tintA or 0) > 0 then
			for i = 1, nBands do bands[i].cb:tint(PR._tintR, PR._tintG, PR._tintB, PR._tintA) end
		end
		if (PR._fadeA or 0) > 0 then
			for i = 1, nBands do bands[i].cb:tint(0, 0, 0, PR._fadeA) end
		end
		if PR._overlay then
		-- An overlay is screen space by definition: it is drawn after the world and
		-- has nothing to do with where the camera is looking. Every draw call bakes
		-- the camera in as it is recorded, so it is zeroed for the duration -- a
		-- fight's camera was otherwise carrying the overlay off screen with it, and
		-- moving it around while it went.
		--
		-- Errors are reported once. This runs every frame, so one bad overlay would
		-- otherwise be either silent or fifty thousand lines of log.
			local ocx, ocy = PR.Camera.X, PR.Camera.Y
			PR.Camera.X, PR.Camera.Y = 0, 0
			local ok, err = pcall(PR._overlay)
			PR.Camera.X, PR.Camera.Y = ocx, ocy
			if not ok and not overlayWarned then
				overlayWarned = true
				warn("[Ro2D] overlay error, further errors suppressed: " .. tostring(err))
			end
		end
		ST.camX = 0
		ST.camY = 0
		-- Every band's stream is published BEFORE the frame id moves. A worker only
		-- reads when the id changes, so it can never pick up half a frame -- the
		-- stream it finds under its own key is always the one for the id it saw.
		for i = 1, nBands do
			local bd = bands[i]
			ST["c" .. i] = bd.cb:serialize()
			bd.cb:reset()
		end
		frameId += 1
		ST.frame = frameId
	end)
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
function PR.System.SetBackground()
	return false
end
-- Declares this frame identical to the one on screen.
--
-- The canvas is persistent: workers write their band and it stays written, so a
-- frame that would paint exactly the same pixels does not need to be painted. A
-- scene sitting behind a settled modal is the case this exists for -- the panel
-- has finished fading, nothing under it is moving, and the composite on screen is
-- already the answer. Compositing it again every frame costs a full decode and a
-- full image upload per worker to produce the picture that is already there.
--
-- Called INSTEAD of drawing, not after it: the command buffer is discarded, so
-- anything recorded before this is thrown away rather than deferred.
--
-- One frame only. Every frame that should hold has to say so, which is what stops
-- a scene forgetting to start drawing again.
function PR.System.SkipFrame()
	PR._skip = true
end

function PR.System.SetImmediateMode() end

return PR
