--!optimize 2
--!native
-- Ro2D :: Assets
-- Decodes png2lua-compiled sprite modules into GPU-ready RGBA buffers, precomputing
-- per-row opaque bounds so the renderer can skip transparent pixels at draw time.

local readu32 = buffer.readu32
local fromstring = buffer.fromstring

local Assets = {}

local cache = setmetatable({}, { __mode = "k" }) -- weak keys: module -> Sprite

function Assets.LoadSprite(spriteModule: ModuleScript)
	local cached = cache[spriteModule]
	if cached then return cached end

	local data = require(spriteModule) :: any
	local buf = fromstring(data.Data)
	local w, h = data.Width, data.Height

	local rowBounds = table.create(h)
	local isEmpty = true
	local solidRows = true -- true iff no row has interior transparent pixels
	local gMinX, gMaxX = w, -1
	local gMinY, gMaxY = h, -1

	for y = 0, h - 1 do
		local rowOffset = y * w * 4
		local minX, maxX = -1, -1

		-- Scan inward from both ends; stop as soon as an opaque pixel is found.
		-- A pixel's alpha is the high byte of its little-endian u32, so
		-- (value > 0xFFFFFF) is true iff alpha > 0.
		for x = 0, w - 1 do
			if readu32(buf, rowOffset + x * 4) > 0xFFFFFF then
				minX = x
				break
			end
		end

		if minX ~= -1 then
			for x = w - 1, minX, -1 do
				if readu32(buf, rowOffset + x * 4) > 0xFFFFFF then
					maxX = x
					break
				end
			end

			isEmpty = false
			if minX < gMinX then gMinX = minX end
			if maxX > gMaxX then gMaxX = maxX end
			if gMinY == h then gMinY = y end
			gMaxY = y

			-- If every pixel in [minX, maxX] is opaque, this row is one solid run
			-- and the renderer can blit it with a single buffer.copy. One hole
			-- anywhere disqualifies the whole sprite from the fast span path.
			if solidRows then
				for x = minX + 1, maxX - 1 do
					if readu32(buf, rowOffset + x * 4) <= 0xFFFFFF then
						solidRows = false
						break
					end
				end
			end
		end

		rowBounds[y] = { MinX = minX, MaxX = maxX }
	end

	local sprite = {
		Width = w,
		Height = h,
		Buffer = buf,
		RowBounds = rowBounds,
		IsEmpty = isEmpty,
		SolidRows = solidRows,

		HitboxWidth = if isEmpty then 0 else (gMaxX - gMinX + 1),
		HitboxHeight = if isEmpty then 0 else (gMaxY - gMinY + 1),
		HitboxOffsetX = if isEmpty then 0 else gMinX,
		HitboxOffsetY = if isEmpty then 0 else gMinY,
		HitboxMaxX = if isEmpty then 0 else gMaxX,
	}

	cache[spriteModule] = sprite
	return sprite
end

return Assets
