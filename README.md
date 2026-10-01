# Ro2D Engine

Ro2D is a high-performance, code-driven 2D software rendering and physics engine
for Roblox. Instead of standard GUI nodes (ImageLabels, Frames), it manipulates
contiguous memory buffers mapped to the `EditableImage` API, giving you a fully
isolated 2D canvas that you draw to pixel by pixel.

It is built for developers who want a self-contained 2D environment inside
Roblox for retro minigames, bullet-hell games, custom physics simulations, or
spatial UI, without the overhead of the Roblox GUI system.

## Features

* **Pooled uploads.** Upload buffers are recycled from an internal pool, so a
  frame's uploads allocate nothing. Pixels are read and written 32 bits at a
  time (one RGBA value per buffer op) rather than byte by byte.
* **Fast with or without native code.** Some clients run Luau interpreted, where
  a pixel written in a loop is the main cost, so the rasterizer works in spans
  rather than pixels wherever it can: solid fills and opaque sprite runs are
  `buffer.copy` calls, a see-through fill reuses the colour it made last and
  copies rows that repeat, sprites are kept pre-blended over the clear colour,
  and glyph coverage is cached per scale.
* **Frame-to-frame memory.** Text, scaled or tinted sprites and see-through
  rects are pasted back when neither they nor the pixels under them have
  changed, and a band whose commands are exactly last frame's is not drawn or
  uploaded at all. Every shortcut produces the same pixels as drawing in full.
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

## Asset pipeline

Because Ro2D writes pixels directly to memory, standard Roblox image IDs and
fonts do not work. Two tools in `tools/` compile assets into Luau
`ModuleScripts` that the engine decodes into buffers. Both require Pillow
(`pip install Pillow`).

**Sprites.** `png2lua` packs a `.png` into RGBA data and records the sprite's
opaque bounds, so fully transparent rows are skipped at draw time.

```
python tools/png2lua.py -i sprite.png -o sprite.luau
```

**Fonts.** `bake_font` rasterizes a `.ttf`/`.otf` into a packed atlas whose RGB
is white and whose alpha is glyph coverage, so `Draw.Text` can tint it per call.
The result is loaded with `Assets.LoadFont`.

```
python tools/bake_font.py -i Inter.ttf -o Inter.luau -s 40
```

`-s` sets the native pixel size to rasterize at (default 40); `--atlas-width`
and `--pad` control packing. The font name defaults to the output filename.

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

`Ro2D.Camera.Zoom` (default `1`) scales every draw about the middle of the
screen: positions move away from the middle and sizes, text and sprites grow by
the same factor. Set it for the part of a frame that is the world and put it
back to `1` for a HUD drawn over it.

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
| `Draw.Polygon(xs, ys, r, g, b, a?, offsetX?, offsetY?, count?)` | Anti-aliased filled polygon, its points `(xs[k] + offsetX, ys[k] + offsetY)` for the first `count` of them (all, by default), one draw however many points. |
| `Draw.Clear(r, g, b, a?)` | Fill the whole canvas. Ignores the clip. |
| `Draw.SetClip(x, y, w, h)` | Restrict subsequent drawing to a rectangle. Cuts text off mid-glyph, so scrolling lists need no fade. |
| `Draw.ClearClip()` | Restore drawing to the full surface. |

`Draw.Polygon` fills by how much of each pixel the shape covers, so its edges are
smooth with no outline drawn over them, and a shape that crosses itself is filled
wherever it winds round (a five-pointed star drawn in one stroke has a filled
middle). A point is the middle of a pixel, as a line's end is: a square from
`9.5` to `19.5` fills pixels `10` to `19` exactly. It takes up to 65535 points,
and a point that is not a number leaves the polygon undrawn. Under the parallel
renderer the whole outline is one command, and a see-through polygon drawn again
over unchanged pixels is pasted back, as a see-through rect is.

`Assets.LoadSprite` and `Assets.LoadFont` cache their result per `ModuleScript`,
so requiring the same asset again is free after the first decode.

`System.ImageError()` answers why part of the canvas has nothing to draw into,
or `nil` while every band and chunk has its image. Roblox refuses an
`EditableImage` past a device's memory budget, and a part of the screen without
one stays empty; a game that sees an answer can call `System.SetResolution` with
a smaller size, which makes the images again.

## Pointer and touch

`Input.GetMousePosition()` and `Input.IsMouseDown(1)` are the pointer: the
mouse, the gamepad's cursor, or on a touchscreen the newest finger still down.
Other fingers neither move it nor hold it down, so a thumb resting on a stick
does not stop a tap elsewhere from pressing. When a finger lands while another
is the pointer, the pointer lets go for one frame, off the screen, then presses
where the new finger is, so the handover clicks nothing under the first finger.
A game that follows several fingers at once reads them from `UserInputService`.

The gamepad's cursor moves with the left stick and clicks with A. A game whose
d-pad walks a focus of its own parks the cursor with
`Input.SetPointerParked(true)` as the focus moves: the cursor is hidden, the
pointer reads as off the screen, and A is not its click, so A answers the focus
alone. Moving the stick brings the cursor back where it was, and
`Input.IsPointerParked()` says which of the two a pad is using.

## Input actions

`Ro2D.Input.Actions` lets a game read input by name and let players change the
keys. The engine holds no defaults and saves nothing; the game hands in its
action table and stores the overrides `bindings()` returns wherever it likes.

```lua
local Actions = Ro2D.Input.Actions
Actions.define({
    order = { "Move", "Fire" },
    actions = {
        Move = { label = "MOVE", kind = "axis",
            kbm = { up = "W", down = "S", left = "A", right = "D" },
            alt = { up = "Up", down = "Down", left = "Left", right = "Right" },
            pad = "Thumbstick1", lock = { pad = true } },
        Fire = { label = "SHOOT", kbm = "MouseLeftButton", pad = "ButtonR2" },
    },
    blocked = { "Slash" },
})

-- each frame
local mx, my = Actions.axis("Move")        -- screen space: +x right, +y down
if Actions.down("Fire") then keepShooting() end
if Actions.pressed("Fire") then shoot() end -- consumes one queued press

-- a keybinds screen
Actions.capture("kbm", function(key)       -- nil when cancelled
    if key then print(Actions.rebind("Fire", "kbm", key)) end
end)
save(Actions.bindings())                   -- only what differs from the defaults
Actions.apply(load())
Actions.label("Fire", "kbm")               -- "LMB", for a prompt
```

An axis action may carry `alt`, a second keyboard set that is read but never
rebound or saved; a key from it yields to any action it is later bound to.

Keys are strings: `Enum.KeyCode` names, or `MouseLeftButton`,
`MouseRightButton`, `MouseMiddleButton`. `rebind` refuses a blocked key, a
locked binding, and a key another action already answers to on that device.

## UI module

`Ro2D.UI` is a work in progress. It is functional and used in the example
places, but the API is not final and may change. Rely on `Draw`, `Physics`, and
`World` for stable use.

## Contributing

Issues and pull requests are welcome, especially around buffer-manipulation and
physics-solver bottlenecks.

## License

MIT. Free to use in your own games and projects.
