--!optimize 2
--!native

local buffer = buffer
local readu32, writeu32 = buffer.readu32, buffer.writeu32
local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local ceil = math.ceil
local cos, sin = math.cos, math.sin

local Rasterizer = {}
Rasterizer.__index = Rasterizer

function Rasterizer.new(buf: buffer, bufW: number, bufH: number, sprites, fonts)
	return setmetatable({
		buf = buf, w = bufW, h = bufH,
		ox = 0, oy = 0,
		-- Inclusive band-local scissor. Every primitive already clamps to the band,
		-- so clipping is the same clamp against tighter bounds and costs nothing
		-- when no clip is set.
		cx0 = 0, cy0 = 0, cx1 = bufW - 1, cy1 = bufH - 1,
		sprites = sprites or {},
		fonts = fonts or {},
	}, Rasterizer)
end

function Rasterizer:setOffset(ox: number, oy: number)
	self.ox, self.oy = ox, oy
end

-- Screen-space, inclusive. Intersected with this worker's band, so a clip that
-- misses the band entirely leaves it with nothing to draw.
function Rasterizer:setClip(x0: number, y0: number, x1: number, y1: number)
	local lx0 = floor(x0 - self.ox)
	local ly0 = floor(y0 - self.oy)
	local lx1 = floor(x1 - self.ox)
	local ly1 = floor(y1 - self.oy)
	if lx0 < 0 then lx0 = 0 end
	if ly0 < 0 then ly0 = 0 end
	if lx1 > self.w - 1 then lx1 = self.w - 1 end
	if ly1 > self.h - 1 then ly1 = self.h - 1 end
	self.cx0, self.cy0, self.cx1, self.cy1 = lx0, ly0, lx1, ly1
end

function Rasterizer:resetClip()
	self.cx0, self.cy0, self.cx1, self.cy1 = 0, 0, self.w - 1, self.h - 1
end

function Rasterizer:clear(r, g, b, a)
	local packed = r + g * 256 + b * 65536 + (a or 255) * 16777216
	local buf, n = self.buf, self.w * self.h
	writeu32(buf, 0, packed)
	local filled = 1
	while filled < n do
		local copy = min(filled, n - filled)
		buffer.copy(buf, filled * 4, buf, 0, copy * 4)
		filled += copy
	end
end

function Rasterizer:tint(r, g, b, a)
	if a <= 0 then return end
	local buf, n = self.buf, self.w * self.h
	local ia = 255 - a
	local ar, ag, ab = r * a, g * a, b * a
	local off = 0
	for _ = 1, n do
		local dst = readu32(buf, off)
		writeu32(buf, off,
			(ar + (dst % 256) * ia) // 255
			+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
			+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
			+ 0xFF000000)
		off += 4
	end
end

function Rasterizer:rect(x, y, w, h, r, g, b, a)
	if w <= 0 or h <= 0 then return end
	local bw, buf = self.w, self.buf
	local cx0, cy0, cx1, cy1 = self.cx0, self.cy0, self.cx1, self.cy1
	local x0 = floor(x - self.ox)
	local y0 = floor(y - self.oy)
	local x1 = x0 + w - 1
	local y1 = y0 + h - 1
	if x1 < cx0 or y1 < cy0 or x0 > cx1 or y0 > cy1 then return end
	if x0 < cx0 then x0 = cx0 end
	if y0 < cy0 then y0 = cy0 end
	if x1 > cx1 then x1 = cx1 end
	if y1 > cy1 then y1 = cy1 end
	local aa = a or 255
	if aa >= 255 then
		local packed = r + g * 256 + b * 65536 + 0xFF000000
		for py = y0, y1 do
			local rowoff = (py * bw + x0) * 4
			for _ = x0, x1 do
				writeu32(buf, rowoff, packed)
				rowoff += 4
			end
		end
	else
		local ia = 255 - aa
		for py = y0, y1 do
			local off = (py * bw + x0) * 4
			for _ = x0, x1 do
				local dst = readu32(buf, off)
				writeu32(buf, off,
					(r * aa + (dst % 256) * ia) // 255
					+ ((g * aa + (dst // 256 % 256) * ia) // 255) * 256
					+ ((b * aa + (dst // 65536 % 256) * ia) // 255) * 65536
					+ 0xFF000000)
				off += 4
			end
		end
	end
end

function Rasterizer:rectRot(wx, wy, w, h, angle, r, g, b, a)
	if w <= 0 or h <= 0 then return end
	local bw, buf = self.w, self.buf
	local cx0b, cy0b, cx1b, cy1b = self.cx0, self.cy0, self.cx1, self.cy1
	local cx = wx - self.ox
	local cy = wy - self.oy
	local hw, hh = w * 0.5, h * 0.5
	a = a or 255
	local blend = a < 255
	local packed = r + g * 256 + b * 65536 + a * 16777216
	local ar, ag, ab, ia = r * a, g * a, b * a, 255 - a

	if angle == 0 then
		local minX, maxX = floor(cx - hw), floor(cx + hw)
		local minY, maxY = floor(cy - hh), floor(cy + hh)
		if maxX < cx0b or maxY < cy0b or minX > cx1b or minY > cy1b then return end
		if minX < cx0b then minX = cx0b end
		if minY < cy0b then minY = cy0b end
		if maxX > cx1b then maxX = cx1b end
		if maxY > cy1b then maxY = cy1b end
		for py = minY, maxY do
			local off = (py * bw + minX) * 4
			for _ = minX, maxX do
				if blend then
					local dst = readu32(buf, off)
					writeu32(buf, off,
						(ar + (dst % 256) * ia) // 255
						+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
						+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
						+ 0xFF000000)
				else
					writeu32(buf, off, packed)
				end
				off += 4
			end
		end
		return
	end

	local ca, sa = cos(angle), sin(angle)
	local ex = abs(hw * ca) + abs(hh * sa)
	local ey = abs(hw * sa) + abs(hh * ca)
	local minX, maxX = floor(cx - ex), floor(cx + ex)
	local minY, maxY = floor(cy - ey), floor(cy + ey)
	if maxX < cx0b or maxY < cy0b or minX > cx1b or minY > cy1b then return end
	if minX < cx0b then minX = cx0b end
	if minY < cy0b then minY = cy0b end
	if maxX > cx1b then maxX = cx1b end
	if maxY > cy1b then maxY = cy1b end
	for py = minY, maxY do
		local dyc = py - cy
		local base = py * bw
		for px = minX, maxX do
			local dxc = px - cx
			local lx = dxc * ca + dyc * sa
			local ly = dyc * ca - dxc * sa
			if lx >= -hw and lx <= hw and ly >= -hh and ly <= hh then
				local off = (base + px) * 4
				if blend then
					local dst = readu32(buf, off)
					writeu32(buf, off,
						(ar + (dst % 256) * ia) // 255
						+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
						+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
						+ 0xFF000000)
				else
					writeu32(buf, off, packed)
				end
			end
		end
	end
end

function Rasterizer:spriteEx(wx, wy, spriteId, scale, rot, tintR, tintG, tintB, alpha, flipX, flipY)
	local sprite = self.sprites[spriteId]
	if not sprite then return end
	local sbuf, sw, sh = sprite.Buffer, sprite.Width, sprite.Height
	local bw, buf = self.w, self.buf
	local cx0b, cy0b, cx1b, cy1b = self.cx0, self.cy0, self.cx1, self.cy1
	local cx = wx - self.ox
	local cy = wy - self.oy
	local halfW, halfH = sw * 0.5, sh * 0.5
	local invScale = 1 / scale
	local ca, sa = cos(rot), sin(rot)
	local ex = (abs(halfW * ca) + abs(halfH * sa)) * scale
	local ey = (abs(halfW * sa) + abs(halfH * ca)) * scale
	local minX, maxX = floor(cx - ex), floor(cx + ex)
	local minY, maxY = floor(cy - ey), floor(cy + ey)
	if maxX < cx0b or maxY < cy0b or minX > cx1b or minY > cy1b then return end
	if minX < cx0b then minX = cx0b end
	if minY < cy0b then minY = cy0b end
	if maxX > cx1b then maxX = cx1b end
	if maxY > cy1b then maxY = cy1b end
	local tinted = tintR ~= 255 or tintG ~= 255 or tintB ~= 255
	local rot0 = rot == 0

	for py = minY, maxY do
		local base = py * bw
		local dyc = py - cy
		for px = minX, maxX do
			local dxc = px - cx
			local sxp, syp
			if rot0 then
				sxp = floor(dxc * invScale + halfW)
				syp = floor(dyc * invScale + halfH)
			else
				sxp = floor((dxc * ca + dyc * sa) * invScale + halfW)
				syp = floor((dyc * ca - dxc * sa) * invScale + halfH)
			end
			if flipX then sxp = sw - 1 - sxp end
			if flipY then syp = sh - 1 - syp end
			if sxp >= 0 and sxp < sw and syp >= 0 and syp < sh then
				local src = readu32(sbuf, (syp * sw + sxp) * 4)
				if src > 0xFFFFFF then
					local sr, sg, sb = src % 256, (src // 256) % 256, (src // 65536) % 256
					local oa = (src // 16777216) % 256
					if tinted then
						sr = (sr * tintR) // 255
						sg = (sg * tintG) // 255
						sb = (sb * tintB) // 255
					end
					if alpha ~= 255 then oa = (oa * alpha) // 255 end
					local off = (base + px) * 4
					if oa >= 255 then
						writeu32(buf, off, sr + sg * 256 + sb * 65536 + 0xFF000000)
					elseif oa > 0 then
						local dst = readu32(buf, off)
						local ia = 255 - oa
						writeu32(buf, off,
							(sr * oa + (dst % 256) * ia) // 255
							+ ((sg * oa + (dst // 256 % 256) * ia) // 255) * 256
							+ ((sb * oa + (dst // 65536 % 256) * ia) // 255) * 65536
							+ 0xFF000000)
					end
				end
			end
		end
	end
end

-- Draw.Sprite is positioned by its top-left corner, spriteEx by its centre, so
-- the coordinate has to be converted rather than forwarded. Without this every
-- Draw.Sprite lands half a sprite up and to the left of where the single
-- threaded renderer puts it.
function Rasterizer:sprite(wx, wy, spriteId, flipX, flipY)
	local sprite = self.sprites[spriteId]
	if not sprite then return end
	self:spriteEx(wx + sprite.Width * 0.5, wy + sprite.Height * 0.5, spriteId,
		1, 0, 255, 255, 255, 255, flipX, flipY)
end

local strbyte = string.byte
local colS = table.create(512, 0)
local colN = table.create(512, 0)
local colW = table.create(2048, 0)
function Rasterizer:text(wx, wy, str, fontId, scale, tr, tg, tb, alpha)
	local font = self.fonts[fontId]
	if not font or str == "" or scale <= 0 then return end
	local glyphs, atlas, aw, space = font.Glyphs, font.Buffer, font.Width, font.SpaceAdvance
	local bw, buf = self.w, self.buf
	local cx0b, cy0b, cx1b, cy1b = self.cx0, self.cy0, self.cx1, self.cy1
	local invScale = 1 / scale
	local penX = wx
	for i = 1, #str do
		local g = glyphs[strbyte(str, i)]
		if g then
			local gx, gy = g.X, g.Y
			local gW, gH = g.W, g.H
			local ox = floor(penX + g.OX * scale - self.ox)
			local oy = floor(wy + g.OY * scale - self.oy)
			local dw, dh = floor(gW * scale), floor(gH * scale)
			local wIdx = 0
			for px = 0, dw - 1 do
				local fx0 = px * invScale
				local fx1 = fx0 + invScale
				if fx1 > gW then fx1 = gW end
				local sxA = floor(fx0)
				local sxB = ceil(fx1) - 1
				colS[px] = sxA
				colN[px] = sxB - sxA + 1
				local sx = sxA
				while sx <= sxB do
					local lo = sx > fx0 and sx or fx0
					local hi = sx + 1 < fx1 and sx + 1 or fx1
					colW[wIdx] = hi - lo
					wIdx += 1
					sx += 1
				end
			end
			for py = 0, dh - 1 do
				local screenY = oy + py
				if screenY >= cy0b and screenY <= cy1b then
					local base = screenY * bw
					local fy0 = py * invScale
					local fy1 = fy0 + invScale
					if fy1 > gH then fy1 = gH end
					local syA = floor(fy0)
					local syB = ceil(fy1) - 1
					local invArea = 1 / ((fy1 - fy0) * invScale)
					local wCol = 0
					for px = 0, dw - 1 do
						local screenX = ox + px
						local sxA, nS = colS[px], colN[px]
						if screenX >= cx0b and screenX <= cx1b then
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
											if a > 0 then acc += a * colW[wCol + k] * wy end
										end
									end
									sy += 1
								end
								oa = floor(acc * invArea + 0.5)
								if oa > 255 then oa = 255 end
							end
							if alpha ~= 255 then oa = (oa * alpha) // 255 end
							if oa > 0 then
								local off = (base + screenX) * 4
								if oa >= 255 then
									writeu32(buf, off, tr + tg * 256 + tb * 65536 + 0xFF000000)
								else
									local dst = readu32(buf, off)
									local ia = 255 - oa
									writeu32(buf, off,
										(tr * oa + (dst % 256) * ia) // 255
										+ ((tg * oa + (dst // 256 % 256) * ia) // 255) * 256
										+ ((tb * oa + (dst // 65536 % 256) * ia) // 255) * 65536
										+ 0xFF000000)
								end
							end
						end
						wCol += nS
					end
				end
			end
			penX += g.Adv * scale
		else
			penX += space * scale
		end
	end
end

return Rasterizer
