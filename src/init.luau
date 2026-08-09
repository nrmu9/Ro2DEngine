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
		-- Many small squares as one command. Bracket a run with BeginPoints and
		-- EndPoints and call Point for each; on the parallel renderer that is one
		-- command for the whole field instead of one per square, which is what keeps
		-- a large particle system inside a worker's time budget.
		BeginPoints: () -> (),
		Point: (worldX: number, worldY: number, size: number, r: number, g: number, b: number, a: number?) -> (),
		EndPoints: () -> (),
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
-- How many render workers a caller gets without asking for a number. Four is the
-- floor worth having: it is what a modest phone can keep busy, and the band split
-- costs a little per worker, so more is a choice a scene makes rather than a
-- default it inherits.
local DEFAULT_WORKERS = 4
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


-- The overlay is owned here rather than by a renderer. Each backend keeps its own
-- copy, and a scene that switches between them (parallel menus, a serial fight)
-- would otherwise leave one of them holding nothing -- which is how a debug
-- overlay registered once at start-up came to vanish the moment a fight began.
-- Kept at this level and re-applied on every Init, it survives the swap.
local overlayFn = nil
local function applyOverlay()
	if activeIsParallel and ParallelRenderer then
		ParallelRenderer.System.SetOverlay(overlayFn)
	else
		Renderer.System.SetOverlay(overlayFn)
	end
end
-- Held as locals as well as fields. `bindBackend` empties the table before it
-- fills it, and this table IS the one the caller holds, so reading these back off
-- it mid-bind would read what the clear had just removed.
local function systemSetOverlay(fn)
	overlayFn = fn
	applyOverlay()
end
local function noFade() end
local systemInit

-- ONE renderer with two backends behind it.
--
-- They used to be two objects handed straight to the caller. `Ro2D.Draw` was
-- REPLACED on Init, so anything holding it from before -- or holding a function
-- taken off it -- went on talking to the backend that was no longer running. The
-- System swap was worse, because it only went one way: a parallel Init
-- overwrote SetTint, SetFade and five others, and a serial Init afterwards put
-- none of them back, so the serial scene drove the parallel renderer's state and
-- its tint and fade went nowhere.
--
-- The tables the caller holds now never change identity. Init re-points what is
-- inside them, in both directions, every time.
-- No __index fallback to a backend on either of these. Binding is TOTAL -- every
-- call the caller can make is written in by `bindBackend` -- because a fallback
-- is exactly how a function belonging to the renderer that is NOT running
-- survives a swap and quietly keeps being called.
local DRAW, SYSTEM = {}, {}
-- Both backends read the SAME camera table, so `Ro2D.Camera` is one object for
-- the life of the session. Assigned rather than copied: the serial renderer bound
-- its camera to an upvalue at load, so the table has to be the one it already
-- has, and the parallel one reads its own field per call and can be pointed here.
local CAMERA = Renderer.Camera

local function bindBackend(be)
	table.clear(DRAW)
	for k, v in pairs(be.Draw) do DRAW[k] = v end
	-- Everything the backend offers, then the three this module owns whichever
	-- backend is running. SetFade is a no-op on a renderer that has none, rather
	-- than a missing function, so a caller never has to ask which it is talking to.
	table.clear(SYSTEM)
	for k, v in pairs(be.System) do SYSTEM[k] = v end
	SYSTEM.Init = systemInit
	SYSTEM.SetOverlay = systemSetOverlay
	if SYSTEM.SetFade == nil then SYSTEM.SetFade = noFade end
	if Ro2D then Ro2D.Compute = be.Compute or ComputeStub end
end

function systemInit(canvasFrame, config)
	if config and config.Isolate2D then applyIsolate2D() end
	-- Threaded unless the caller says otherwise, on four workers unless the caller
	-- says how many. It is the faster path on every device that has the cores for
	-- it, so it is what you get without asking; `Parallel = false` is the way out,
	-- for a device that cannot or a bug that needs the simpler renderer to compare
	-- against.
	local wantParallel = not (config and config.Parallel == false)
	if wantParallel then
		ParallelRenderer = ParallelRenderer
			or require(script:WaitForChild("parallel"):WaitForChild("ParallelRenderer"))
		ParallelRenderer.Camera = CAMERA
		local cfg = config or {}
		if cfg.WorkerCount == nil then
			cfg = table.clone(cfg)
			cfg.WorkerCount = DEFAULT_WORKERS
		end
		ParallelRenderer.System.Init(canvasFrame, cfg)
		activeIsParallel = true
		bindBackend(ParallelRenderer)
	else
		activeIsParallel = false
		Renderer.System.Init(canvasFrame, config)
		bindBackend(Renderer)
	end
	-- Last, so it lands on whichever backend this Init just made current.
	applyOverlay()
end

Ro2D = {
	System = SYSTEM,
	Draw = DRAW,
	Camera = CAMERA,
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

-- The surface is live before Init, bound to the single-threaded backend. Without
-- this a caller that touched `Draw` or `System` between requiring the engine and
-- initialising it would find an empty table rather than a renderer that has not
-- started yet, and "attempt to call a nil value" is a worse way to learn that.
bindBackend(Renderer)

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
