--!optimize 2
--!native

local buffer = buffer
local readu32, writeu32 = buffer.readu32, buffer.writeu32
local readu8, readf32, writeu8 = buffer.readu8, buffer.readf32, buffer.writeu8
local bcopy, bcreate, readstring = buffer.copy, buffer.create, buffer.readstring
local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local ceil = math.ceil
local cos, sin = math.cos, math.sin
local HUGE = math.huge
local EPS = 1e-9
local SPAN = 3
local ROW_SAME = 16
local ROW_FLAT = 48
local CHUNK = 32
local GLYPH_SCALES = 16
local MEMO_MAX = 2048
local MEMO_PX = 32768
local MEMO_BYTES = 1048576
local MEMO_AGE = 2
local MEMO_MIN = 256
local MEMO_MISSES = 3
local MEMO_SKIP = 45
local spack, srep = string.pack, string.rep

local Shapes = if script then require(script.Parent:WaitForChild("Shapes")) else nil

local Rasterizer = {}
Rasterizer.__index = Rasterizer

function Rasterizer.useShapes(shapes)
	Shapes = shapes
end

function Rasterizer.new(buf: buffer, bufW: number, bufH: number, sprites, fonts)
	return setmetatable({
		buf = buf, w = bufW, h = bufH,
		ox = 0, oy = 0,
		cx0 = 0, cy0 = 0, cx1 = bufW - 1, cy1 = bufH - 1,
		dx0 = bufW, dy0 = bufH, dx1 = -1, dy1 = -1,
		sprites = sprites or {},
		fonts = fonts or {},
		memo = {}, memoN = 0, memoBytes = 0, tick = 0,
	}, Rasterizer)
end

function Rasterizer:forget()
	table.clear(self.memo)
	self.memoN, self.memoBytes = 0, 0
end

function Rasterizer:resetDirty()
	self.dx0, self.dy0, self.dx1, self.dy1 = self.w, self.h, -1, -1
	self.tick += 1
end

local function mark(self, x0: number, y0: number, x1: number, y1: number)
	if x0 < self.dx0 then self.dx0 = x0 end
	if y0 < self.dy0 then self.dy0 = y0 end
	if x1 > self.dx1 then self.dx1 = x1 end
	if y1 > self.dy1 then self.dy1 = y1 end
end

function Rasterizer:setOffset(ox: number, oy: number)
	self.ox, self.oy = ox, oy
end

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

local rowBuf = bcreate(4096)
local rowCap = 1024
local rowColor, rowLen = -1, 0

local function colorRow(packed: number, n: number): buffer
	if packed ~= rowColor then
		rowColor, rowLen = packed, 0
	elseif n <= rowLen then
		return rowBuf
	end
	if n > rowCap then
		local cap = rowCap
		while cap < n do cap *= 2 end
		rowBuf = bcreate(cap * 4)
		rowCap, rowLen = cap, 0
	end
	local filled = rowLen
	if filled == 0 then
		writeu32(rowBuf, 0, packed)
		filled = 1
	end
	while filled < n do
		local c = min(filled, n - filled)
		bcopy(rowBuf, filled * 4, rowBuf, 0, c * 4)
		filled += c
	end
	rowLen = filled
	return rowBuf
end

local function fillBox(buf: buffer, bw: number, x0: number, y0: number, x1: number, y1: number, packed: number)
	local n = x1 - x0 + 1
	if n <= 0 or y1 < y0 then return end
	local stride = bw * 4
	local off = (y0 * bw + x0) * 4
	if n < SPAN then
		for _ = y0, y1 do
			local o = off
			for _ = 1, n do
				writeu32(buf, o, packed)
				o += 4
			end
			off += stride
		end
		return
	end
	local bytes = n * 4
	bcopy(buf, off, colorRow(packed, n), 0, bytes)
	if n == bw then
		local total = (y1 - y0 + 1) * bytes
		local filled = bytes
		while filled < total do
			local c = min(filled, total - filled)
			bcopy(buf, off + filled, buf, off, c)
			filled += c
		end
		return
	end
	local first = off
	for _ = y0 + 1, y1 do
		off += stride
		bcopy(buf, off, buf, first, bytes)
	end
end

local function blendSpan(buf: buffer, off: number, n: number, ar: number, ag: number, ab: number, ia: number,
	lastD: number, lastO: number): (number, number)
	while n > 0 do
		local m = if n < CHUNK then n else CHUNK
		local bytes = m * 4
		if m == CHUNK then
			local d = readu32(buf, off)
			if d == readu32(buf, off + bytes - 4) and readstring(buf, off, bytes - 4) == readstring(buf, off + 4, bytes - 4) then
				if d ~= lastD then
					lastD = d
					lastO = (ar + (d % 256) * ia) // 255
						+ ((ag + (d // 256 % 256) * ia) // 255) * 256
						+ ((ab + (d // 65536 % 256) * ia) // 255) * 65536
						+ 0xFF000000
				end
				bcopy(buf, off, colorRow(lastO, m), 0, bytes)
				off += bytes
				n -= m
				continue
			end
		end
		for _ = 1, m do
			local dst = readu32(buf, off)
			if dst ~= lastD then
				lastD = dst
				lastO = (ar + (dst % 256) * ia) // 255
					+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
					+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
					+ 0xFF000000
			end
			writeu32(buf, off, lastO)
			off += 4
		end
		n -= m
	end
	return lastD, lastO
end

local function blendBox(buf: buffer, bw: number, x0: number, y0: number, x1: number, y1: number,
	r: number, g: number, b: number, a: number)
	local n = x1 - x0 + 1
	if n <= 0 or y1 < y0 then return end
	local ia = 255 - a
	local ar, ag, ab = r * a, g * a, b * a
	local stride, bytes = bw * 4, n * 4
	local off = (y0 * bw + x0) * 4
	local lastD, lastO = -1, 0
	local prevS, prevOff = nil, 0
	for _ = y0, y1 do
		if n >= ROW_SAME then
			local s = readstring(buf, off, bytes)
			if s == prevS then
				bcopy(buf, off, buf, prevOff, bytes)
				off += stride
				continue
			end
			prevS, prevOff = s, off
			if n >= ROW_FLAT then
				local d = readu32(buf, off)
				if d == readu32(buf, off + bytes - 4) and d == readu32(buf, off + (n // 2) * 4)
					and readstring(buf, off, bytes - 4) == readstring(buf, off + 4, bytes - 4) then
					if d ~= lastD then
						lastD = d
						lastO = (ar + (d % 256) * ia) // 255
							+ ((ag + (d // 256 % 256) * ia) // 255) * 256
							+ ((ab + (d // 65536 % 256) * ia) // 255) * 65536
							+ 0xFF000000
					end
					bcopy(buf, off, colorRow(lastO, n), 0, bytes)
					off += stride
					continue
				end
			end
		end
		lastD, lastO = blendSpan(buf, off, n, ar, ag, ab, ia, lastD, lastO)
		off += stride
	end
end

local function memoSweep(self)
	local memo, tick = self.memo, self.tick
	local n, bytes = 0, 0
	for k, e in memo do
		local used = if type(e) == "number" then e else e.used
		if tick - used > MEMO_AGE then
			memo[k] = nil
		else
			n += 1
			if type(e) == "table" then bytes += buffer.len(e.out) * 2 end
		end
	end
	self.memoN, self.memoBytes = n, bytes
end

local function memoSeen(self, key: string)
	local memo = self.memo
	local e = memo[key]
	if e == nil then
		if self.memoN >= MEMO_MAX then
			memoSweep(self)
			if self.memoN >= MEMO_MAX then
				table.clear(memo)
				self.memoN, self.memoBytes = 0, 0
			end
		end
		self.memoN += 1
		memo[key] = self.tick
		return nil
	end
	if type(e) == "number" then
		memo[key] = self.tick
		return false
	end
	e.used = self.tick
	return e
end

local function memoOpen(self, e, x0: number, y0: number, x1: number, y1: number): (boolean, { string }?)
	if x1 < x0 or y1 < y0 or (x1 - x0 + 1) * (y1 - y0 + 1) > MEMO_PX then return false, nil end
	local buf, bw = self.buf, self.w
	local bytes, stride = (x1 - x0 + 1) * 4, bw * 4
	if e then
		if e.skip > 0 then
			e.skip -= 1
			return false, nil
		end
		if e.x0 == x0 and e.y0 == y0 and e.x1 == x1 and e.y1 == y1 then
			local rows = e.rows
			local off = (y0 * bw + x0) * 4
			local same = true
			for i = 1, y1 - y0 + 1 do
				if readstring(buf, off, bytes) ~= rows[i] then
					same = false
					break
				end
				off += stride
			end
			if same then
				local out = e.out
				off = (y0 * bw + x0) * 4
				local o = 0
				for _ = y0, y1 do
					bcopy(buf, off, out, o, bytes)
					off += stride
					o += bytes
				end
				mark(self, x0, y0, x1, y1)
				e.miss = 0
				return true, nil
			end
			e.miss += 1
			if e.miss >= MEMO_MISSES then
				e.skip = MEMO_SKIP
				e.miss = 0
				return false, nil
			end
		end
	end
	local rows = table.create(y1 - y0 + 1)
	local off = (y0 * bw + x0) * 4
	for i = 1, y1 - y0 + 1 do
		rows[i] = readstring(buf, off, bytes)
		off += stride
	end
	return false, rows
end

local function memoClose(self, key: string, e, x0: number, y0: number, x1: number, y1: number, rows: { string })
	local buf, bw = self.buf, self.w
	local bytes, stride = (x1 - x0 + 1) * 4, bw * 4
	local size = bytes * (y1 - y0 + 1)
	if not e then
		if self.memoBytes + size * 2 > MEMO_BYTES then
			memoSweep(self)
			if self.memoBytes + size * 2 > MEMO_BYTES then return end
		end
		e = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, rows = rows, out = bcreate(size), miss = 0, skip = 0, used = self.tick }
		if self.memo[key] == nil then self.memoN += 1 end
		self.memo[key] = e
		self.memoBytes += size * 2
	else
		e.x0, e.y0, e.x1, e.y1, e.rows = x0, y0, x1, y1, rows
		if buffer.len(e.out) ~= size then e.out = bcreate(size) end
	end
	local out = e.out
	local off = (y0 * bw + x0) * 4
	local o = 0
	for _ = y0, y1 do
		bcopy(out, o, buf, off, bytes)
		off += stride
		o += bytes
	end
end

function Rasterizer:clear(r, g, b, a)
	local packed = r + g * 256 + b * 65536 + (a or 255) * 16777216
	local buf, n = self.buf, self.w * self.h
	self.ground = packed
	mark(self, 0, 0, self.w - 1, self.h - 1)
	writeu32(buf, 0, packed)
	local filled = 1
	while filled < n do
		local copy = min(filled, n - filled)
		bcopy(buf, filled * 4, buf, 0, copy * 4)
		filled += copy
	end
end

function Rasterizer:tint(r, g, b, a)
	if a <= 0 then return end
	mark(self, 0, 0, self.w - 1, self.h - 1)
	blendBox(self.buf, self.w, 0, 0, self.w - 1, self.h - 1, r, g, b, a)
end

function Rasterizer:rect(x, y, w, h, r, g, b, a)
	if w <= 0 or h <= 0 then return end
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
	if x0 < self.dx0 then self.dx0 = x0 end
	if y0 < self.dy0 then self.dy0 = y0 end
	if x1 > self.dx1 then self.dx1 = x1 end
	if y1 > self.dy1 then self.dy1 = y1 end
	local aa = a or 255
	local xe, ye = floor(x1), floor(y1)
	if xe < x0 or ye < y0 then return end
	if aa >= 255 then
		local packed = r + g * 256 + b * 65536 + 0xFF000000
		if ye == y0 then
			local n = xe - x0 + 1
			if n >= SPAN then
				bcopy(self.buf, (y0 * self.w + x0) * 4, colorRow(packed, n), 0, n * 4)
				return
			end
		end
		fillBox(self.buf, self.w, x0, y0, xe, ye, packed)
		return
	end
	if (xe - x0 + 1) * (ye - y0 + 1) >= MEMO_MIN then
		local key = spack("<dddddddddddddd", self.ox, self.oy, x, y, w, h, r, g, b, aa, cx0, cy0, cx1, cy1)
		local e = memoSeen(self, key)
		if e ~= nil then
			local hit, rows = memoOpen(self, e, x0, y0, xe, ye)
			if hit then return end
			blendBox(self.buf, self.w, x0, y0, xe, ye, r, g, b, aa)
			if rows then memoClose(self, key, e, x0, y0, xe, ye, rows) end
			return
		end
	end
	blendBox(self.buf, self.w, x0, y0, xe, ye, r, g, b, aa)
end

function Rasterizer:points(src: buffer, off: number, n: number)
	local bw, buf = self.w, self.buf
	local ox, oy = self.ox, self.oy
	local cx0, cy0, cx1, cy1 = self.cx0, self.cy0, self.cx1, self.cy1
	local dx0, dy0, dx1, dy1 = self.dx0, self.dy0, self.dx1, self.dy1
	for _ = 1, n do
		local s = readu8(src, off + 8)
		if s > 0 then
			local x0 = floor(readf32(src, off) - ox)
			local y0 = floor(readf32(src, off + 4) - oy)
			local x1, y1 = x0 + s - 1, y0 + s - 1
			if x1 >= cx0 and y1 >= cy0 and x0 <= cx1 and y0 <= cy1 then
				if x0 < cx0 then x0 = cx0 end
				if y0 < cy0 then y0 = cy0 end
				if x1 > cx1 then x1 = cx1 end
				if y1 > cy1 then y1 = cy1 end
				if x0 < dx0 then dx0 = x0 end
				if y0 < dy0 then dy0 = y0 end
				if x1 > dx1 then dx1 = x1 end
				if y1 > dy1 then dy1 = y1 end
				local a = readu8(src, off + 12)
				local r = readu8(src, off + 9)
				local g = readu8(src, off + 10)
				local b = readu8(src, off + 11)
				if a >= 255 then
					local packed = r + g * 256 + b * 65536 + 0xFF000000
					for py = y0, y1 do
						local o = (py * bw + x0) * 4
						for _ = x0, x1 do
							writeu32(buf, o, packed)
							o += 4
						end
					end
				else
					local ia = 255 - a
					local ar, ag, ab = r * a, g * a, b * a
					local lastD, lastO = -1, 0
					for py = y0, y1 do
						local o = (py * bw + x0) * 4
						for _ = x0, x1 do
							local dst = readu32(buf, o)
							if dst ~= lastD then
								lastD = dst
								lastO = (ar + (dst % 256) * ia) // 255
									+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
									+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
									+ 0xFF000000
							end
							writeu32(buf, o, lastO)
							o += 4
						end
					end
				end
			end
		end
		off += 13
	end
	self.dx0, self.dy0, self.dx1, self.dy1 = dx0, dy0, dx1, dy1
end

local function blendInto(buf: buffer, off: number, r: number, g: number, b: number, a: number)
	if a >= 255 then
		writeu32(buf, off, r + g * 256 + b * 65536 + 0xFF000000)
		return
	end
	local ia = 255 - a
	local dst = readu32(buf, off)
	writeu32(buf, off,
		(r * a + (dst % 256) * ia) // 255
		+ ((g * a + (dst // 256 % 256) * ia) // 255) * 256
		+ ((b * a + (dst // 65536 % 256) * ia) // 255) * 65536
		+ 0xFF000000)
end

function Rasterizer:circle(wx, wy, radius, r, g, b, a)
	if not Shapes or radius <= 0 then return end
	local bw, buf = self.w, self.buf
	local cx0, cy0, cx1, cy1 = self.cx0, self.cy0, self.cx1, self.cy1
	local cx, cy = wx - self.ox, wy - self.oy
	local x0, y0 = floor(cx - radius - 1), floor(cy - radius - 1)
	local x1, y1 = floor(cx + radius + 1), floor(cy + radius + 1)
	if x1 < cx0 or y1 < cy0 or x0 > cx1 or y0 > cy1 then return end
	mark(self, max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1))
	local function plot(px, py, pr, pg, pb, pa)
		blendInto(buf, (py * bw + px) * 4, pr, pg, pb, pa)
	end
	local function span(sx0, sx1, py, pr, pg, pb, pa)
		local off = (py * bw + sx0) * 4
		if pa >= 255 then
			local packed = pr + pg * 256 + pb * 65536 + 0xFF000000
			local n = sx1 - sx0 + 1
			if n >= SPAN then
				bcopy(buf, off, colorRow(packed, n), 0, n * 4)
				return
			end
			for _ = sx0, sx1 do
				writeu32(buf, off, packed)
				off += 4
			end
		else
			for _ = sx0, sx1 do
				blendInto(buf, off, pr, pg, pb, pa)
				off += 4
			end
		end
	end
	Shapes.circle(plot, cx, cy, radius, r, g, b, a or 255, cx0, cy0, cx1, cy1, span)
end

function Rasterizer:line(wx0, wy0, wx1, wy1, thickness, r, g, b)
	if not Shapes or thickness <= 0 then return end
	local bw, buf = self.w, self.buf
	local cx0, cy0, cx1, cy1 = self.cx0, self.cy0, self.cx1, self.cy1
	local ax, ay = wx0 - self.ox, wy0 - self.oy
	local bx, by = wx1 - self.ox, wy1 - self.oy
	local pad = thickness * 0.5 + 1
	local x0, y0 = floor(min(ax, bx) - pad), floor(min(ay, by) - pad)
	local x1, y1 = floor(max(ax, bx) + pad), floor(max(ay, by) + pad)
	if x1 < cx0 or y1 < cy0 or x0 > cx1 or y0 > cy1 then return end
	mark(self, max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1))
	local function plot(px, py, pr, pg, pb, pa)
		blendInto(buf, (py * bw + px) * 4, pr, pg, pb, pa)
	end
	Shapes.line(plot, ax, ay, bx, by, thickness, r, g, b, cx0, cy0, cx1, cy1)
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

	if angle == 0 then
		local minX, maxX = floor(cx - hw), floor(cx + hw)
		local minY, maxY = floor(cy - hh), floor(cy + hh)
		if maxX < cx0b or maxY < cy0b or minX > cx1b or minY > cy1b then return end
		if minX < cx0b then minX = cx0b end
		if minY < cy0b then minY = cy0b end
		if maxX > cx1b then maxX = cx1b end
		if maxY > cy1b then maxY = cy1b end
		mark(self, minX, minY, maxX, maxY)
		if blend then
			blendBox(buf, bw, minX, minY, maxX, maxY, r, g, b, a)
		else
			fillBox(buf, bw, minX, minY, maxX, maxY, packed)
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
	mark(self, minX, minY, maxX, maxY)
	local ia = 255 - a
	local ar, ag, ab = r * a, g * a, b * a
	local lastD, lastO = -1, 0
	for py = minY, maxY do
		local dyc = py - cy
		local lo, hi = -HUGE, HUGE
		local alo, ahi = -hw - dyc * sa, hw - dyc * sa
		if ca > EPS then
			lo, hi = alo / ca, ahi / ca
		elseif ca < -EPS then
			lo, hi = ahi / ca, alo / ca
		elseif alo > 0 or ahi < 0 then
			continue
		end
		local blo, bhi = dyc * ca - hh, dyc * ca + hh
		if sa > EPS then
			lo, hi = max(lo, blo / sa), min(hi, bhi / sa)
		elseif sa < -EPS then
			lo, hi = max(lo, bhi / sa), min(hi, blo / sa)
		elseif blo > 0 or bhi < 0 then
			continue
		end
		local rowMin = max(minX, floor(cx + lo) - 1)
		local rowMax = min(maxX, ceil(cx + hi) + 1)
		local first = rowMax + 1
		for px = rowMin, rowMax do
			local dxc = px - cx
			local lx = dxc * ca + dyc * sa
			local ly = dyc * ca - dxc * sa
			if lx >= -hw and lx <= hw and ly >= -hh and ly <= hh then
				first = px
				break
			end
		end
		if first > rowMax then continue end
		local last = first
		for px = rowMax, first + 1, -1 do
			local dxc = px - cx
			local lx = dxc * ca + dyc * sa
			local ly = dyc * ca - dxc * sa
			if lx >= -hw and lx <= hw and ly >= -hh and ly <= hh then
				last = px
				break
			end
		end
		local n = last - first + 1
		local off = (py * bw + first) * 4
		if blend then
			for _ = 1, n do
				local dst = readu32(buf, off)
				if dst ~= lastD then
					lastD = dst
					lastO = (ar + (dst % 256) * ia) // 255
						+ ((ag + (dst // 256 % 256) * ia) // 255) * 256
						+ ((ab + (dst // 65536 % 256) * ia) // 255) * 65536
						+ 0xFF000000
				end
				writeu32(buf, off, lastO)
				off += 4
			end
		elseif n >= SPAN then
			bcopy(buf, off, colorRow(packed, n), 0, n * 4)
		else
			for _ = 1, n do
				writeu32(buf, off, packed)
				off += 4
			end
		end
	end
end

local overOf = setmetatable({}, { __mode = "k" })
local groundColor, groundPixel, groundRows = -1, "", {}

local function overGround(sprite, ground: number): buffer
	if ground ~= groundColor then
		groundColor, groundPixel, groundRows = ground, spack("<I4", ground), {}
	end
	local o = overOf[sprite]
	if o and o.ground == ground then return o.buf end
	local sbuf = sprite.Buffer
	local bytes = sprite.Width * sprite.Height * 4
	local out = if o and buffer.len(o.buf) == bytes then o.buf else bcreate(bytes)
	local dr, dg, db = ground % 256, ground // 256 % 256, ground // 65536 % 256
	for i = 0, bytes - 4, 4 do
		local src = readu32(sbuf, i)
		if src <= 0xFFFFFF then
			writeu32(out, i, ground)
		elseif src >= 0xFF000000 then
			writeu32(out, i, src)
		else
			local oa = (src // 16777216) % 256
			local ia = 255 - oa
			writeu32(out, i, ((src % 256) * oa + dr * ia) // 255
				+ (((src // 256) % 256 * oa + dg * ia) // 255) * 256
				+ (((src // 65536) % 256 * oa + db * ia) // 255) * 65536
				+ 0xFF000000)
		end
	end
	overOf[sprite] = { ground = ground, buf = out }
	return out
end

local runsOf = setmetatable({}, { __mode = "k" })

local function spriteRuns(sprite)
	local runs = runsOf[sprite]
	if runs then return runs end
	local sbuf, sw, sh = sprite.Buffer, sprite.Width, sprite.Height
	runs = table.create(sh)
	for y = 0, sh - 1 do
		local segs = {}
		local base = y * sw
		local x = 0
		while x < sw do
			local v = readu32(sbuf, (base + x) * 4)
			local k = if v <= 0xFFFFFF then 0 elseif v >= 0xFF000000 then 1 else 2
			local e = x
			while e + 1 < sw do
				local v2 = readu32(sbuf, (base + e + 1) * 4)
				local k2 = if v2 <= 0xFFFFFF then 0 elseif v2 >= 0xFF000000 then 1 else 2
				if k2 ~= k then break end
				e += 1
			end
			if k ~= 0 then
				segs[#segs + 1] = x
				segs[#segs + 1] = e
				segs[#segs + 1] = k
			end
			x = e + 1
		end
		runs[y + 1] = segs
	end
	runsOf[sprite] = runs
	return runs
end

local valuesOf = setmetatable({}, { __mode = "k" })

local function spriteValues(sprite)
	local runs = valuesOf[sprite]
	if runs then return runs end
	local sbuf, sw, sh = sprite.Buffer, sprite.Width, sprite.Height
	runs = table.create(sh)
	for y = 0, sh - 1 do
		local segs = {}
		local base = y * sw
		local x = 0
		while x < sw do
			local v = readu32(sbuf, (base + x) * 4)
			local e = x
			while e + 1 < sw and readu32(sbuf, (base + e + 1) * 4) == v do
				e += 1
			end
			if v > 0xFFFFFF then
				segs[#segs + 1] = x
				segs[#segs + 1] = e
				segs[#segs + 1] = v
			end
			x = e + 1
		end
		runs[y + 1] = segs
	end
	valuesOf[sprite] = runs
	return runs
end

local startCol = table.create(1024, 0)

local function blitPlain(self, sprite, cx: number, cy: number, flipY: boolean?)
	local sbuf, sw, sh = sprite.Buffer, sprite.Width, sprite.Height
	local bw, buf = self.w, self.buf
	local cx0b, cy0b, cx1b, cy1b = self.cx0, self.cy0, self.cx1, self.cy1
	local halfW, halfH = sw * 0.5, sh * 0.5
	local minX, maxX = floor(cx - halfW), floor(cx + halfW)
	local minY, maxY = floor(cy - halfH), floor(cy + halfH)
	if maxX < cx0b or maxY < cy0b or minX > cx1b or minY > cy1b then return end
	if minX < cx0b then minX = cx0b end
	if minY < cy0b then minY = cy0b end
	if maxX > cx1b then maxX = cx1b end
	if maxY > cy1b then maxY = cy1b end
	if minX < self.dx0 then self.dx0 = minX end
	if minY < self.dy0 then self.dy0 = minY end
	if maxX > self.dx1 then self.dx1 = maxX end
	if maxY > self.dy1 then self.dy1 = maxY end
	local lastS, lastD, lastO = -1, -1, 0
	local kx, ky = floor(halfW - cx), floor(halfH - cy)
	local pxA, pxB = max(minX, -kx), min(maxX, sw - 1 - kx)
	local pyA, pyB = max(minY, -ky), min(maxY, sh - 1 - ky)
	if pxA > pxB or pyA > pyB then return end
	local runs = spriteRuns(sprite)
	local ground = self.ground
	local over = if ground then overGround(sprite, ground) else nil
	local sxA, sxB = pxA + kx, pxB + kx
	for py = pyA, pyB do
		local syp = py + ky
		if flipY then syp = sh - 1 - syp end
		local segs = runs[syp + 1]
		local nSegs = #segs
		if nSegs == 0 then continue end
		local srow = syp * sw
		local drow = py * bw - kx
		if over then
			local s0, s1 = segs[1], segs[nSegs - 1]
			if s0 < sxA then s0 = sxA end
			if s1 > sxB then s1 = sxB end
			if s0 > s1 then continue end
			local n = s1 - s0 + 1
			local off = (drow + s0) * 4
			if readu32(buf, off) == ground then
				local flat = groundRows[n]
				if not flat then
					flat = srep(groundPixel, n)
					groundRows[n] = flat
				end
				if readstring(buf, off, n * 4) == flat then
					bcopy(buf, off, over, (srow + s0) * 4, n * 4)
					continue
				end
			end
		end
		for j = 1, nSegs, 3 do
			local s, e = segs[j], segs[j + 1]
			if s < sxA then s = sxA end
			if e > sxB then e = sxB end
			if s <= e then
				if segs[j + 2] == 1 then
					bcopy(buf, (drow + s) * 4, sbuf, (srow + s) * 4, (e - s + 1) * 4)
				else
					for sx = s, e do
						local src = readu32(sbuf, (srow + sx) * 4)
						local off = (drow + sx) * 4
						local dst = readu32(buf, off)
						if src ~= lastS or dst ~= lastD then
							lastS, lastD = src, dst
							local oa = (src // 16777216) % 256
							local ia = 255 - oa
							lastO = ((src % 256) * oa + (dst % 256) * ia) // 255
								+ (((src // 256) % 256 * oa + (dst // 256 % 256) * ia) // 255) * 256
								+ (((src // 65536) % 256 * oa + (dst // 65536 % 256) * ia) // 255) * 65536
								+ 0xFF000000
						end
						writeu32(buf, off, lastO)
					end
				end
			end
		end
	end
end

function Rasterizer:spriteEx(wx, wy, spriteId, scale, rot, tintR, tintG, tintB, alpha, flipX, flipY)
	local sprite = self.sprites[spriteId]
	if not sprite then return end
	if rot == 0 and scale == 1 and alpha == 255 and tintR == 255 and tintG == 255 and tintB == 255 and not flipX then
		blitPlain(self, sprite, wx - self.ox, wy - self.oy, flipY)
		return
	end
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
	mark(self, minX, minY, maxX, maxY)
	local tinted = tintR ~= 255 or tintG ~= 255 or tintB ~= 255
	local lastS, lastD, lastO = -1, -1, 0
	local cR, cG, cB, cA, cP = 0, 0, 0, 0, 0


	if maxX < minX or maxY < minY then return end
	local key, e, rows
	if (maxX - minX + 1) * (maxY - minY + 1) >= MEMO_MIN then
		key = spack("<ddddddddddddddddd", self.ox, self.oy, wx, wy, scale, rot, spriteId, tintR, tintG, tintB, alpha,
			flipX and 1 or 0, flipY and 1 or 0, cx0b, cy0b, cx1b, cy1b)
		e = memoSeen(self, key)
		if e ~= nil then
			local hit
			hit, rows = memoOpen(self, e, minX, minY, maxX, maxY)
			if hit then return end
		end
	end

	repeat
		if rot == 0 and not flipX then
			local nC = maxX - minX + 1
			local s, lastI = 0, 0
			for i = 1, nC do
				local sxp = floor((minX + i - 1 - cx) * invScale + halfW)
				if sxp >= 0 and sxp < sw then
					while s <= sxp do
						startCol[s + 1] = i
						s += 1
					end
					lastI = i
				end
			end
			while s <= sw do
				startCol[s + 1] = lastI + 1
				s += 1
			end
			local runs = spriteValues(sprite)
			for py = minY, maxY do
				local syp = floor((py - cy) * invScale + halfH)
				if flipY then syp = sh - 1 - syp end
				if syp >= 0 and syp < sh then
					local segs = runs[syp + 1]
					local base = (py * bw + minX - 1) * 4
					for j = 1, #segs, 3 do
						local i0 = startCol[segs[j] + 1]
						local i1 = startCol[segs[j + 1] + 2] - 1
						if i0 <= i1 then
							local src = segs[j + 2]
							if src ~= lastS then
								lastS, lastD = src, -1
								local sr, sg, sb = src % 256, (src // 256) % 256, (src // 65536) % 256
								local oa = (src // 16777216) % 256
								if tinted then
									sr = (sr * tintR) // 255
									sg = (sg * tintG) // 255
									sb = (sb * tintB) // 255
								end
								if alpha ~= 255 then oa = (oa * alpha) // 255 end
								cR, cG, cB, cA = sr, sg, sb, oa
								cP = sr + sg * 256 + sb * 65536 + 0xFF000000
							end
							local n = i1 - i0 + 1
							local off = base + i0 * 4
							if cA >= 255 then
								if n >= SPAN then
									bcopy(buf, off, colorRow(cP, n), 0, n * 4)
								else
									for _ = 1, n do
										writeu32(buf, off, cP)
										off += 4
									end
								end
							elseif cA > 0 then
								lastD, lastO = blendSpan(buf, off, n, cR * cA, cG * cA, cB * cA, 255 - cA, lastD, lastO)
							end
						end
					end
				end
			end
			break
		end

		for py = minY, maxY do
			local base = py * bw
			local dyc = py - cy
			for px = minX, maxX do
				local dxc = px - cx
				local sxp = floor((dxc * ca + dyc * sa) * invScale + halfW)
				local syp = floor((dyc * ca - dxc * sa) * invScale + halfH)
				if flipX then sxp = sw - 1 - sxp end
				if flipY then syp = sh - 1 - syp end
				if sxp >= 0 and sxp < sw and syp >= 0 and syp < sh then
					local src = readu32(sbuf, (syp * sw + sxp) * 4)
					if src > 0xFFFFFF then
						if src ~= lastS then
							lastS, lastD = src, -1
							local sr, sg, sb = src % 256, (src // 256) % 256, (src // 65536) % 256
							local oa = (src // 16777216) % 256
							if tinted then
								sr = (sr * tintR) // 255
								sg = (sg * tintG) // 255
								sb = (sb * tintB) // 255
							end
							if alpha ~= 255 then oa = (oa * alpha) // 255 end
							cR, cG, cB, cA = sr, sg, sb, oa
							cP = sr + sg * 256 + sb * 65536 + 0xFF000000
						end
						local off = (base + px) * 4
						if cA >= 255 then
							writeu32(buf, off, cP)
						elseif cA > 0 then
							local dst = readu32(buf, off)
							if dst ~= lastD then
								lastD = dst
								local ia = 255 - cA
								lastO = (cR * cA + (dst % 256) * ia) // 255
									+ ((cG * cA + (dst // 256 % 256) * ia) // 255) * 256
									+ ((cB * cA + (dst // 65536 % 256) * ia) // 255) * 65536
									+ 0xFF000000
							end
							writeu32(buf, off, lastO)
						end
					end
				end
			end
		end
	until true
	if rows then memoClose(self, key, e, minX, minY, maxX, maxY, rows) end
end

function Rasterizer:sprite(wx, wy, spriteId, flipX, flipY)
	local sprite = self.sprites[spriteId]
	if not sprite then return end
	if not flipX then
		blitPlain(self, sprite, wx + sprite.Width * 0.5 - self.ox, wy + sprite.Height * 0.5 - self.oy, flipY)
		return
	end
	self:spriteEx(wx + sprite.Width * 0.5, wy + sprite.Height * 0.5, spriteId,
		1, 0, 255, 255, 255, 255, flipX, flipY)
end

local strbyte = string.byte
local colS = table.create(2048, 0)
local colN = table.create(2048, 0)
local colO = table.create(2048, 0)
local colW = table.create(4096, 0)
local glyphCache = setmetatable({}, { __mode = "k" })

local function coverage(font, g, scale: number, invScale: number): buffer
	local byScale = glyphCache[font]
	if not byScale then
		byScale = { n = 0 }
		glyphCache[font] = byScale
	end
	local set = byScale[scale]
	if not set then
		if byScale.n >= GLYPH_SCALES then
			table.clear(byScale)
			byScale.n = 0
		end
		set = {}
		byScale[scale] = set
		byScale.n += 1
	end
	local cov = set[g]
	if cov then return cov end
	local atlas, aw = font.Buffer, font.Width
	local gx, gy = g.X, g.Y
	local gW, gH = g.W, g.H
	local dw, dh = floor(gW * scale), floor(gH * scale)
	cov = bcreate(max(1, dw * dh))
	local wIdx = 0
	for px = 0, dw - 1 do
		local fx0 = px * invScale
		local fx1 = fx0 + invScale
		if fx1 > gW then fx1 = gW end
		local sxA = floor(fx0)
		local sxB = ceil(fx1) - 1
		colS[px] = sxA
		colN[px] = sxB - sxA + 1
		colO[px] = wIdx
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
		local fy0 = py * invScale
		local fy1 = fy0 + invScale
		if fy1 > gH then fy1 = gH end
		local syA = floor(fy0)
		local syB = ceil(fy1) - 1
		local invArea = 1 / ((fy1 - fy0) * invScale)
		local crow = py * dw
		for px = 0, dw - 1 do
			local sxA, nS = colS[px], colN[px]
			local wCol = colO[px]
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
			writeu8(cov, crow + px, oa)
		end
	end
	set[g] = cov
	return cov
end

local memoD = table.create(256, -1)
local memoO = table.create(256, 0)
local memoTint = -1

local function textBox(self, wx: number, wy: number, str: string, font, scale: number): (number, number, number, number)
	local glyphs, space = font.Glyphs, font.SpaceAdvance
	local cx0b, cy0b, cx1b, cy1b = self.cx0, self.cy0, self.cx1, self.cy1
	local x0, y0, x1, y1 = HUGE, HUGE, -HUGE, -HUGE
	local penX = wx
	for i = 1, #str do
		local g = glyphs[strbyte(str, i)]
		if g then
			local ox = floor(penX + g.OX * scale - self.ox)
			local oy = floor(wy + g.OY * scale - self.oy)
			local dw, dh = floor(g.W * scale), floor(g.H * scale)
			local pxA = cx0b - ox
			if pxA < 0 then pxA = 0 end
			local pxB = cx1b - ox
			if pxB > dw - 1 then pxB = dw - 1 end
			local pyA = cy0b - oy
			if pyA < 0 then pyA = 0 end
			local pyB = cy1b - oy
			if pyB > dh - 1 then pyB = dh - 1 end
			if pxA <= pxB and pyA <= pyB then
				if ox + pxA < x0 then x0 = ox + pxA end
				if oy + pyA < y0 then y0 = oy + pyA end
				if ox + pxB > x1 then x1 = ox + pxB end
				if oy + pyB > y1 then y1 = oy + pyB end
			end
			penX += g.Adv * scale
		else
			penX += space * scale
		end
	end
	return x0, y0, x1, y1
end

function Rasterizer:text(wx, wy, str, fontId, scale, tr, tg, tb, alpha)
	local font = self.fonts[fontId]
	if not font or str == "" or scale <= 0 then return end
	local glyphs, space = font.Glyphs, font.SpaceAdvance
	local bw, buf = self.w, self.buf
	local cx0b, cy0b, cx1b, cy1b = self.cx0, self.cy0, self.cx1, self.cy1
	local key = spack("<dddddddddddddds4", self.ox, self.oy, wx, wy, fontId, scale, tr, tg, tb, alpha, cx0b, cy0b, cx1b, cy1b, str)
	local e = memoSeen(self, key)
	local rows, bx0, by0, bx1, by1
	if e ~= nil then
		if e then
			bx0, by0, bx1, by1 = e.x0, e.y0, e.x1, e.y1
		else
			bx0, by0, bx1, by1 = textBox(self, wx, wy, str, font, scale)
		end
		if bx0 <= bx1 and by0 <= by1 then
			local hit
			hit, rows = memoOpen(self, e, bx0, by0, bx1, by1)
			if hit then return end
		end
	end
	local invScale = 1 / scale
	local tint = tr + tg * 256 + tb * 65536
	if tint ~= memoTint then
		table.clear(memoD)
		memoTint = tint
	end
	local solid = tint + 0xFF000000
	local penX = wx
	for i = 1, #str do
		local g = glyphs[strbyte(str, i)]
		if g then
			local ox = floor(penX + g.OX * scale - self.ox)
			local oy = floor(wy + g.OY * scale - self.oy)
			local dw, dh = floor(g.W * scale), floor(g.H * scale)
			local pxA = cx0b - ox
			if pxA < 0 then pxA = 0 end
			local pxB = cx1b - ox
			if pxB > dw - 1 then pxB = dw - 1 end
			local pyA = cy0b - oy
			if pyA < 0 then pyA = 0 end
			local pyB = cy1b - oy
			if pyB > dh - 1 then pyB = dh - 1 end
			if pxA <= pxB and pyA <= pyB then
				mark(self, ox + pxA, oy + pyA, ox + pxB, oy + pyB)
				local cov = coverage(font, g, scale, invScale)
				for py = pyA, pyB do
					local base = (oy + py) * bw + ox
					local crow = py * dw
					for px = pxA, pxB do
						local oa = readu8(cov, crow + px)
						if oa > 0 then
							if alpha ~= 255 then oa = (oa * alpha) // 255 end
							if oa >= 255 then
								writeu32(buf, (base + px) * 4, solid)
							elseif oa > 0 then
								local off = (base + px) * 4
								local dst = readu32(buf, off)
								if memoD[oa] == dst then
									writeu32(buf, off, memoO[oa])
								else
									local ia = 255 - oa
									local out = (tr * oa + (dst % 256) * ia) // 255
										+ ((tg * oa + (dst // 256 % 256) * ia) // 255) * 256
										+ ((tb * oa + (dst // 65536 % 256) * ia) // 255) * 65536
										+ 0xFF000000
									memoD[oa], memoO[oa] = dst, out
									writeu32(buf, off, out)
								end
							end
						end
					end
				end
			end
			penX += g.Adv * scale
		else
			penX += space * scale
		end
	end
	if rows then memoClose(self, key, e, bx0, by0, bx1, by1, rows) end
end

return Rasterizer
