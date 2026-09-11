--!optimize 2
--!native

local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local actor = script:GetActor()
local engine = ReplicatedStorage:WaitForChild("Ro2DEngine")
local CommandBuffer = require(engine:WaitForChild("CommandBuffer"))
local Rasterizer = require(engine:WaitForChild("Rasterizer"))
local FontCodec = require(engine:WaitForChild("parallel"):WaitForChild("FontCodec"))

local function A(name)
	local v = actor:GetAttribute(name)
	while v == nil do
		actor:GetAttributeChangedSignal(name):Wait()
		v = actor:GetAttribute(name)
	end
	return v
end
local BAND_I = A("BandIndex")
local CMD_KEY = "c" .. BAND_I
local BAND_X, BAND_Y = A("BandX"), A("BandY")
local BAND_W, BAND_H = A("BandW"), A("BandH")
local SCALE = A("DisplayScale")
local OFF_X, OFF_Y = A("OffsetX"), A("OffsetY")
local PIXELATED = A("Pixelated") == 1

local imgSize = Vector2.new(BAND_W, BAND_H)
local imgOk, image = pcall(function()
	return AssetService:CreateEditableImage({ Size = imgSize })
end)
if not imgOk or image == nil then
	warn("[Ro2D] EditableImage unavailable, this worker will not draw: " .. tostring(image))
	return
end
local frame = Instance.new("ImageLabel")
frame.Name = string.format("PWorker_%d_%d", BAND_X, BAND_Y)
frame.BackgroundTransparency = 1
frame.BorderSizePixel = 0
local ex0 = math.round(OFF_X + BAND_X * SCALE)
local ey0 = math.round(OFF_Y + BAND_Y * SCALE)
local ex1 = math.round(OFF_X + (BAND_X + BAND_W) * SCALE)
local ey1 = math.round(OFF_Y + (BAND_Y + BAND_H) * SCALE)
frame.Position = UDim2.fromOffset(ex0, ey0)
frame.Size = UDim2.fromOffset(ex1 - ex0, ey1 - ey0)
frame.ResampleMode = PIXELATED and Enum.ResamplerMode.Pixelated or Enum.ResamplerMode.Default
frame.ImageContent = Content.fromObject(image)
frame.Parent = actor.Parent

local BAND_BYTES = BAND_W * BAND_H * 4
local buf = buffer.create(BAND_BYTES)
local sprites, fonts = {}, {}
local rz = Rasterizer.new(buf, BAND_W, BAND_H, sprites, fonts)
local bg = nil
local held = false
local whole = true
local lx0, ly0, lx1, ly1 = BAND_W, BAND_H, -1, -1

function rz.background(self, keep)
	if keep then
		if bg == nil then bg = buffer.create(BAND_BYTES) end
		buffer.copy(bg, 0, buf, 0, BAND_BYTES)
	end
	held = keep
	whole = true
	self:resetDirty()
end

local scratch = {}
local nScratch = 0
local function scratchOf(w, h)
	local key = w * 65536 + h
	local s = scratch[key]
	if s == nil then
		if nScratch >= 8 then
			table.clear(scratch)
			nScratch = 0
		end
		s = buffer.create(w * h * 4)
		scratch[key] = s
		nScratch += 1
	end
	return s
end
local function roundUp(n, cap)
	local p = 1
	while p < n do p *= 2 end
	return p < cap and p or cap
end

actor:BindToMessage("sprite", function(id, bytes, sw, sh)
	sprites[id] = { Width = sw, Height = sh, Buffer = buffer.fromstring(bytes) }
end)
actor:BindToMessage("font", function(id, encoded)
	fonts[id] = FontCodec.decode(encoded)
end)

local ST = SharedTableRegistry:GetSharedTable("Ro2D_Frame")
local lastFrame = -1
local writeWarned = false
local alive = true
local frameConn
local function stop()
	if not alive then return end
	alive = false
	if frameConn then
		frameConn:Disconnect()
		frameConn = nil
	end
	if image then
		image:Destroy()
		image = nil
	end
end
actor.Destroying:Connect(stop)
actor.AncestryChanged:Connect(function(_, parent)
	if parent == nil then stop() end
end)

frameConn = RunService.RenderStepped:ConnectParallel(function()
	if not alive then return end
	local fid = ST.frame
	if fid == nil or fid == lastFrame then
		return
	end
	local bytes = ST[CMD_KEY]
	if bytes == nil then
		return
	end
	lastFrame = fid
	if held and not ST.keep then held = false end
	if held then
		if lx0 <= lx1 then
			local rowBytes = (lx1 - lx0 + 1) * 4
			for row = ly0, ly1 do
				local o = (row * BAND_W + lx0) * 4
				buffer.copy(buf, o, bg, o, rowBytes)
			end
		end
		whole = false
	else
		whole = true
	end
	rz:resetDirty()
	rz:setOffset(ST.camX + BAND_X, ST.camY + BAND_Y)
	rz:resetClip()
	CommandBuffer.decode(bytes, rz)
	local ux, uy, uw, uh = 0, 0, BAND_W, BAND_H
	if not whole then
		local x0, y0 = math.min(lx0, rz.dx0), math.min(ly0, rz.dy0)
		local x1, y1 = math.max(lx1, rz.dx1), math.max(ly1, rz.dy1)
		lx0, ly0, lx1, ly1 = rz.dx0, rz.dy0, rz.dx1, rz.dy1
		if x0 > x1 or y0 > y1 then return end
		uw, uh = roundUp(x1 - x0 + 1, BAND_W), roundUp(y1 - y0 + 1, BAND_H)
		ux = x0 + uw > BAND_W and BAND_W - uw or x0
		uy = y0 + uh > BAND_H and BAND_H - uh or y0
	else
		lx0, ly0, lx1, ly1 = rz.dx0, rz.dy0, rz.dx1, rz.dy1
	end
	local src = buf
	if uw ~= BAND_W or uh ~= BAND_H then
		src = scratchOf(uw, uh)
		local rowBytes = uw * 4
		for row = 0, uh - 1 do
			buffer.copy(src, row * rowBytes, buf, ((uy + row) * BAND_W + ux) * 4, rowBytes)
		end
	end
	task.synchronize()
	local ok, err
	if src == buf then
		ok, err = pcall(image.WritePixelsBuffer, image, Vector2.zero, imgSize, buf)
	else
		ok, err = pcall(image.WritePixelsBuffer, image, Vector2.new(ux, uy), Vector2.new(uw, uh), src)
	end
	if not ok and not writeWarned then
		writeWarned = true
		local first = false
		SharedTable.update(ST, "writeWarned", function(v)
			first = v == nil
			return true
		end)
		if first then
			warn("[Ro2D] canvas write failed, further errors suppressed: " .. tostring(err))
		end
	end
end)

SharedTable.update(ST, "ready", function(v)
	return (v or 0) + 1
end)
