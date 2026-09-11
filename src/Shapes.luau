--!optimize 2
--!native

local floor, min, max, sqrt, clamp = math.floor, math.min, math.max, math.sqrt, math.clamp

local Shapes = {}

function Shapes.line(plot, x0: number, y0: number, x1: number, y1: number,
	thickness: number, r: number, g: number, b: number)
	local halfThick = thickness * 0.5
	local dx, dy = x1 - x0, y1 - y0
	local lenSq = dx * dx + dy * dy
	local invLenSq = if lenSq > 0 then 1 / lenSq else 0

	local minX = floor(min(x0, x1) - halfThick - 1)
	local maxX = floor(max(x0, x1) + halfThick + 1)
	local minY = floor(min(y0, y1) - halfThick - 1)
	local maxY = floor(max(y0, y1) + halfThick + 1)
	local edge = halfThick + 1

	for py = minY, maxY do
		for px = minX, maxX do
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
	r: number, g: number, b: number, a: number?)
	if radius <= 0 then return end
	a = a or 255
	local startX, startY = floor(cx - radius - 1), floor(cy - radius - 1)
	local endX, endY = floor(cx + radius + 1), floor(cy + radius + 1)

	for py = startY, endY do
		local dy = py - cy
		local dySq = dy * dy
		for px = startX, endX do
			local dx = px - cx
			local dist = sqrt(dx * dx + dySq)
			local coverage = radius - dist + 0.5
			if coverage > 0 then
				local pa = if coverage >= 1 then a else floor(a * coverage)
				if pa > 0 then plot(px, py, r, g, b, pa) end
			end
		end
	end
end

return Shapes
