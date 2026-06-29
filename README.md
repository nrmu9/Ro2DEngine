# Ro2D Engine

Ro2D is a high-performance, strictly code-driven 2D software rendering and physics engine for Roblox. It bypasses standard GUI nodes (like ImageLabels and Frames) and instead manipulates contiguous memory buffers mapped to the `EditableImage` API.

I built this for developers who want a completely isolated 2D environment inside Roblox for retro minigames, custom physics simulations, or complex UI rendering without the overhead of the DOM-like Roblox GUI system.

## Features

* **Zero-Allocation Rendering:** The engine recycles upload buffers using an internal memory pool to completely eliminate Garbage Collection (GC) spikes during the render loop. Pixels are read and written 32 bits at a time (one RGBA value per buffer op) instead of byte-by-byte.
* **Dirty Region Optimization:** The canvas is split into spatial chunks. Instead of wiping and redrawing the entire screen every frame, Ro2D tracks the min/max bounds of modified pixels and only pushes the exact dirty rectangles to the GPU. The UI overlay layer uses the same sub-rectangle upload strategy.
* **Auto-Erase Background Buffer:** Each chunk keeps a persistent background snapshot. After uploading a frame, the dirty region is restored to the background, so moving sprites erase their old positions automatically — you don't need to clear the screen unless you want to.
* **Fast Clear & Fill:** `Draw.Clear` and `Draw.Rect` fill memory using exponential-doubling `buffer.copy` (log-time native memcpys) rather than per-pixel loops.
* **Built-in Physics & World Management:** Out-of-the-box support for AABB collision detection, radial orbital physics, and gravity application.
* **True SDF Primitives:** Draw circles and lines using Signed Distance Fields for smooth, anti-aliased sub-pixel edges.

## The Asset Pipeline: `png2lua`

Because Ro2D writes pixel data directly to memory, you can't just use standard Roblox Image/Texture IDs. To solve this, I built the **`png2lua`** tool (included in this repository).

`png2lua` takes your standard `.png` sprite files and compiles them into highly optimized Luau `ModuleScripts`. It packs the RGBA data into a string that the engine converts into a `buffer`. During loading of the sprite, Ro2D calculates the exact bounds of the sprite and ignores fully transparent rows. This allows the `Ro2D.Draw.Sprite` function to skip transparent pixels entirely, making sprite rendering incredibly fast.

Usage example:
`python png2lua.py -i sprite.png -o sprite.lua`

## Installation

### Method 1: Rojo (Recommended)

This project is structured for Rojo. Clone the repository and sync it to your Studio session:

```
git clone https://github.com/nrmu9/Ro2DEngine.git
cd Ro2DEngine
rojo serve
```

### Method 2: Roblox Model

Download the latest `.rbxmx` release from the [Releases](https://github.com/nrmu9/Ro2DEngine/releases) tab and drop it into `ReplicatedStorage`.

## Quick Start

Here is a basic boilerplate to initialize the engine, load a compiled sprite, and run the main loop:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Ro2D = require(ReplicatedStorage.Ro2DEngine)

-- 1. Setup the Canvas
local canvas = script.Parent.CanvasFrame
Ro2D.System.Init(canvas, {
    Isolate2D = true,
    RenderScale = 0.5,
    AntiAliasing = false
})

-- 2. Load a Sprite (compiled via png2lua)
local PlayerModule = ReplicatedStorage.Assets.PlayerSprite
local PlayerSprite = Ro2D.Assets.LoadSprite(PlayerModule)

-- 3. Spawn an Entity
local player = Ro2D.World.Spawn(500, 500, PlayerSprite)
Ro2D.Physics.Gravity = 900

player.OnUpdate = function(self, dt)
    if Ro2D.Input.IsKeyDown(Enum.KeyCode.D) then
        self.VelocityX = 200
        self.FlipX = false
    elseif Ro2D.Input.IsKeyDown(Enum.KeyCode.A) then
        self.VelocityX = -200
        self.FlipX = true
    else
        self.VelocityX = 0
    end
end

-- 4. Main Loop
RunService.RenderStepped:Connect(function(dt)
    if not Ro2D.IsReady then return end

    Ro2D.World.UpdateAll(dt)
    Ro2D.Draw.Clear(20, 20, 30, 255) -- Clear background
    Ro2D.World.DrawAll()
end)

```

## Drawing API

All `Draw` calls operate in **world space** (offset by `Ro2D.Camera`). Colors are `0–255` integers; alpha is optional and defaults to `255`.

| Function | Description |
| --- | --- |
| `Draw.Pixel(x, y, r, g, b, a?)` | Write a single pixel. |
| `Draw.Sprite(x, y, sprite, flipX?, flipY?)` | Blit a compiled sprite, skipping transparent pixels. |
| `Draw.Rect(x, y, w, h, r, g, b, a?)` | Fast filled rectangle (chunk-aware span fills). |
| `Draw.CircleSDF(x, y, radius, r, g, b, a?)` | Anti-aliased filled circle. |
| `Draw.LineSDF(x0, y0, x1, y1, thickness, r, g, b)` | Anti-aliased line. |
| `Draw.Clear(r, g, b, a?)` | Fill the whole canvas. |

`Ro2D.Assets.LoadSprite` caches its result per `ModuleScript`, so requiring the same sprite repeatedly is free after the first decode.

## Disclaimer regarding UI

The `Ro2D.UI` module included in the source is currently a **Work In Progress**. While it is functional (and used in my example places), the API is not final and will likely undergo breaking changes in future updates. Rely on `Draw`, `Physics`, and `World` for stable use.

## Contributing

Pull requests and optimization tweaks are highly encouraged. If you find a bottleneck in the buffer manipulations or physics solver, feel free to open an issue or submit a PR.

## License

MIT License. Free to use in your own games and projects.

```
