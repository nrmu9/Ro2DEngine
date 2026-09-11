--!optimize 2
--!native

local abs, cos, sin, sqrt = math.abs, math.cos, math.sin, math.sqrt

local DrawBounds = {}

function DrawBounds.rect(x, y, w, h): (number, number, number, number)
	return x, y, x + w, y + h
end

function DrawBounds.rectRot(cx, cy, w, h): (number, number, number, number)
	local r = sqrt(w * w + h * h) * 0.5 + 1
	return cx - r, cy - r, cx + r, cy + r
end

function DrawBounds.point(x, y, size): (number, number, number, number)
	return x, y, x + size, y + size
end

function DrawBounds.sprite(x, y, w, h): (number, number, number, number)
	return x, y, x + w, y + h
end

function DrawBounds.spriteEx(cx, cy, w, h, scale, rot): (number, number, number, number)
	local hw, hh = w * 0.5, h * 0.5
	local ca, sa = cos(rot), sin(rot)
	local ex = (abs(hw * ca) + abs(hh * sa)) * scale + 1
	local ey = (abs(hw * sa) + abs(hh * ca)) * scale + 1
	return cx - ex, cy - ey, cx + ex, cy + ey
end

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

function DrawBounds.text(x, y, width, scale, vLo, vHi): (number, number, number, number)
	return x - scale, y + vLo * scale - 1, x + width + scale, y + vHi * scale + 1
end

return DrawBounds
