--!optimize 2
--!native

local floor, ceil, min, max, sqrt, clamp, abs = math.floor, math.ceil, math.min, math.max, math.sqrt, math.clamp, math.abs
local HUGE = math.huge
local readf32 = buffer.readf32
local sort = table.sort

local Shapes = {}

local acc, seen, touched = {}, {}, {}
local nTouched, stamp = 0, 0
local edgeYa, edgeYb, edgeXa, edgeDx, edgeDir, order, active = {}, {}, {}, {}, {}, {}, {}
local clipL, clipR = 0, 0

local function add(i: number, v: number)
	if i > clipR then return end
	if i < clipL then i = clipL end
	if seen[i] ~= stamp then
		seen[i] = stamp
		acc[i] = v
		nTouched += 1
		touched[nTouched] = i
	else
		acc[i] += v
	end
end

local function deposit(x: number, xnext: number, d: number)
	local x0, x1 = x, xnext
	if x0 > x1 then x0, x1 = x1, x0 end
	local x0i = floor(x0)
	local x1i = ceil(x1)
	if x1i <= x0i + 1 then
		local xmf = 0.5 * (x + xnext) - x0i
		add(x0i, d - d * xmf)
		add(x0i + 1, d * xmf)
		return
	end
	local s = 1 / (x1 - x0)
	local x0f = x0 - x0i
	local a0 = 0.5 * s * (1 - x0f) * (1 - x0f)
	local x1f = x1 - x1i + 1
	local am = 0.5 * s * x1f * x1f
	add(x0i, d * a0)
	if x1i == x0i + 2 then
		add(x0i + 1, d * (1 - a0 - am))
	else
		local a1 = s * (1.5 - x0f)
		add(x0i + 1, d * (a1 - a0))
		local ds = d * s
		for xi = x0i + 2, x1i - 2 do add(xi, ds) end
		local a2 = a1 + (x1i - x0i - 3) * s
		add(x1i - 1, d * (1 - a2 - am))
	end
	add(x1i, d * am)
end

local function depositClipped(x0: number, x1: number, d: number)
	local lo, hi = x0, x1
	if lo > hi then lo, hi = hi, lo end
	local right = clipR + 1
	if hi <= clipL then
		add(clipL, d)
		return
	end
	if lo >= right then return end
	if lo >= clipL and hi <= right then
		deposit(x0, x1, d)
		return
	end
	local span = x1 - x0
	local tl, tr = (clipL - x0) / span, (right - x0) / span
	local t0, t1 = min(tl, tr), max(tl, tr)
	if t0 < 0 then t0 = 0 end
	if t1 > 1 then t1 = 1 end
	if span > 0 then
		if t0 > 0 then add(clipL, d * t0) end
	elseif t1 < 1 then
		add(clipL, d * (1 - t1))
	end
	if t1 > t0 then deposit(x0 + span * t0, x0 + span * t1, d * (t1 - t0)) end
end

local function byTop(a: number, b: number): boolean
	return edgeYa[a] < edgeYa[b]
end

function Shapes.polygon(src: buffer, off: number, n: number, dx: number, dy: number,
	cx0: number, cy0: number, cx1: number, cy1: number, alpha: number, run, pixel)
	if n < 3 or cx1 < cx0 or cy1 < cy0 or alpha <= 0 then return end
	local ne = 0
	local ymin, ymax = HUGE, -HUGE
	local last = off + (n - 1) * 8
	local px, py = readf32(src, last) + dx, readf32(src, last + 4) + dy
	for k = 0, n - 1 do
		local at = off + k * 8
		local qx, qy = readf32(src, at) + dx, readf32(src, at + 4) + dy
		if qx ~= qx or qy ~= qy or abs(qx) == HUGE or abs(qy) == HUGE then return end
		if qy ~= py then
			ne += 1
			if py < qy then
				edgeYa[ne], edgeYb[ne], edgeXa[ne], edgeDir[ne] = py, qy, px, 1
			else
				edgeYa[ne], edgeYb[ne], edgeXa[ne], edgeDir[ne] = qy, py, qx, -1
			end
			edgeDx[ne] = (qx - px) / (qy - py)
			order[ne] = ne
		end
		if qy < ymin then ymin = qy end
		if qy > ymax then ymax = qy end
		px, py = qx, qy
	end
	if ne < 2 then return end
	local row0 = max(floor(ymin), cy0)
	local row1 = min(ceil(ymax) - 1, cy1)
	if row1 < row0 then return end
	for k = ne + 1, #order do order[k] = nil end
	sort(order, byTop)
	clipL, clipR = cx0, cx1
	local nActive, nextEdge = 0, 1
	for y = row0, row1 do
		local bottom = y + 1
		local keep = 0
		for k = 1, nActive do
			local e = active[k]
			if edgeYb[e] > y then
				keep += 1
				active[keep] = e
			end
		end
		nActive = keep
		while nextEdge <= ne and edgeYa[order[nextEdge]] < bottom do
			local e = order[nextEdge]
			if edgeYb[e] > y then
				nActive += 1
				active[nActive] = e
			end
			nextEdge += 1
		end
		if nActive > 0 then
			stamp += 1
			nTouched = 0
			for k = 1, nActive do
				local e = active[k]
				local ya, slope = edgeYa[e], edgeDx[e]
				local ys = if ya > y then ya else y
				local yb = edgeYb[e]
				local ye = if yb < bottom then yb else bottom
				if ye > ys then
					local xa = edgeXa[e]
					depositClipped(xa + (ys - ya) * slope, xa + (ye - ya) * slope, (ye - ys) * edgeDir[e])
				end
			end
			if nTouched > 0 then
				sort(touched)
				local sum, at = 0, cx0
				for k = 1, nTouched do
					local t = touched[k]
					if t > at then
						local c = abs(sum)
						if c > 0.002 then
							local pa = if c >= 0.998 then alpha else floor(alpha * c + 0.5)
							if pa > 0 then run(at, t - 1, y, pa) end
						end
					end
					sum += acc[t]
					local c = abs(sum)
					if c > 0.002 then
						local pa = if c >= 0.998 then alpha else floor(alpha * c + 0.5)
						if pa > 0 then pixel(t, y, pa) end
					end
					at = t + 1
				end
				if at <= cx1 then
					local c = abs(sum)
					if c > 0.002 then
						local pa = if c >= 0.998 then alpha else floor(alpha * c + 0.5)
						if pa > 0 then run(at, cx1, y, pa) end
					end
				end
				for k = nTouched, 1, -1 do touched[k] = nil end
			end
		end
	end
end

function Shapes.line(plot, x0: number, y0: number, x1: number, y1: number,
	thickness: number, r: number, g: number, b: number,
	clipX0: number?, clipY0: number?, clipX1: number?, clipY1: number?)
	local halfThick = thickness * 0.5
	local dx, dy = x1 - x0, y1 - y0
	local lenSq = dx * dx + dy * dy
	local invLenSq = if lenSq > 0 then 1 / lenSq else 0
	local edge = halfThick + 1

	local minX = floor(min(x0, x1) - halfThick - 1)
	local maxX = floor(max(x0, x1) + halfThick + 1)
	local minY = floor(min(y0, y1) - halfThick - 1)
	local maxY = floor(max(y0, y1) + halfThick + 1)
	if clipX0 and minX < clipX0 then minX = clipX0 end
	if clipY0 and minY < clipY0 then minY = clipY0 end
	if clipX1 and maxX > clipX1 then maxX = clipX1 end
	if clipY1 and maxY > clipY1 then maxY = clipY1 end
	if minX > maxX or minY > maxY then return end

	local steep = abs(dy) > 1e-6
	local reach = if steep then edge * sqrt(lenSq) / abs(dy) + 1 else HUGE
	local slope = if steep then dx / dy else 0

	for py = minY, maxY do
		local rowX0, rowX1 = minX, maxX
		if steep then
			local xc = x0 + (py - y0) * slope
			local lo, hi = floor(xc - reach), ceil(xc + reach)
			if lo > rowX0 then rowX0 = lo end
			if hi < rowX1 then rowX1 = hi end
		end
		for px = rowX0, rowX1 do
			local t = clamp(((px - x0) * dx + (py - y0) * dy) * invLenSq, 0, 1)
			local ex = px - (x0 + t * dx)
			local ey = py - (y0 + t * dy)
			local dist = sqrt(ex * ex + ey * ey)
			if dist <= edge then
				local a = 255
				if dist > halfThick then a = floor(255 * (1 - (dist - halfThick))) end
				if a > 5 then plot(px, py, r, g, b, a) end
			end
		end
	end
end

function Shapes.circle(plot, cx: number, cy: number, radius: number,
	r: number, g: number, b: number, a: number?,
	clipX0: number?, clipY0: number?, clipX1: number?, clipY1: number?, span)
	if radius <= 0 then return end
	local alpha = a or 255
	local startX, startY = floor(cx - radius - 1), floor(cy - radius - 1)
	local endX, endY = floor(cx + radius + 1), floor(cy + radius + 1)
	if clipX0 and startX < clipX0 then startX = clipX0 end
	if clipY0 and startY < clipY0 then startY = clipY0 end
	if clipX1 and endX > clipX1 then endX = clipX1 end
	if clipY1 and endY > clipY1 then endY = clipY1 end
	if startX > endX or startY > endY then return end

	local outer = radius + 0.5
	local outerSq = outer * outer
	local solid = radius - 0.5
	local solidSq = if solid > 0 then solid * solid else -1

	for py = startY, endY do
		local dy = py - cy
		local dySq = dy * dy
		if dySq < outerSq then
			local reach = sqrt(outerSq - dySq)
			local rowX0, rowX1 = floor(cx - reach), ceil(cx + reach)
			if rowX0 < startX then rowX0 = startX end
			if rowX1 > endX then rowX1 = endX end

			local inX0, inX1 = rowX1 + 1, rowX1
			if dySq <= solidSq then
				local half = sqrt(solidSq - dySq)
				local sx0, sx1 = ceil(cx - half), floor(cx + half)
				if sx0 < rowX0 then sx0 = rowX0 end
				if sx1 > rowX1 then sx1 = rowX1 end
				if sx0 <= sx1 then
					inX0, inX1 = sx0, sx1
					if span then
						span(sx0, sx1, py, r, g, b, alpha)
					else
						for px = sx0, sx1 do plot(px, py, r, g, b, alpha) end
					end
				end
			end

			for px = rowX0, min(inX0 - 1, rowX1) do
				local ddx = px - cx
				local coverage = radius - sqrt(ddx * ddx + dySq) + 0.5
				if coverage > 0 then
					local pa = if coverage >= 1 then alpha else floor(alpha * coverage)
					if pa > 0 then plot(px, py, r, g, b, pa) end
				end
			end
			for px = max(inX1 + 1, rowX0), rowX1 do
				local ddx = px - cx
				local coverage = radius - sqrt(ddx * ddx + dySq) + 0.5
				if coverage > 0 then
					local pa = if coverage >= 1 then alpha else floor(alpha * coverage)
					if pa > 0 then plot(px, py, r, g, b, pa) end
				end
			end
		end
	end
end

return Shapes
