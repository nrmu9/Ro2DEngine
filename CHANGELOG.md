# Changelog

All notable changes to Ro2D are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-04

### Added
- `System.SkipFrame()` declares a frame identical to the one already on screen.
  The canvas is persistent, so a frame that would paint the same pixels does not
  need to be painted: under the parallel renderer nothing is decoded and no image
  is uploaded, and the workers keep what they have. It exists on the serial
  renderer too, where the flush already uploads only what changed, so that a
  caller never has to ask which renderer it is talking to.

  Called instead of drawing rather than after it, and for one frame only. A
  screen sitting behind a settled modal is the case it is for.

### Fixed
- `Draw.Text` clips to the visible range instead of walking the whole glyph.
  Both loops in the blit ran the glyph's full size and tested each pixel from the
  inside, so a glyph scrolled off an edge, or simply drawn large, spun through
  its entire area to paint a sliver of it or none at all. A band's whole frame
  runs on one resumption in a parallel worker and Roblox kills a resumption that
  overruns its budget, so this showed up as workers timing out rather than as
  anything merely slow.

  The visible column and row ranges are computed once from the clip, and the
  per-column sample weights are looked up by index rather than carried as a
  running total through columns the blit no longer visits.

- A failed canvas write is reported once for the canvas rather than once per
  worker. Every worker writes its own band of the same image, so a failure is
  nearly always all of them failing together on the same cause, and each was
  suppressing only its own repeats.

## [0.2.3] - 2026-08-02

### Fixed
- An overlay is drawn in screen space. Every draw call bakes the camera in as it
  is recorded and the overlay was recorded like any other drawing, so in a scene
  whose camera follows something it was carried along, moving around the screen
  and leaving it entirely once the camera was far enough from the origin. The
  camera is zeroed for the duration of the callback and restored after, in both
  renderers.

  The pointer was already reported in canvas space with no camera in it, so
  hit-testing inside an overlay had been wrong by the same offset. The two agree
  now.

- An overlay that errors is reported once rather than swallowed. It runs every
  frame, so the choice was between silence and tens of thousands of lines, and
  silence makes an overlay drawn off screen indistinguishable from one that was
  never called.

- `System.SetOverlay` survives a re-init. The callback was stored on whichever
  renderer was current when it was registered, so a place that re-initialised the
  engine between a parallel scene and a serial one lost it. It is held above both
  renderers now and re-applied at the end of every `Init`.

## [0.2.2] - 2026-08-02

### Fixed
- The gamepad cursor is driven by whichever pad the player is holding, not by
  `Gamepad1`. `LastInputTypeChanged` only turned `GamepadActive` on for that one
  and the stick was only ever read from it, so a controller that enumerated
  anywhere else left the cursor invisible and immobile. Another pad paired ahead
  of it, or a reconnect, is enough to move it, and on a console that leaves
  nothing to click with.

  The active pad is picked from the navigation gamepads, corrected by any pad
  input that arrives, updated on connect and disconnect, and re-picked while none
  is known. The last part covers joining: the pad list can still be empty as
  `Input` loads, and a stick sends `InputChanged` rather than `InputBegan`, so a
  player who only pushes the stick announces themselves no other way.

- A worker that cannot write to its `EditableImage` says so once instead of on
  every frame. The API is gated behind an experience setting and the check that
  decides whether it is available can also fail to reach Roblox; that write runs
  once per worker per frame, so a session could produce tens of thousands of
  copies of one message. A worker that cannot create its image at all now stands
  down rather than erroring forever.

### Performance
- `Rasterizer.rectRot` scans only the pixels a rotated rect covers. It walked the
  whole axis-aligned bounding box and tested every pixel in it, which for a long
  thin bar at an angle is around a hundred times the bar's own area: a 900px bar
  three pixels thick at sixty degrees came to 317,800 tests to paint 2,700
  pixels. At ninety-odd such bars in a frame that was enough to exhaust a
  parallel worker's allowed execution time, reported as "Script timeout:
  exhausted allowed execution time for the current resumption point".

  Each scanline now solves for the x-range the rect actually covers, widened by a
  pixel each side, with the original per-pixel test kept inside it. Output is
  unchanged, verified pixel for pixel against the old predicate over four hundred
  randomised rects.

## [0.2.1] - 2026-07-25

### Performance
- `ParallelRenderer` and `World` are compiled with `--!native`. The recorder runs
  per-call arithmetic and buffer writes once per primitive per frame, and `World`
  runs the AABB and radial solvers; both are numeric enough to be worth it. The
  rasterizer, renderer, command buffer and worker were already marked.

  Native code generation is platform-dependent. Where it is unavailable the
  script falls back to the interpreter and Studio logs "Native code generation
  not initialized" — that is a fallback notice, not an error.

## [0.2.0] - 2026-07-25

### Added
- Scissor clipping: `Draw.SetClip(x, y, w, h)` restricts subsequent drawing to a
  rectangle, `Draw.ClearClip()` restores the full surface. Coordinates are in the
  same world space as the draw calls, and a zero or negative size clips everything
  away until the clip is cleared.

  Every primitive honours it, including text, which previously could not be cut
  off mid-glyph — scrolling lists had to fade their contents out instead. Works in
  both renderers: the parallel path records it as a command so it takes effect at
  the right point in the frame, and each worker intersects it with its own band.

  The clip resets to the full surface at the end of every frame, so a scene that
  errors part-way through cannot leave the next one clipped. `Draw.Clear` and the
  global tint are whole-frame operations and ignore it.

## [0.1.1] - 2026-07-21

### Fixed
- `Draw.Sprite` is placed by its top-left corner again when the parallel
  renderer is active. The worker forwarded that coordinate straight to the
  centre-based sprite path, so every `Draw.Sprite` landed half a sprite up and
  to the left of where the single-threaded renderer puts it. Sprites drawn this
  way will shift back into place; anything positioned to compensate needs its
  offset removed.

## [0.1.0] - 2026-07-20

First tagged release. Consolidates a large body of renderer, physics, and
tooling work into a versioned package with automated model builds.

### Added
- Multi-threaded renderer: an optional worker-Actor pool rasterizes screen
  bands in parallel from a shared draw-command stream (`Parallel = true`,
  `WorkerCount`). Falls back to the single-threaded path automatically.
- General-purpose parallel compute pool for running pure kernels over packed
  buffers off the main thread (`ComputeWorkers`, `Ro2D.Compute`).
- Bitmap text: `Assets.LoadFont`, `Draw.Text`, and `Draw.MeasureText` with
  area-coverage sampling for consistent stroke weight at any scale.
- Rotated primitives: `Draw.RectRotated` and `Draw.SpriteEx` (rotation, scale,
  flip, tint, alpha), alpha-blended over the scene.
- Fixed internal resolution with letterboxing, plus a `Fill` mode that fixes
  height and extends width to the viewport.
- `Isolate2D` mode: scriptable camera, character/CoreGui lockout, and default
  camera-control keys freed for 2D use.
- System helpers: `SetBackground`, `SetImmediateMode`, `SetResolution`,
  `SetOverlay`, `SetTint`, and `ScreenToCanvas`.

### Changed
- Removed `RenderScale`. The engine now renders either at native canvas size or
  at a fixed `Resolution`.
- Faster solid-sprite blit via per-row span copies.

### Tooling
- `tools/bake_font.py` compiles a TTF/OTF into the bitmap-font module format
  read by `Assets.LoadFont`, alongside the existing `tools/png2lua.py` sprite
  packer. Both are required to author assets for the engine.
- GitHub Actions build the distributable `.rbxm` model and attach it to each
  tagged release; a CI workflow builds the project on every push.

[0.3.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.3.0
[0.2.3]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.3
[0.2.2]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.2
[0.2.1]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.1
[0.2.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.0
[0.1.1]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.1.1
[0.1.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.1.0
