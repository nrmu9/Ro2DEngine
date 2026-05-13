local Physics = require(script.Parent:WaitForChild("Physics"))

local World = {
	ActiveEntities = {},
	StaticHitboxes = {}
}

function World.Spawn(x: number, y: number, sprite: any)
	local entity = {
		X = x, Y = y,
		VelocityX = 0, VelocityY = 0,
		Sprite = sprite,
		FlipX = false, FlipY = false,
		Visible = true, _isDead = false
	}
	function entity:Destroy() self._isDead = true end
	table.insert(World.ActiveEntities, entity)
	return entity
end

function World.AddHitbox(x: number, y: number, w: number, h: number)
	local box = { X = x, Y = y, Width = w, Height = h }
	table.insert(World.StaticHitboxes, box)
	return box
end

function World.UpdateAll(dt: number)
	for i = #World.ActiveEntities, 1, -1 do
		local ent = World.ActiveEntities[i]
		if ent._isDead then
			table.remove(World.ActiveEntities, i)
			continue
		end

		if ent.OnUpdate then ent:OnUpdate(dt) end

		if ent.PhysicsMode == "Radial" and ent.RadialTarget then
			Physics.UpdateRadialEntity(ent, ent.RadialTarget.X, ent.RadialTarget.Y, ent.RadialTarget.Radius, dt)
		elseif ent.VelocityX ~= nil and not ent.PhysicsMode then
			Physics.UpdateEntity(ent, dt, World.StaticHitboxes)
		end
	end
end

function World.DrawAll(drawSpriteFunc)
	for i = 1, #World.ActiveEntities do
		local ent = World.ActiveEntities[i]
		if not ent.Visible then continue end

		if ent.OnDraw then
			ent:OnDraw()
		elseif ent.Sprite then
			drawSpriteFunc(ent.X, ent.Y, ent.Sprite, ent.FlipX, ent.FlipY)
		end
	end
end

function World.Clear()
	table.clear(World.ActiveEntities)
	table.clear(World.StaticHitboxes)
end

return World