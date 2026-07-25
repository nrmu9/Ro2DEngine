--!optimize 2
--!native

local Physics = require(script.Parent:WaitForChild("Physics"))

local World = {
	ActiveEntities = {},
	StaticHitboxes = {},
}

local function destroyEntity(self)
	self._isDead = true
end

function World.Spawn(x: number, y: number, sprite: any?)
	local entity = {
		X = x, Y = y,
		VelocityX = 0, VelocityY = 0,
		Sprite = sprite,
		FlipX = false, FlipY = false,
		Visible = true,
		_isDead = false,
		Destroy = destroyEntity,
	}
	table.insert(World.ActiveEntities, entity)
	return entity
end

function World.AddHitbox(x: number, y: number, w: number, h: number)
	local box = { X = x, Y = y, Width = w, Height = h }
	table.insert(World.StaticHitboxes, box)
	return box
end

function World.UpdateAll(dt: number)
	local entities = World.ActiveEntities
	local hitboxes = World.StaticHitboxes

	for i = #entities, 1, -1 do
		local ent = entities[i]
		if ent._isDead then
			table.remove(entities, i)
			continue
		end

		if ent.OnUpdate then ent:OnUpdate(dt) end

		local mode = ent.PhysicsMode
		if mode == "Radial" then
			local target = ent.RadialTarget
			if target then
				Physics.UpdateRadialEntity(ent, target.X, target.Y, target.Radius, dt)
			end
		elseif mode == nil and ent.VelocityX ~= nil then
			Physics.UpdateEntity(ent, dt, hitboxes)
		end
	end
end

function World.DrawAll(drawSpriteFunc)
	local entities = World.ActiveEntities
	for i = 1, #entities do
		local ent = entities[i]
		if ent.Visible then
			if ent.OnDraw then
				ent:OnDraw()
			elseif ent.Sprite then
				drawSpriteFunc(ent.X, ent.Y, ent.Sprite, ent.FlipX, ent.FlipY)
			end
		end
	end
end

function World.Clear()
	table.clear(World.ActiveEntities)
	table.clear(World.StaticHitboxes)
end

return World
