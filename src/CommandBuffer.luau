--!optimize 2
--!native

local buffer = buffer
local wu8, wf32, wu16 = buffer.writeu8, buffer.writef32, buffer.writeu16
local ru8, rf32, ru16 = buffer.readu8, buffer.readf32, buffer.readu16

local CommandBuffer = {}
CommandBuffer.__index = CommandBuffer

local OP = {
	CLEAR = 1,
	RECT = 2,
	RECT_ROT = 3,
	SPRITE = 4,
	SPRITE_EX = 5,
	TEXT = 6,
	TINT = 7,
	CLIP = 8,
}
CommandBuffer.OP = OP

local INITIAL = 262144

function CommandBuffer.new()
	local self = setmetatable({
		buf = buffer.create(INITIAL),
		cap = INITIAL,
		cur = 0,
	}, CommandBuffer)
	return self
end

function CommandBuffer:reset()
	self.cur = 0
end

function CommandBuffer:_need(extra: number)
	local want = self.cur + extra
	if want <= self.cap then return end
	local cap = self.cap
	while cap < want do cap *= 2 end
	local nb = buffer.create(cap)
	buffer.copy(nb, 0, self.buf, 0, self.cur)
	self.buf, self.cap = nb, cap
end

function CommandBuffer:clear(r, g, b, a)
	self:_need(5)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.CLEAR)
	wu8(buf, c + 1, r); wu8(buf, c + 2, g); wu8(buf, c + 3, b); wu8(buf, c + 4, a or 255)
	self.cur = c + 5
end

function CommandBuffer:tint(r, g, b, a)
	self:_need(5)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.TINT)
	wu8(buf, c + 1, r); wu8(buf, c + 2, g); wu8(buf, c + 3, b); wu8(buf, c + 4, a)
	self.cur = c + 5
end

-- Scissor state, in screen space and inclusive. Recorded in the stream rather
-- than sent out of band because it has to take effect at the point in the frame
-- where it was set, not for the whole frame.
function CommandBuffer:clip(x0, y0, x1, y1)
	self:_need(17)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.CLIP)
	wf32(buf, c + 1, x0); wf32(buf, c + 5, y0); wf32(buf, c + 9, x1); wf32(buf, c + 13, y1)
	self.cur = c + 17
end

function CommandBuffer:rect(x, y, w, h, r, g, b, a)
	self:_need(21)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.RECT)
	wf32(buf, c + 1, x); wf32(buf, c + 5, y); wf32(buf, c + 9, w); wf32(buf, c + 13, h)
	wu8(buf, c + 17, r); wu8(buf, c + 18, g); wu8(buf, c + 19, b); wu8(buf, c + 20, a or 255)
	self.cur = c + 21
end

function CommandBuffer:rectRot(cx, cy, w, h, angle, r, g, b, a)
	self:_need(25)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.RECT_ROT)
	wf32(buf, c + 1, cx); wf32(buf, c + 5, cy); wf32(buf, c + 9, w); wf32(buf, c + 13, h)
	wf32(buf, c + 17, angle)
	wu8(buf, c + 21, r); wu8(buf, c + 22, g); wu8(buf, c + 23, b); wu8(buf, c + 24, a or 255)
	self.cur = c + 25
end

function CommandBuffer:sprite(x, y, spriteId, flipX, flipY)
	self:_need(12)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.SPRITE)
	wf32(buf, c + 1, x); wf32(buf, c + 5, y)
	wu16(buf, c + 9, spriteId)
	wu8(buf, c + 11, (flipX and 1 or 0) + (flipY and 2 or 0))
	self.cur = c + 12
end

function CommandBuffer:spriteEx(x, y, spriteId, scale, rot, tr, tg, tb, alpha, flipX, flipY)
	self:_need(24)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.SPRITE_EX)
	wf32(buf, c + 1, x); wf32(buf, c + 5, y)
	wu16(buf, c + 9, spriteId)
	wf32(buf, c + 11, scale); wf32(buf, c + 15, rot)
	wu8(buf, c + 19, tr); wu8(buf, c + 20, tg); wu8(buf, c + 21, tb); wu8(buf, c + 22, alpha)
	wu8(buf, c + 23, (flipX and 1 or 0) + (flipY and 2 or 0))
	self.cur = c + 24
end

function CommandBuffer:text(x, y, str, fontId, scale, tr, tg, tb, alpha)
	local n = #str
	self:_need(21 + n)
	local buf, c = self.buf, self.cur
	wu8(buf, c, OP.TEXT)
	wf32(buf, c + 1, x); wf32(buf, c + 5, y)
	wu16(buf, c + 9, fontId)
	wf32(buf, c + 11, scale)
	wu8(buf, c + 15, tr); wu8(buf, c + 16, tg); wu8(buf, c + 17, tb); wu8(buf, c + 18, alpha)
	wu16(buf, c + 19, n)
	buffer.writestring(buf, c + 21, str)
	self.cur = c + 21 + n
end

function CommandBuffer:serialize(): string
	local trimmed = buffer.create(self.cur)
	buffer.copy(trimmed, 0, self.buf, 0, self.cur)
	return buffer.tostring(trimmed)
end

function CommandBuffer.decode(bytes: string, h)
	local buf = buffer.fromstring(bytes)
	local len = buffer.len(buf)
	local c = 0
	while c < len do
		local op = ru8(buf, c)
		if op == OP.CLEAR then
			h:clear(ru8(buf, c + 1), ru8(buf, c + 2), ru8(buf, c + 3), ru8(buf, c + 4))
			c += 5
		elseif op == OP.TINT then
			h:tint(ru8(buf, c + 1), ru8(buf, c + 2), ru8(buf, c + 3), ru8(buf, c + 4))
			c += 5
		elseif op == OP.CLIP then
			h:setClip(rf32(buf, c + 1), rf32(buf, c + 5), rf32(buf, c + 9), rf32(buf, c + 13))
			c += 17
		elseif op == OP.RECT then
			h:rect(rf32(buf, c + 1), rf32(buf, c + 5), rf32(buf, c + 9), rf32(buf, c + 13),
				ru8(buf, c + 17), ru8(buf, c + 18), ru8(buf, c + 19), ru8(buf, c + 20))
			c += 21
		elseif op == OP.RECT_ROT then
			h:rectRot(rf32(buf, c + 1), rf32(buf, c + 5), rf32(buf, c + 9), rf32(buf, c + 13),
				rf32(buf, c + 17), ru8(buf, c + 21), ru8(buf, c + 22), ru8(buf, c + 23), ru8(buf, c + 24))
			c += 25
		elseif op == OP.SPRITE then
			local f = ru8(buf, c + 11)
			h:sprite(rf32(buf, c + 1), rf32(buf, c + 5), ru16(buf, c + 9), f % 2 == 1, f >= 2)
			c += 12
		elseif op == OP.SPRITE_EX then
			local f = ru8(buf, c + 23)
			h:spriteEx(rf32(buf, c + 1), rf32(buf, c + 5), ru16(buf, c + 9),
				rf32(buf, c + 11), rf32(buf, c + 15),
				ru8(buf, c + 19), ru8(buf, c + 20), ru8(buf, c + 21), ru8(buf, c + 22),
				f % 2 == 1, f >= 2)
			c += 24
		elseif op == OP.TEXT then
			local n = ru16(buf, c + 19)
			h:text(rf32(buf, c + 1), rf32(buf, c + 5), buffer.readstring(buf, c + 21, n),
				ru16(buf, c + 9), rf32(buf, c + 11),
				ru8(buf, c + 15), ru8(buf, c + 16), ru8(buf, c + 17), ru8(buf, c + 18))
			c += 21 + n
		else
			break
		end
	end
end

return CommandBuffer
