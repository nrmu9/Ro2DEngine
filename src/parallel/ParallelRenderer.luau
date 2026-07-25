--!optimize 2

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local engine = script.Parent.Parent
local CommandBuffer = require(engine:WaitForChild("CommandBuffer"))
local FontCodec = require(script.Parent:WaitForChild("FontCodec"))
local ComputePool = require(script.Parent:WaitForChild("ComputePool"))

local floor, min, max, ceil = math.floor, math.min, math.max, math.ceil

local PR = {}
PR.Draw = {}
PR.System = {}
PR.Camera = { X = 0, Y = 0 }
PR.Width = 0
PR.Height = 0
PR.IsReady = false
PR.Compute = ComputePool

local cb = CommandBuffer.new()
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

function PR.Draw.Clear(r, g, b, a)
	if PR.IsReady then cb:clear(r, g, b, a) end
end
-- Restricts subsequent drawing to a rectangle, in the same world space the draw
-- calls use. Resets to the whole surface at the start of every frame, so a scene
-- that errors part-way through cannot leave the next one clipped.
function PR.Draw.SetClip(x, y, w, h)
	if not PR.IsReady then return end
	if w <= 0 or h <= 0 then
		cb:clip(0, 0, -1, -1) -- empty: nothing draws until the clip is cleared
		return
	end
	local x0, y0 = x - PR.Camera.X, y - PR.Camera.Y
	cb:clip(x0, y0, x0 + w - 1, y0 + h - 1)
end
function PR.Draw.ClearClip()
	if PR.IsReady then cb:clip(0, 0, PR.Width - 1, PR.Height - 1) end
end
function PR.Draw.Rect(x, y, w, h, r, g, b, a)
	if PR.IsReady then cb:rect(x - PR.Camera.X, y - PR.Camera.Y, w, h, r, g, b, a) end
end
function PR.Draw.RectRotated(x, y, w, h, angle, r, g, b, a)
	if PR.IsReady then cb:rectRot(x - PR.Camera.X, y - PR.Camera.Y, w, h, angle, r, g, b, a) end
end
function PR.Draw.Sprite(x, y, sprite, flipX, flipY)
	if PR.IsReady and sprite then cb:sprite(x - PR.Camera.X, y - PR.Camera.Y, spriteIdOf(sprite), flipX, flipY) end
end
function PR.Draw.SpriteEx(x, y, sprite, opts)
	if not (PR.IsReady and sprite) then return end
	opts = opts or {}
	cb:spriteEx(x - PR.Camera.X, y - PR.Camera.Y, spriteIdOf(sprite), opts.Scale or 1, opts.Rotation or 0,
		opts.TintR or 255, opts.TintG or 255, opts.TintB or 255, opts.Alpha or 255,
		opts.FlipX, opts.FlipY)
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
	if align == "center" then
		x -= PR.Draw.MeasureText(s, font, scale) * 0.5
	elseif align == "right" then
		x -= PR.Draw.MeasureText(s, font, scale)
	end
	if opts.VAlign == "center" then
		y -= (font.CapCenter or 0) * scale
	end
	cb:text(x - PR.Camera.X, y - PR.Camera.Y, s, fontIdOf(font), scale,
		opts.TintR or 255, opts.TintG or 255, opts.TintB or 255, opts.Alpha or 255)
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
		local rdy = ST.ready or 0
		if rdy ~= lastReady then
			lastReady = rdy
			rebroadcastAll()
		end
		if (PR._tintA or 0) > 0 then
			cb:tint(PR._tintR, PR._tintG, PR._tintB, PR._tintA)
		end
		if (PR._fadeA or 0) > 0 then
			cb:tint(0, 0, 0, PR._fadeA)
		end
		if PR._overlay then pcall(PR._overlay) end
		local bytes = cb:serialize()
		ST.camX = 0
		ST.camY = 0
		ST.commands = bytes
		frameId += 1
		ST.frame = frameId
		cb:reset()
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
function PR.System.SetImmediateMode() end

return PR
