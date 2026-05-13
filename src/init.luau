local Core = script.Parent.Parent:WaitForChild("Core")

local Renderer = require(Core:WaitForChild("Renderer"))
local Assets = require(Core:WaitForChild("Assets"))
local World = require(Core:WaitForChild("World"))
local Input = require(Core:WaitForChild("Input"))
local UI = require(Core:WaitForChild("UI"))
local Physics = require(Core:WaitForChild("Physics"))

-- =======================================
-- ENGINE TYPES
-- =======================================
export type EngineConfig = {
	Isolate2D: boolean?,
	RenderScale: number?,
	AntiAliasing: boolean?
}

export type RowBound = {
	MinX: number,
	MaxX: number
}

export type Sprite = {
	Width: number,
	Height: number,
	Buffer: buffer,
	RowBounds: {[number]: RowBound},
	IsEmpty: boolean,
	HitboxWidth: number,
	HitboxHeight: number,
	HitboxOffsetX: number,
	HitboxOffsetY: number,
	HitboxMaxX: number
}

export type Hitbox = {
	X: number,
	Y: number,
	Width: number,
	Height: number
}

export type PhysicsMode = "AABB" | "Radial"

export type RadialTarget = { X: number, Y: number, Radius: number }

export type Entity = {
	X: number, Y: number,
	VelocityX: number, VelocityY: number,
	Gravity: number?, IsGrounded: boolean?,
	HitboxRadius: number?,       
	PhysicsMode: PhysicsMode?,
	RadialTarget: RadialTarget?, 
	Sprite: Sprite?,
	FlipX: boolean, FlipY: boolean,
	Visible: boolean,
	OnUpdate: ((self: Entity, dt: number) -> ())?,
	OnDraw: ((self: Entity) -> ())?, 
	Destroy: (self: Entity) -> ()
}

export type PhysicsEntity = {
	X: number, Y: number,
	VelocityX: number?, VelocityY: number?,
	Gravity: number?, IsGrounded: boolean?,
	HitboxWidth: number?, HitboxHeight: number?, HitboxRadius: number?,
	Sprite: { Width: number, Height: number }? 
}

local EngineEnums = {
	PhysicsMode = {
		AABB = "AABB",
		Radial = "Radial"
	}
}

table.freeze(EngineEnums.PhysicsMode)
table.freeze(EngineEnums)

export type Ro2DAPI = {
	System: {
		Init: (canvasFrame: Frame, config: EngineConfig?) -> (),
		ScreenToCanvas: (screenX: number, screenY: number) -> (number, number),
		SetBackground: (callback: () -> ()) -> ()
	},
	Draw: {
		Pixel: (worldX: number, worldY: number, r: number, g: number, b: number, a: number?) -> (),
		Sprite: (worldX: number, worldY: number, sprite: Sprite, flipX: boolean?, flipY: boolean?) -> (),
		LineSDF: (worldX0: number, worldY0: number, worldX1: number, worldY1: number, thickness: number, r: number, g: number, b: number) -> (),
		CircleSDF: (worldX: number, worldY: number, radius: number, r: number, g: number, b: number, a: number?) -> (),
		Clear: (r: number, g: number, b: number, a: number?) -> ()
	},
	Assets: {
		LoadSprite: (spriteModule: ModuleScript) -> Sprite
	},
	World: {
		Spawn: (x: number, y: number, sprite: Sprite?) -> Entity,
		AddHitbox: (x: number, y: number, w: number, h: number) -> Hitbox,
		UpdateAll: (dt: number) -> (),
		DrawAll: () -> (),
		Clear: () -> ()
	},
	Physics: {
		Gravity: number,
		CheckAABB: (x1: number, y1: number, w1: number, h1: number, x2: number, y2: number, w2: number, h2: number) -> boolean,
		GetDistance: (x1: number, y1: number, x2: number, y2: number) -> (number, number, number),
		UpdateRadialEntity: (entity: PhysicsEntity, targetX: number, targetY: number, targetRadius: number, dt: number) -> ()
	},
	Input: {
		IsKeyDown: (keyCode: Enum.KeyCode) -> boolean,
		IsKeyPressed: (keyCode: Enum.KeyCode) -> boolean,
		GetMousePosition: () -> (number, number),
		IsMouseDown: (button: number) -> boolean,
		GetScrollDelta: () -> number
	},
	UI: {
		Clear: () -> (),
		DrawFrame: (screenX: number, screenY: number, w: number, h: number, r: number, g: number, b: number, a: number?) -> ()
	},
	Enums: {
		PhysicsMode: {
			AABB: string,
			Radial: string
		}
	},
	Camera: { X: number, Y: number },
	Width: number,
	Height: number,
	IsReady: boolean
}

-- =======================================
-- PUBLIC API
-- =======================================
local API = {
	System = Renderer.System,
	Draw = Renderer.Draw,
	Camera = Renderer.Camera,
	Assets = Assets,
	Physics = Physics,
	World = {
		Spawn = World.Spawn,
		AddHitbox = World.AddHitbox,
		UpdateAll = World.UpdateAll,
		DrawAll = function() World.DrawAll(Renderer.Draw.Sprite) end,
		Clear = World.Clear
	},
	Input = {
		IsKeyDown = function(k) return Input.KeysDown[k] or false end,
		IsKeyPressed = function(k) return Input.KeysPressedThisFrame[k] or false end,
		GetMousePosition = function() return math.floor(Input.Mouse.X * Renderer.Grid.Scale), math.floor(Input.Mouse.Y * Renderer.Grid.Scale) end,
		IsMouseDown = function(b) return (b == 1 and Input.Mouse.LeftDown) or (b == 2 and Input.Mouse.RightDown) or false end,
		GetScrollDelta = function() return Input.Mouse.ScrollDelta end
	},
	UI = UI,
	Enums = EngineEnums
}

local PublicProxy = setmetatable({}, {
	__index = function(_, key)
		if API[key] then return API[key] end
		if key == "Width" then return math.floor(Renderer.Resolution.X * Renderer.Grid.Scale) end
		if key == "Height" then return math.floor(Renderer.Resolution.Y * Renderer.Grid.Scale) end
		if key == "IsReady" then return Renderer.Grid.IsReady end
		return nil
	end,
	__newindex = function(_, key, _) warn("[Ro2DEngine] Read-Only property.") end
})

return PublicProxy :: Ro2DAPI