--!optimize 2

local Renderer = require(script:WaitForChild("Renderer"))
local Assets = require(script:WaitForChild("Assets"))
local World = require(script:WaitForChild("World"))
local Input = require(script:WaitForChild("Input"))
local UI = require(script:WaitForChild("UI"))
local Physics = require(script:WaitForChild("Physics"))

export type EngineConfig = {
	Isolate2D: boolean?,
	AntiAliasing: boolean?,
	Resolution: Vector2?,
	Fill: boolean?,
	Parallel: boolean?,
	WorkerCount: number?,
	ComputeWorkers: number?,
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

export type Font = {
	Name: string?,
	Buffer: buffer,
	Width: number,
	Height: number,
	LineHeight: number,
	Ascent: number,
	CapCenter: number?,
	SpaceAdvance: number,
	Glyphs: { [number]: { X: number, Y: number, W: number, H: number, Adv: number, OX: number, OY: number } },
}

export type TextDrawOptions = {
	Scale: number?,
	TintR: number?,
	TintG: number?,
	TintB: number?,
	Alpha: number?,
	Align: ("left" | "center" | "right")?,
	VAlign: ("top" | "center")?,
}

export type SpriteDrawOptions = {
	Rotation: number?,
	Scale: number?,
	FlipX: boolean?,
	FlipY: boolean?,
	TintR: number?,
	TintG: number?,
	TintB: number?,
	Alpha: number?,
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
		SetImmediateMode: (on: boolean) -> (),
		SkipFrame: () -> (),
		SetTint: (r: number, g: number, b: number, alpha: number) -> (),
		SetFade: (alpha: number) -> (),
		SetResolution: (res: Vector2?, fill: boolean?) -> (),
	},
	Draw: {
		Pixel: (worldX: number, worldY: number, r: number, g: number, b: number, a: number?) -> (),
		Sprite: (worldX: number, worldY: number, sprite: Sprite, flipX: boolean?, flipY: boolean?) -> (),
		SpriteEx: (worldX: number, worldY: number, sprite: Sprite, opts: SpriteDrawOptions?) -> (),
		Rect: (worldX: number, worldY: number, w: number, h: number, r: number, g: number, b: number, a: number?) -> (),
		RectRotated: (worldX: number, worldY: number, w: number, h: number, angle: number, r: number, g: number, b: number, a: number?) -> (),
		Text: (worldX: number, worldY: number, text: string, font: Font, opts: TextDrawOptions?) -> (),
		MeasureText: (text: string, font: Font, scale: number?) -> number,
		LineSDF: (worldX0: number, worldY0: number, worldX1: number, worldY1: number, thickness: number, r: number, g: number, b: number) -> (),
		CircleSDF: (worldX: number, worldY: number, radius: number, r: number, g: number, b: number, a: number?) -> (),
		Clear: (r: number, g: number, b: number, a: number?) -> (),
		SetClip: (worldX: number, worldY: number, w: number, h: number) -> (),
		ClearClip: () -> (),
	},
	Assets: {
		LoadSprite: (spriteModule: ModuleScript) -> Sprite,
		LoadFont: (fontModule: ModuleScript) -> Font,
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
	Compute: {
		IsReady: boolean,
		WorkerCount: number,
		registerKernel: (module: ModuleScript) -> number,
		dispatch: (kernelId: number, inputBytes: string, count: number, stride: number, paramsBytes: string?) -> (),
		gather: () -> (string?, number?),
	},
}

local Grid = Renderer.Grid
local mouse = Input.Mouse
local keysDown = Input.KeysDown
local keysPressed = Input.KeysPressedThisFrame
local drawSprite = Renderer.Draw.Sprite

local Ro2D
local ParallelRenderer, activeIsParallel = nil, false
local inputLocked = false
local function rawMousePos()
	local sx, sy = mouse.X, mouse.Y
	if Input.GamepadActive then sx, sy = Input.PadCursorX, Input.PadCursorY end
	if activeIsParallel then
		local inv = 1 / (ParallelRenderer._scale or 1)
		return math.floor((sx - (ParallelRenderer._offX or 0)) * inv),
			math.floor((sy - (ParallelRenderer._offY or 0)) * inv)
	end
	local inv = 1 / Grid.DisplayScale
	return math.floor((sx - Grid.OffsetX) * inv), math.floor((sy - Grid.OffsetY) * inv)
end
local ComputeStub = {
	IsReady = false,
	WorkerCount = 0,
	registerKernel = function() return 0 end,
	dispatch = function() end,
	gather = function() return nil end,
}
local isolated = false
local function applyIsolate2D()
	if isolated then return end
	isolated = true
	local Players = game:GetService("Players")
	local StarterGui = game:GetService("StarterGui")
	local ContextActionService = game:GetService("ContextActionService")
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false) end)
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true) end)
	pcall(function() game:GetService("TextChatService").ChatWindowConfiguration.Enabled = true end)
	local camera = workspace.CurrentCamera
	if camera then camera.CameraType = Enum.CameraType.Scriptable end
	local player = Players.LocalPlayer
	pcall(function()
		player.DevComputerCameraMovementMode = Enum.DevComputerCameraMovementMode.Classic
		player.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
		player.DevTouchMovementMode = Enum.DevTouchMovementMode.Scriptable
	end)
	if player.Character then player.Character:Destroy() end
	player.CharacterAdded:Connect(function(char) char:Destroy() end)
	task.spawn(function()
		for _ = 1, 40 do
			pcall(function() ContextActionService:UnbindAction("RbxCameraKeypress") end)
			task.wait(0.25)
		end
	end)
end

local SystemWrap = setmetatable({}, { __index = Renderer.System })
function SystemWrap.SetFade() end

-- The overlay is owned here rather than by a renderer. Each renderer keeps its
-- own copy, and a scene that switches between them (parallel menus, a serial
-- fight) would otherwise leave one of them holding nothing -- which is how a
-- debug overlay registered once at start-up came to vanish the moment a fight
-- began. Kept at this level and re-applied on every Init, it survives the swap.
local overlayFn = nil
local function applyOverlay()
	if activeIsParallel and ParallelRenderer then
		ParallelRenderer.System.SetOverlay(overlayFn)
	else
		Renderer.System.SetOverlay(overlayFn)
	end
end
function SystemWrap.SetOverlay(fn)
	overlayFn = fn
	applyOverlay()
end

function SystemWrap.Init(canvasFrame, config)
	if config and config.Isolate2D then applyIsolate2D() end
	if config and config.Parallel then
		ParallelRenderer = ParallelRenderer
			or require(script:WaitForChild("parallel"):WaitForChild("ParallelRenderer"))
		ParallelRenderer.System.Init(canvasFrame, config)
		activeIsParallel = true
		Ro2D.Draw = ParallelRenderer.Draw
		Ro2D.Camera = ParallelRenderer.Camera
		Ro2D.Compute = ParallelRenderer.Compute
		SystemWrap.SetTint = ParallelRenderer.System.SetTint
		SystemWrap.SetFade = ParallelRenderer.System.SetFade
		SystemWrap.SetBackground = ParallelRenderer.System.SetBackground
		SystemWrap.SetImmediateMode = ParallelRenderer.System.SetImmediateMode
		SystemWrap.SkipFrame = ParallelRenderer.System.SkipFrame
		SystemWrap.ScreenToCanvas = ParallelRenderer.System.ScreenToCanvas
		SystemWrap.SetResolution = ParallelRenderer.System.SetResolution
	else
		activeIsParallel = false
		Renderer.System.Init(canvasFrame, config)
	end
	-- Last, so it lands on whichever renderer this Init just made current.
	applyOverlay()
end

Ro2D = {
	System = SystemWrap,
	Draw = Renderer.Draw,
	Camera = Renderer.Camera,
	Assets = Assets,
	Physics = Physics,
	UI = UI,
	Enums = EngineEnums,
	Compute = ComputeStub,

	World = {
		Spawn = World.Spawn,
		AddHitbox = World.AddHitbox,
		UpdateAll = World.UpdateAll,
		DrawAll = function() World.DrawAll(drawSprite) end,
		Clear = World.Clear,
	},

	Input = {
		IsKeyDown = function(k) return not inputLocked and keysDown[k] == true end,
		IsKeyPressed = function(k) return not inputLocked and keysPressed[k] == true end,
		GetMousePosition = function()
			if inputLocked then return -100000, -100000 end
			return rawMousePos()
		end,
		GetMousePositionRaw = rawMousePos,
		IsMouseDown = function(b)
			if inputLocked then return false end
			if b == 1 then return mouse.LeftDown or Input.PadDown end
			return (b == 2 and mouse.RightDown) or false
		end,
		GetScrollDelta = function() return inputLocked and 0 or mouse.ScrollDelta end,
		SetLocked = function(v) inputLocked = v == true end,
		IsLocked = function() return inputLocked end,
		IsGamepadActive = function() return Input.GamepadActive end,
		SetPointerVisible = function(v) Input.PointerVisible = v ~= false end,
	},
}

local proxy = setmetatable({}, {
	__index = function(_, key)
		local v = Ro2D[key]
		if v ~= nil then return v end
		if key == "Width" then return activeIsParallel and ParallelRenderer.Width or Grid.Width end
		if key == "Height" then return activeIsParallel and ParallelRenderer.Height or Grid.Height end
		if key == "IsReady" then return activeIsParallel and ParallelRenderer.IsReady or Grid.IsReady end
		return nil
	end,
	__newindex = function(_, key)
		error(`[Ro2D] '{key}' is read-only.`, 2)
	end,
	__metatable = "Locked",
})

return proxy :: Ro2DAPI
