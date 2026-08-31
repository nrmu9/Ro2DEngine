--!optimize 2
--!native

-- Where a primitive can reach, in canvas pixels, for band routing. Every
-- bound must CONTAIN every pixel the rasteriser would paint: too generous
-- costs a wasted decode, too tight is a hole at a band seam. Inclusive and
-- unrounded; only ever compared against band rectangles.

local abs, cos, sin, sqrt = math.abs, math.cos, math.sin, math.sqrt

local DrawBounds = {}

-- Top-left anchored, exactly as the rasteriser reads it.
function DrawBounds.rect(x, y, w, h): (number, number, number, number)
	return x, y, x + w, y + h
end

-- Centre anchored. Half the diagonal covers the rectangle at every angle, which
-- is cheaper than projecting both axes and never smaller than the truth.
function DrawBounds.rectRot(cx, cy, w, h): (number, number, number, number)
	local r = sqrt(w * w + h * h) * 0.5 + 1
	return cx - r, cy - r, cx + r, cy + r
end

-- A square of `size` with its top-left at x, y. See CommandBuffer.beginPoints.
function DrawBounds.point(x, y, size): (number, number, number, number)
	return x, y, x + size, y + size
end

-- Top-left anchored, like Draw.Sprite itself.
function DrawBounds.sprite(x, y, w, h): (number, number, number, number)
	return x, y, x + w, y + h
end

-- Centre anchored and rotated: the rasteriser's own half-extent, plus a pixel
-- for the flooring at each end.
function DrawBounds.spriteEx(cx, cy, w, h, scale, rot): (number, number, number, number)
	local hw, hh = w * 0.5, h * 0.5
	local ca, sa = cos(rot), sin(rot)
	local ex = (abs(hw * ca) + abs(hh * sa)) * scale + 1
	local ey = (abs(hw * sa) + abs(hh * ca)) * scale + 1
	return cx - ex, cy - ey, cx + ex, cy + ey
end

-- Vertical reach of a string, unscaled font units, measured from the glyphs
-- actually used; the font's full height would hand every band nearly every
-- string.
function DrawBounds.textVSpan(s: string, font): (number, number)
	local glyphs = font.Glyphs
	local lo, hi, seen = 0, 0, false
	for i = 1, #s do
		local g = glyphs[string.byte(s, i)]
		if g then
			local top, bot = g.OY, g.OY + g.H
			if not seen then
				lo, hi, seen = top, bot, true
			else
				if top < lo then lo = top end
				if bot > hi then hi = bot end
			end
		end
	end
	return lo, hi
end

-- `width` is the measured advance at this scale; one unscaled em of slack
-- each end covers glyph offset and overhang without walking the offsets.
function DrawBounds.text(x, y, width, scale, vLo, vHi): (number, number, number, number)
	return x - scale, y + vLo * scale - 1, x + width + scale, y + vHi * scale + 1
end

return DrawBounds
