# Ro2D Engine

Ro2D is a high-performance, code-driven 2D software rendering and physics engine
for Roblox. Instead of standard GUI nodes (ImageLabels, Frames), it manipulates
contiguous memory buffers mapped to the `EditableImage` API, giving you a fully
isolated 2D canvas that you draw to pixel by pixel.

It is built for developers who want a self-contained 2D environment inside
Roblox for retro minigames, bullet-hell games, custom physics simulations, or
spatial UI, without the overhead of the Roblox GUI system.

## Features

* **Zero-allocation render loop.** Upload buffers are recycled from an internal
  pool, eliminating GC spikes. Pixels are read and written 32 bits at a time
  (one RGBA value per buffer op) rather than byte by byte.
* **Dirty-region uploads.** The canvas is split into spatial chunks. Only the
  min/max bounds of modified pixels are pushed to the GPU each frame instead of
  the whole screen. The UI overlay uses the same strategy.
* **Auto-erase background.** Each chunk keeps a persistent snapshot. After a
  frame is uploaded, the dirty region is restored, so moving sprites clear their
  old positions automatically without a full-screen clear.
* **Optional multi-threading.** With `Parallel = true`, a pool of worker Actors
  rasterizes horizontal screen bands in parallel from a shared draw-command
  stream. The engine transparently falls back to the single-threaded path.
* **Parallel compute pool.** Run pure Luau kernels over packed buffers across
  extra worker Actors, decoupled from rendering, for heavy per-entity math.
* **Rotated and tinted primitives.** `Draw.RectRotated` and `Draw.SpriteEx`
  support rotation, scale, flip, tint, and alpha blending.
* **Bitmap text.** Load a baked font atlas and draw text with area-coverage
  sampling, keeping stroke weight consistent at any scale.
* **Built-in physics.** AABB collision, radial/orbital physics, and gravity.
* **SDF primitives.** Anti-aliased circles and lines via signed distance fields.
* **Fixed or native resolution.** Render at the native canvas size or a fixed
  internal resolution (letterboxed, with an optional fill mode).

## The asset pipeline: `png2lua`

Because Ro2D writes pixels directly to memory, standard Roblox image IDs do not
work. The `png2lua` tool (in `tools/`) compiles `.png` sprites into optimized
Luau `ModuleScripts`: it packs RGBA data into a string that the engine decodes
into a `buffer`, and records the sprite's opaque bounds so fully transparent
rows are skipped at draw time.

```
python tools/png2lua.py -i sprite.png -o sprite.luau
```

## Installation

### Rojo (recommended)

```
git clone https://github.com/nrmu9/Ro2DEngine.git
cd Ro2DEngine
rojo serve
```

The default project maps `src` to `ReplicatedStorage/Ro2DEngine`.

### Roblox model

Each tagged release ships a prebuilt `Ro2DEngine.rbxm` on the
[Releases](https://github.com/nrmu9/Ro2DEngine/releases) page (built by CI).
Download it and drop it into `ReplicatedStorage`.

## Quick start

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Ro2D = require(ReplicatedStorage.Ro2DEngine)

-- 1. Set up the canvas
local canvas = script.Parent.CanvasFrame
Ro2D.System.Init(canvas, {
    Isolate2D = true,
    Resolution = Vector2.new(1024, 576), -- fixed internal resolution; omit for native
    AntiAliasing = false,
    -- Parallel = true, WorkerCount = 4,  -- opt into multi-threaded rendering
})

-- 2. Load a sprite (compiled via png2lua)
local PlayerSprite = Ro2D.Assets.LoadSprite(ReplicatedStorage.Assets.PlayerSprite)

-- 3. Spawn an entity
local player = Ro2D.World.Spawn(500, 500, PlayerSprite)
Ro2D.Physics.Gravity = 900

player.OnUpdate = function(self, dt)
    if Ro2D.Input.IsKeyDown(Enum.KeyCode.D) then
        self.VelocityX, self.FlipX = 200, false
    elseif Ro2D.Input.IsKeyDown(Enum.KeyCode.A) then
        self.VelocityX, self.FlipX = -200, true
    else
        self.VelocityX = 0
    end
end

-- 4. Main loop
RunService.RenderStepped:Connect(function(dt)
    if not Ro2D.IsReady then return end
    Ro2D.World.UpdateAll(dt)
    Ro2D.Draw.Clear(20, 20, 30, 255)
    Ro2D.World.DrawAll()
end)
```

## Drawing API

All `Draw` calls operate in world space (offset by `Ro2D.Camera`). Colors are
`0-255` integers; alpha is optional and defaults to `255`.

| Function | Description |
| --- | --- |
| `Draw.Pixel(x, y, r, g, b, a?)` | Write a single pixel. |
| `Draw.Sprite(x, y, sprite, flipX?, flipY?)` | Blit a compiled sprite, skipping transparent pixels. Fully opaque rows blit as one `buffer.copy` span. |
| `Draw.SpriteEx(x, y, sprite, opts?)` | Sprite with rotation, scale, flip, tint, and alpha. |
| `Draw.Rect(x, y, w, h, r, g, b, a?)` | Fast filled rectangle. |
| `Draw.RectRotated(x, y, w, h, angle, r, g, b, a?)` | Rotated filled rectangle. |
| `Draw.Text(x, y, text, font, opts?)` | Bitmap text (scale, tint, alpha, alignment). |
| `Draw.MeasureText(text, font, scale?)` | Pixel width of a text string. |
| `Draw.CircleSDF(x, y, radius, r, g, b, a?)` | Anti-aliased filled circle. |
| `Draw.LineSDF(x0, y0, x1, y1, thickness, r, g, b)` | Anti-aliased line. |
| `Draw.Clear(r, g, b, a?)` | Fill the whole canvas. |

`Assets.LoadSprite` and `Assets.LoadFont` cache their result per `ModuleScript`,
so requiring the same asset again is free after the first decode.

## UI module

`Ro2D.UI` is a work in progress. It is functional and used in the example
places, but the API is not final and may change. Rely on `Draw`, `Physics`, and
`World` for stable use.

## Contributing

Issues and pull requests are welcome, especially around buffer-manipulation and
physics-solver bottlenecks.

## License

MIT. Free to use in your own games and projects.
