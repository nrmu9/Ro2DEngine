local Assets = {}

function Assets.LoadSprite(spriteModule: ModuleScript)
	local data = require(spriteModule)
	local memBuffer = buffer.fromstring(data.Data)
	local w = data.Width
	local h = data.Height

	local rowBounds = {}
	local isEmpty = true

	local globalMinX, globalMaxX = w, -1
	local globalMinY, globalMaxY = h, -1

	for y = 0, h - 1 do
		local minX = -1
		local maxX = -1
		local rowOffset = (y * w) * 4

		for x = 0, w - 1 do
			local alpha = buffer.readu8(memBuffer, rowOffset + (x * 4) + 3)
			if alpha > 0 then
				if minX == -1 then minX = x end
				maxX = x
			end
		end

		rowBounds[y] = { MinX = minX, MaxX = maxX }

		if minX ~= -1 then 
			isEmpty = false 
			if minX < globalMinX then globalMinX = minX end
			if maxX > globalMaxX then globalMaxX = maxX end
			if globalMinY == h then globalMinY = y end
			globalMaxY = y
		end
	end

	return {
		Width = w,
		Height = h,
		Buffer = memBuffer,
		RowBounds = rowBounds,
		IsEmpty = isEmpty,

		HitboxWidth = isEmpty and 0 or (globalMaxX - globalMinX + 1),
		HitboxHeight = isEmpty and 0 or (globalMaxY - globalMinY + 1),
		HitboxOffsetX = isEmpty and 0 or globalMinX,
		HitboxOffsetY = isEmpty and 0 or globalMinY,
		HitboxMaxX = isEmpty and 0 or globalMaxX
	}
end

return Assets