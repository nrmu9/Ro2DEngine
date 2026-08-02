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
local BAND_X, BAND_Y = A("BandX"), A("BandY")
local BAND_W, BAND_H = A("BandW"), A("BandH")
local SCALE = A("DisplayScale")
local OFF_X, OFF_Y = A("OffsetX"), A("OffsetY")
local PIXELATED = A("Pixelated") == 1

local imgSize = Vector2.new(BAND_W, BAND_H)
-- EditableImage is gated behind an experience setting, and the check that decides
-- whether it is available can also just fail to reach Roblox. Either way there is
-- no canvas to draw into, so say so once and stop rather than letting every worker
-- raise it on every frame for the length of a session.
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

-- The write can start failing at any point in a session (the API status is
-- fetched, not fixed), and it runs once per worker per frame. Reported the first
-- time and never again: fifty thousand copies of one message is not a log.
local writeWarned = false

RunService.RenderStepped:ConnectParallel(function()
	local fid = ST.frame
	if fid == nil or fid == lastFrame then
		return
	end
	local bytes = ST.commands
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
		warn("[Ro2D] canvas write failed, further errors suppressed: " .. tostring(err))
	end
end)

SharedTable.update(ST, "ready", function(v)
	return (v or 0) + 1
end)
