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
-- This worker's own stream key. Each band is handed only the commands that touch
-- it, rather than every worker walking the whole scene -- see ParallelRenderer.
local BAND_I = A("BandIndex")
local CMD_KEY = "c" .. BAND_I
local BAND_X, BAND_Y = A("BandX"), A("BandY")
local BAND_W, BAND_H = A("BandW"), A("BandH")
local SCALE = A("DisplayScale")
local OFF_X, OFF_Y = A("OffsetX"), A("OffsetY")
local PIXELATED = A("Pixelated") == 1

local imgSize = Vector2.new(BAND_W, BAND_H)
-- EditableImage can be unavailable, or the availability check can fail; say
-- so once and stop.
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

local buf = buffer.create(BAND_W * BAND_H * 4)
local sprites, fonts = {}, {}
local rz = Rasterizer.new(buf, BAND_W, BAND_H, sprites, fonts)

actor:BindToMessage("sprite", function(id, bytes, sw, sh)
	sprites[id] = { Width = sw, Height = sh, Buffer = buffer.fromstring(bytes) }
end)
actor:BindToMessage("font", function(id, encoded)
	fonts[id] = FontCodec.decode(encoded)
end)

local ST = SharedTableRegistry:GetSharedTable("Ro2D_Frame")
local lastFrame = -1

-- The write can start failing mid-session and runs per worker per frame;
-- reported once.
local writeWarned = false

-- A worker stops itself when it leaves the tree: a callback already
-- scheduled for the frame still runs, and task.synchronize outside an Actor
-- throws. Destroying and AncestryChanged answer different endings.
local alive = true
local frameConn
local function stop()
	if not alive then return end
	alive = false
	if frameConn then
		frameConn:Disconnect()
		frameConn = nil
	end
	-- The band is not parented to anything, so destroying the actor does not take
	-- it with us.
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
	-- Before the synchronize: the destroy happens serially, so a callback
	-- past this check is safe for the rest of its run.
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
	rz:setOffset(ST.camX + BAND_X, ST.camY + BAND_Y)
	-- Scissor state is per frame: a stream that sets a clip and never clears it
	-- must not leak into the next frame.
	rz:resetClip()
	CommandBuffer.decode(bytes, rz)
	task.synchronize()
	local ok, err = pcall(image.WritePixelsBuffer, image, Vector2.zero, imgSize, buf)
	if not ok and not writeWarned then
		writeWarned = true
		-- Once for the CANVAS, not per worker: a failure is all of them
		-- failing on the same cause. The local flag quiets this worker, the
		-- shared one its neighbours.
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
