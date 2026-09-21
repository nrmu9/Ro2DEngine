--!optimize 2
--!native

local floor, ceil, min, max, sqrt, clamp, abs = math.floor, math.ceil, math.min, math.max, math.sqrt, math.clamp, math.abs
local HUGE = math.huge

local Shapes = {}

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
