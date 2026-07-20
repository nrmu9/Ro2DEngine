--!optimize 2
--!native

local readu32 = buffer.readu32
local fromstring = buffer.fromstring

local Assets = {}

local cache = setmetatable({}, { __mode = "k" })
local fontCache = setmetatable({}, { __mode = "k" })

function Assets.LoadSprite(spriteModule: ModuleScript)
	local cached = cache[spriteModule]
	if cached then return cached end

	local data = require(spriteModule) :: any
	local buf = fromstring(data.Data)
	local w, h = data.Width, data.Height

	local rowBounds = table.create(h)
	local isEmpty = true
	local solidRows = true
	local gMinX, gMaxX = w, -1
	local gMinY, gMaxY = h, -1

	for y = 0, h - 1 do
		local rowOffset = y * w * 4
		local minX, maxX = -1, -1

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

function Assets.LoadFont(fontModule: ModuleScript)
	local cached = fontCache[fontModule]
	if cached then return cached end

	local data = require(fontModule) :: any
	local font = {
		Name = data.Name,
		Buffer = fromstring(data.Data),
		Width = data.Width,
		Height = data.Height,
		LineHeight = data.LineHeight,
		Ascent = data.Ascent,
		CapCenter = data.CapCenter,
		SpaceAdvance = data.SpaceAdvance,
		Glyphs = data.Glyphs,
	}
	fontCache[fontModule] = font
	return font
end

return Assets
