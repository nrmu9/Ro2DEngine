export type Hitbox = {
	X: number,
	Y: number,
	Width: number,
	Height: number
}

export type PhysicsEntity = {
	X: number,
	Y: number,
	VelocityX: number?,
	VelocityY: number?,
	Gravity: number?,
	HitboxWidth: number?,
	HitboxHeight: number?,
	IsGrounded: boolean?,
	Sprite: { Width: number, Height: number }? 
}

local Physics = {
	Gravity = 900
}

function Physics.CheckAABB(x1: number, y1: number, w1: number, h1: number, x2: number, y2: number, w2: number, h2: number): boolean
	return x1 < x2 + w2 and
		x1 + w1 > x2 and
		y1 < y2 + h2 and
		y1 + h1 > y2
end

function Physics.GetDistance(x1: number, y1: number, x2: number, y2: number): (number, number, number)
	local dx = x2 - x1
	local dy = y2 - y1
	return math.sqrt((dx * dx) + (dy * dy)), dx, dy
end

function Physics.UpdateRadialEntity(entity: PhysicsEntity, targetX: number, targetY: number, targetRadius: number, dt: number)
	local dist, dx, dy = Physics.GetDistance(entity.X, entity.Y, targetX, targetY)
	local hitboxRad = entity.HitboxRadius or 0

	if dist <= targetRadius + hitboxRad then
		entity.VelocityX = 0
		entity.VelocityY = 0
		entity.IsGrounded = true

		local overlap = (targetRadius + hitboxRad) - dist
		local dirX, dirY = dx / dist, dy / dist
		entity.X = entity.X - (dirX * overlap)
		entity.Y = entity.Y - (dirY * overlap)
		return
	end

	local appliedGravity = entity.Gravity or Physics.Gravity
	if appliedGravity ~= 0 then
		local dirX = dx / dist
		local dirY = dy / dist
		entity.VelocityX = (entity.VelocityX or 0) + (dirX * appliedGravity) * dt
		entity.VelocityY = (entity.VelocityY or 0) + (dirY * appliedGravity) * dt
	end

	entity.X = entity.X + (entity.VelocityX * dt)
	entity.Y = entity.Y + (entity.VelocityY * dt)
	entity.IsGrounded = false
end

function Physics.UpdateEntity(entity: PhysicsEntity, dt: number, hitboxes: {Hitbox})
	local appliedGravity = entity.Gravity or Physics.Gravity
	entity.VelocityY = (entity.VelocityY or 0) + (appliedGravity * dt)

	local velX = entity.VelocityX or 0
	local velY = entity.VelocityY or 0

	local w = entity.HitboxWidth or (entity.Sprite and entity.Sprite.HitboxWidth) or 0
	local h = entity.HitboxHeight or (entity.Sprite and entity.Sprite.HitboxHeight) or 0

	local offX = 0
	if entity.Sprite and entity.Sprite.HitboxOffsetX then
		if entity.FlipX then
			offX = entity.Sprite.Width - entity.Sprite.HitboxMaxX - 1
		else
			offX = entity.Sprite.HitboxOffsetX
		end
	end
	local offY = (entity.Sprite and entity.Sprite.HitboxOffsetY) or 0

	local trueX = entity.X + offX
	local trueY = entity.Y + offY

	entity.IsGrounded = false

	if velX ~= 0 then
		local nextTrueX = trueX + (velX * dt)
		local collidedX = false

		for i = 1, #hitboxes do
			local box = hitboxes[i]
			if Physics.CheckAABB(nextTrueX, trueY, w, h, box.X, box.Y, box.Width, box.Height) then
				collidedX = true
				if velX > 0 then 
					entity.X = box.X - w - offX
				elseif velX < 0 then 
					entity.X = box.X + box.Width - offX
				end
				entity.VelocityX = 0
				break
			end
		end

		if not collidedX then entity.X = entity.X + (velX * dt) end
	end

	trueX = entity.X + offX

	if velY ~= 0 then
		local nextTrueY = trueY + (velY * dt)
		local collidedY = false

		for i = 1, #hitboxes do
			local box = hitboxes[i]
			if Physics.CheckAABB(trueX, nextTrueY, w, h, box.X, box.Y, box.Width, box.Height) then
				collidedY = true
				if velY > 0 then 
					entity.Y = box.Y - h - offY
					entity.IsGrounded = true
				elseif velY < 0 then 
					entity.Y = box.Y + box.Height - offY
				end
				entity.VelocityY = 0
				break
			end
		end

		if not collidedY then entity.Y = entity.Y + (velY * dt) end
	end
end

return Physics