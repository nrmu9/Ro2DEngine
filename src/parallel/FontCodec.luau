--!optimize 2

local buffer = buffer
local floor = math.floor

local FontCodec = {}

function FontCodec.encode(font): string
	local glyphs = font.Glyphs
	local order = {}
	for b in pairs(glyphs) do
		order[#order + 1] = b
	end
	local atlasLen = buffer.len(font.Buffer)
	local buf = buffer.create(4 + atlasLen + 2 + 4 + 2 + #order * 21)
	local c = 0
	buffer.writeu32(buf, c, atlasLen); c += 4
	buffer.copy(buf, c, font.Buffer, 0, atlasLen); c += atlasLen
	buffer.writeu16(buf, c, floor(font.Width)); c += 2
	buffer.writef32(buf, c, font.SpaceAdvance or 0); c += 4
	buffer.writeu16(buf, c, #order); c += 2
	for _, b in ipairs(order) do
		local g = glyphs[b]
		buffer.writeu8(buf, c, b)
		buffer.writeu16(buf, c + 1, floor(g.X)); buffer.writeu16(buf, c + 3, floor(g.Y))
		buffer.writeu16(buf, c + 5, floor(g.W)); buffer.writeu16(buf, c + 7, floor(g.H))
		buffer.writef32(buf, c + 9, g.Adv); buffer.writef32(buf, c + 13, g.OX); buffer.writef32(buf, c + 17, g.OY)
		c += 21
	end
	return buffer.tostring(buf)
end

function FontCodec.decode(str: string)
	local buf = buffer.fromstring(str)
	local c = 0
	local atlasLen = buffer.readu32(buf, c); c += 4
	local atlas = buffer.create(atlasLen)
	buffer.copy(atlas, 0, buf, c, atlasLen); c += atlasLen
	local width = buffer.readu16(buf, c); c += 2
	local space = buffer.readf32(buf, c); c += 4
	local count = buffer.readu16(buf, c); c += 2
	local glyphs = {}
	for _ = 1, count do
		local b = buffer.readu8(buf, c)
		glyphs[b] = {
			X = buffer.readu16(buf, c + 1), Y = buffer.readu16(buf, c + 3),
			W = buffer.readu16(buf, c + 5), H = buffer.readu16(buf, c + 7),
			Adv = buffer.readf32(buf, c + 9), OX = buffer.readf32(buf, c + 13), OY = buffer.readf32(buf, c + 17),
		}
		c += 21
	end
	return { Buffer = atlas, Width = width, SpaceAdvance = space, Glyphs = glyphs }
end

return FontCodec
