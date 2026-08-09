--!optimize 2
--!native

-- Where a primitive can reach, in canvas pixels, so the parallel renderer can
-- decide which bands need to be told about it.
--
-- Separate from the renderer because the correctness condition is not obvious and
-- is worth testing directly: every bound here must CONTAIN every pixel the
-- rasteriser would paint. Too generous only costs a band a decode that paints
-- nothing. Too tight is a hole in the picture along a band seam, and one that
-- appears for some rotations and some strings and not others -- so the suite
-- checks each of these against the pixels the real rasteriser actually writes,
-- over a spread of angles, scales and sizes.
--
-- Bounds are inclusive and are not rounded to integers; the caller only compares
-- them against band rectangles.

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

-- Centre anchored and rotated. The same half-extent the rasteriser derives, so
-- the two cannot disagree about how far a turned sprite reaches, plus a pixel for
-- the flooring at each end.
function DrawBounds.spriteEx(cx, cy, w, h, scale, rot): (number, number, number, number)
	local hw, hh = w * 0.5, h * 0.5
	local ca, sa = cos(rot), sin(rot)
	local ex = (abs(hw * ca) + abs(hh * sa)) * scale + 1
	local ey = (abs(hw * sa) + abs(hh * ca)) * scale + 1
	return cx - ex, cy - ey, cx + ex, cy + ey
end

-- The vertical reach of a string, in unscaled font units, from the glyphs it
-- actually uses.
--
-- Measured rather than taken from the font, because a line of digits and a line
-- with a descender do not occupy the same rows -- and a bound taken from the
-- font's full height would hand nearly every strip of the canvas nearly every
-- string on it, which is most of what this exercise is trying to stop.
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

-- `width` is the measured advance of the string at this scale. A glyph is placed
-- at penX + OX, so the first can start slightly left of the pen and the last can
-- overhang its advance; one unscaled em of slack at each end covers both without
-- walking the offsets again.
function DrawBounds.text(x, y, width, scale, vLo, vHi): (number, number, number, number)
	return x - scale, y + vLo * scale - 1, x + width + scale, y + vHi * scale + 1
end

return DrawBounds
