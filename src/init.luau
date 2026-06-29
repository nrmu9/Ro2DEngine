--!optimize 2
-- Ro2D Engine :: public entry point.
-- Modules are flat children of this ModuleScript (see default.project.json / sourcemap.json).

local Renderer = require(script:WaitForChild("Renderer"))
local Assets = require(script:WaitForChild("Assets"))
local World = require(script:WaitForChild("World"))
local Input = require(script:WaitForChild("Input"))
local UI = require(script:WaitForChild("UI"))
local Physics = require(script:WaitForChild("Physics"))

-- =======================================
-- ENGINE TYPES
-- =======================================
export type EngineConfig = {
	Isolate2D: boolean?,
	AntiAliasing: boolean?,
	Resolution: Vector2?, -- fixed internal render resolution (letterboxed); else native canvas size
}

export type RowBound = {
	MinX: number,
	MaxX: number,
}

export type Sprite = {
	Width: number,
	Height: number,
	Buffer: buffer,
	RowBounds: { [number]: RowBound },
	IsEmpty: boolean,
	SolidRows: boolean,
	HitboxWidth: number,
	HitboxHeight: number,
	HitboxOffsetX: number,
	HitboxOffsetY: number,
	HitboxMaxX: number,
}

export type Hitbox = {
	X: number,
	Y: number,
	Width: number,
	Height: number,
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
	Destroy: (self: Entity) -> (),
}

export type PhysicsEntity = {
	X: number, Y: number,
	VelocityX: number?, VelocityY: number?,
	Gravity: number?, IsGrounded: boolean?,
	HitboxWidth: number?, HitboxHeight: number?, HitboxRadius: number?,
	Sprite: { Width: number, Height: number }?,
}

local EngineEnums = table.freeze({
	PhysicsMode = table.freeze({
		AABB = "AABB",
		Radial = "Radial",
	}),
})

export type Ro2DAPI = {
	System: {
		Init: (canvasFrame: GuiObject, config: EngineConfig?) -> (),
		ScreenToCanvas: (screenX: number, screenY: number) -> (number, number),
		SetBackground: (callback: () -> ()) -> (),
	},
	Draw: {
		Pixel: (worldX: number, worldY: number, r: number, g: number, b: number, a: number?) -> (),
		Sprite: (worldX: number, worldY: number, sprite: Sprite, flipX: boolean?, flipY: boolean?) -> (),
		Rect: (worldX: number, worldY: number, w: number, h: number, r: number, g: number, b: number, a: number?) -> (),
		LineSDF: (worldX0: number, worldY0: number, worldX1: number, worldY1: number, thickness: number, r: number, g: number, b: number) -> (),
		CircleSDF: (worldX: number, worldY: number, radius: number, r: number, g: number, b: number, a: number?) -> (),
		Clear: (r: number, g: number, b: number, a: number?) -> (),
	},
	Assets: {
		LoadSprite: (spriteModule: ModuleScript) -> Sprite,
	},
	World: {
		Spawn: (x: number, y: number, sprite: Sprite?) -> Entity,
		AddHitbox: (x: number, y: number, w: number, h: number) -> Hitbox,
		UpdateAll: (dt: number) -> (),
		DrawAll: () -> (),
		Clear: () -> (),
	},
	Physics: {
		Gravity: number,
		CheckAABB: (x1: number, y1: number, w1: number, h1: number, x2: number, y2: number, w2: number, h2: number) -> boolean,
		GetDistance: (x1: number, y1: number, x2: number, y2: number) -> (number, number, number),
		UpdateRadialEntity: (entity: PhysicsEntity, targetX: number, targetY: number, targetRadius: number, dt: number) -> (),
	},
	Input: {
		IsKeyDown: (keyCode: Enum.KeyCode) -> boolean,
		IsKeyPressed: (keyCode: Enum.KeyCode) -> boolean,
		GetMousePosition: () -> (number, number),
		IsMouseDown: (button: number) -> boolean,
		GetScrollDelta: () -> number,
	},
	UI: {
		Clear: () -> (),
		DrawFrame: (screenX: number, screenY: number, w: number, h: number, r: number, g: number, b: number, a: number?) -> (),
	},
	Enums: {
		PhysicsMode: { AABB: string, Radial: string },
	},
	Camera: { X: number, Y: number },
	Width: number,
	Height: number,
	IsReady: boolean,
}

-- =======================================
-- PUBLIC API
-- =======================================
local Grid = Renderer.Grid
local mouse = Input.Mouse
local keysDown = Input.KeysDown
local keysPressed = Input.KeysPressedThisFrame
local drawSprite = Renderer.Draw.Sprite

local Ro2D = {
	System = Renderer.System,
	Draw = Renderer.Draw,
	Camera = Renderer.Camera,
	Assets = Assets,
	Physics = Physics,
	UI = UI,
	Enums = EngineEnums,

	World = {
		Spawn = World.Spawn,
		AddHitbox = World.AddHitbox,
		UpdateAll = World.UpdateAll,
		DrawAll = function() World.DrawAll(drawSprite) end,
		Clear = World.Clear,
	},

	Input = {
		IsKeyDown = function(k) return keysDown[k] == true end,
		IsKeyPressed = function(k) return keysPressed[k] == true end,
		GetMousePosition = function()
			local inv = 1 / Grid.DisplayScale
			return math.floor((mouse.X - Grid.OffsetX) * inv), math.floor((mouse.Y - Grid.OffsetY) * inv)
		end,
		IsMouseDown = function(b)
			return (b == 1 and mouse.LeftDown) or (b == 2 and mouse.RightDown) or false
		end,
		GetScrollDelta = function() return mouse.ScrollDelta end,
	},
}

-- Static namespaces are real fields (raw, fast access). Only the three live scalars
-- are resolved dynamically, and any stray write is rejected to catch typos early.
local proxy = setmetatable({}, {
	__index = function(_, key)
		local v = Ro2D[key]
		if v ~= nil then return v end
		if key == "Width" then return Grid.Width end
		if key == "Height" then return Grid.Height end
		if key == "IsReady" then return Grid.IsReady end
		return nil
	end,
	__newindex = function(_, key)
		error(`[Ro2D] '{key}' is read-only.`, 2)
	end,
	__metatable = "Locked",
})

return proxy :: Ro2DAPI
