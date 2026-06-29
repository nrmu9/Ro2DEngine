--!optimize 2
--!native
-- Ro2D :: Physics
-- Stateless AABB + radial solvers. Functions mutate the entity passed in.

export type Hitbox = {
	X: number,
	Y: number,
	Width: number,
	Height: number,
}

export type PhysicsEntity = {
	X: number,
	Y: number,
	VelocityX: number?,
	VelocityY: number?,
	Gravity: number?,
	HitboxWidth: number?,
	HitboxHeight: number?,
	HitboxRadius: number?,
	IsGrounded: boolean?,
	FlipX: boolean?,
	Sprite: any?,
}

local sqrt = math.sqrt

local Physics = {
	Gravity = 900,
}

function Physics.CheckAABB(x1: number, y1: number, w1: number, h1: number, x2: number, y2: number, w2: number, h2: number): boolean
	return x1 < x2 + w2
		and x1 + w1 > x2
		and y1 < y2 + h2
		and y1 + h1 > y2
end

function Physics.GetDistance(x1: number, y1: number, x2: number, y2: number): (number, number, number)
	local dx = x2 - x1
	local dy = y2 - y1
	return sqrt(dx * dx + dy * dy), dx, dy
end

function Physics.UpdateRadialEntity(entity: PhysicsEntity, targetX: number, targetY: number, targetRadius: number, dt: number)
	local dx = targetX - entity.X
	local dy = targetY - entity.Y
	local dist = sqrt(dx * dx + dy * dy)
	if dist == 0 then return end -- coincident with target; no defined direction

	local invDist = 1 / dist
	local dirX, dirY = dx * invDist, dy * invDist
	local contact = targetRadius + (entity.HitboxRadius or 0)

	if dist <= contact then
		entity.VelocityX = 0
		entity.VelocityY = 0
		entity.IsGrounded = true

		local overlap = contact - dist
		entity.X -= dirX * overlap
		entity.Y -= dirY * overlap
		return
	end

	local appliedGravity = entity.Gravity or Physics.Gravity
	local vx = entity.VelocityX or 0
	local vy = entity.VelocityY or 0
	if appliedGravity ~= 0 then
		vx += dirX * appliedGravity * dt
		vy += dirY * appliedGravity * dt
	end

	entity.VelocityX = vx
	entity.VelocityY = vy
	entity.X += vx * dt
	entity.Y += vy * dt
	entity.IsGrounded = false
end

function Physics.UpdateEntity(entity: PhysicsEntity, dt: number, hitboxes: { Hitbox })
	local sprite = entity.Sprite
	local appliedGravity = entity.Gravity or Physics.Gravity

	local velX = entity.VelocityX or 0
	local velY = (entity.VelocityY or 0) + appliedGravity * dt
	entity.VelocityY = velY

	local w = entity.HitboxWidth or (sprite and sprite.HitboxWidth) or 0
	local h = entity.HitboxHeight or (sprite and sprite.HitboxHeight) or 0

	local offX = 0
	if sprite and sprite.HitboxOffsetX then
		offX = if entity.FlipX then (sprite.Width - sprite.HitboxMaxX - 1) else sprite.HitboxOffsetX
	end
	local offY = (sprite and sprite.HitboxOffsetY) or 0

	local count = #hitboxes
	entity.IsGrounded = false

	-- Horizontal sweep
	if velX ~= 0 then
		local trueX = entity.X + offX
		local trueY = entity.Y + offY
		local nextTrueX = trueX + velX * dt
		local collided = false

		for i = 1, count do
			local box = hitboxes[i]
			if Physics.CheckAABB(nextTrueX, trueY, w, h, box.X, box.Y, box.Width, box.Height) then
				collided = true
				if velX > 0 then
					entity.X = box.X - w - offX
				else
					entity.X = box.X + box.Width - offX
				end
				entity.VelocityX = 0
				break
			end
		end

		if not collided then entity.X += velX * dt end
	end

	-- Vertical sweep (recompute X-derived position after the horizontal step)
	if velY ~= 0 then
		local trueX = entity.X + offX
		local trueY = entity.Y + offY
		local nextTrueY = trueY + velY * dt
		local collided = false

		for i = 1, count do
			local box = hitboxes[i]
			if Physics.CheckAABB(trueX, nextTrueY, w, h, box.X, box.Y, box.Width, box.Height) then
				collided = true
				if velY > 0 then
					entity.Y = box.Y - h - offY
					entity.IsGrounded = true
				else
					entity.Y = box.Y + box.Height - offY
				end
				entity.VelocityY = 0
				break
			end
		end

		if not collided then entity.Y += velY * dt end
	end
end

return Physics
