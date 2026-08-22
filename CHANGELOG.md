# Changelog

All notable changes to Ro2D are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.3] - 2026-08-22

### Fixed
- Chunks of the screen that never update, go black, or hold an old frame while
  everything around them runs. Nothing released an EditableImage: the canvas, the
  UI layer and each render worker's band were all left to be collected. The grid
  is rebuilt on every resize, so the shared budget ran out, `CreateEditableImage`
  started answering nil, and a chunk holding nil cannot be drawn to. Mostly seen
  on phones, where the budget is smallest and resizes are commonest.
- `CreateEditableImage` is checked on the canvas and the UI layer, as it already
  was in the workers. A refused chunk is skipped rather than raising every frame,
  and the grid warns once with how many it lost.

### Added
- Chunk and UI buffers are tagged with `debug.setmemorycategory`, so they are
  attributed in the Developer Console rather than sitting in untagged Luau heap.

## [0.5.2] - 2026-08-12

### Fixed
- `Draw.Pixel`, `Draw.LineSDF` and `Draw.CircleSDF` work on the threaded backend.
  All three were added in 0.5.0 and none has ever run: they were written against a
  single shared command buffer named `cb`, which is what this renderer had until
  each band was given its own one commit earlier, so each reached for a variable
  that no longer existed.

  Nothing raised, because nothing called them. Reading a global that was never
  declared gives nil rather than erroring, so the failure sat at the index waiting
  for a caller, and threading is the default, so the first caller to want a circle
  would have met it whichever renderer they thought they were using.

  Routed now, like every other primitive: a pixel through `Draw.Rect`, so it cannot
  land in a different band from the rect covering the same coordinate, and the two
  distance fields through the batched point run, so a figure still travels as one
  command rather than one per pixel.

- The suite calls both backends instead of reading them, which is why the gap
  survived two releases: the parity check compared function *names* found by regex,
  found all three present in both files, and never invoked one. One of its
  assertions was that the text `cb:beginPoints()` appeared in the source.

  Both renderers are now stood up outside Roblox and every published call is
  invoked on each, with a call that has no test arguments written for it counting
  as a failure. What the batching claims is read off the decoded stream: a circle
  arrives as one command carrying exactly as many squares as `Shapes` plotted.

  A `luau-lsp analyze` gate came with it. An unknown global is a lint finding, not
  a compile error, so the compile sweep could not have caught this.

## [0.5.1] - 2026-08-09

### Fixed
- A render worker now stops itself when its band is taken away. Changing the
  resolution rebuilds the bands, which destroys every worker actor and makes new
  ones -- and since menus and gameplay commonly render at different sizes, that is
  every scene change. Relying on `Destroy` to sever the frame connection is not
  enough: a callback already scheduled for that frame still runs, and reaches
  `task.synchronize` with no Actor above it, which raises rather than doing
  nothing. Each worker now disconnects on `Destroying` and on being lifted out of
  the DataModel, and checks before it synchronizes.

## [0.5.0] - 2026-08-09

### Changed
- **One renderer, two backends.** The threaded and single-threaded renderers were
  two objects handed straight to the caller, and `System.Init` swapped which one
  you held. `Draw` was *replaced*, so anything that had captured it -- or captured
  a function off it -- went on calling the backend that was no longer running.
  `System` was worse for going only one way: a threaded Init overwrote `SetTint`,
  `SetFade` and five others, and a single-threaded Init afterwards put none of
  them back, so that scene drove the threaded renderer's state and its tint and
  fade went nowhere.

  `Ro2D.Draw`, `Ro2D.System` and `Ro2D.Camera` are now tables that never change
  identity for the life of the session. Init re-points what is *inside* them, in
  both directions, every time, with no metatable fallback to a backend -- a
  fallback being exactly how a function belonging to the renderer that is not
  running survives a swap. The surface is bound to the single-threaded backend at
  require time, so it is live before Init rather than empty.
- **Threading is on by default, on four workers.** `Parallel = false` opts out and
  `WorkerCount` sets the number; a caller's own count is never overridden. It was
  off unless a caller asked, which meant the faster path was the one you had to
  know about.

### Added
- `Draw.Pixel`, `Draw.LineSDF` and `Draw.CircleSDF` on the threaded backend. All
  three are in the published API and the single-threaded renderer has always had
  them; the threaded one simply did not, so they were nil for anyone running
  threaded -- which, now that threading is the default, is everyone.

  The geometry moved to `Shapes`, shared by both, so a circle is the same circle
  either way. Only the destination differs: single-threaded it writes pixels
  straight into a chunk, threaded it fills a batched point run, so a distance
  field travels as one command rather than one per pixel.

  The suite compares the two surfaces call for call, which is how the gap was
  found in the first place, so the pair cannot drift apart again.

## [0.4.0] - 2026-08-09

### Added
- `Draw.BeginPoints()`, `Draw.Point(x, y, size, r, g, b, a?)` and `Draw.EndPoints()`
  draw many small axis-aligned squares as one command.

  A particle field is thousands of two-pixel squares, and as individual rects it
  is the most expensive thing in a frame -- not because of the pixels, which are
  trivial, but because of everything around them. Under the parallel renderer the
  command stream is serialised to a string and every worker copies and walks the
  whole of it, so one square costs twenty-one bytes and one dispatch *per
  worker*. Batched, the same field is one command, thirteen bytes each, and a
  tight loop inside the rasteriser with its buffer, band width and scissor
  hoisted once for the run.

  The side is stored as a whole pixel, which is what a rect of a fractional size
  already covered; the position stays a float, because the camera offset is
  fractional and rounding it here would make a small particle jitter by a pixel
  as the camera moves. On the single-threaded renderer the three calls are
  `Draw.Rect` and two no-ops, so a caller never has to ask which renderer it is
  talking to.

### Changed
- The parallel renderer sends each command only to the bands it touches.

  Every worker used to copy and walk the entire stream, so a command was decoded
  once per worker whether or not it landed anywhere near that worker's band:
  eight workers meant eight times the decode work for a scene and seven eighths
  of it produced nothing. On a heavy frame that is what exhausts a resumption's
  time budget, and it is why the resulting timeouts name a different primitive
  each time -- the clock stops wherever it happens to be.

  Each command is now bounded once, on the main thread, and written only into the
  bands it overlaps; a batch of points is routed per point, so a band holds its
  own particles and no others. State -- clear, tint and clip -- has no position
  and still goes to every band, and order within a band is preserved because
  every band is appended to in the order the calls arrive.

  Measured on a frame of 1400 particles, 140 rotated blocks and 220 bullets
  across eight bands: bytes copied per frame fell to 14% of before, and a band's
  decode and fill to roughly 65-85%, the remainder being the pixels themselves,
  which are the same either way.

  The bounds live in `parallel/DrawBounds` rather than inline, because the
  condition they have to meet is not obvious and is worth testing directly: a
  bound must contain every pixel the rasteriser would paint. Too generous costs a
  band a decode that paints nothing; too tight is a hole in the picture along a
  band seam, appearing at some angles and some strings and not others.
- `CommandBuffer.decode` binds the handler's methods once per stream instead of
  looking each up per command. Every worker walks every command of every frame,
  so one hash lookup per command is one per command per worker per frame.

## [0.3.1] - 2026-08-08

### Fixed
- A gamepad is found by polling the pads rather than by waiting to be told about
  one. `LastInputTypeChanged` fires when a device is *used*, and on some consoles
  pushing a stick leaves nothing else to notice: until it fired there was no pad
  and `Input.GamepadActive` stayed false, so the pad cursor never appeared and
  nothing in a menu could be clicked. The only way out was to press a button the
  player had no reason to press.

  Each frame the pad already in hand is read directly, and the full connected
  list four times a second; whichever pad is deflected is the one in hand. That
  needs no event to have fired, it corrects a pick made during the join race when
  the connected list was still empty, and it follows a player who puts one pad
  down and picks another up.

  The flag is only ever turned on this way. A mouse, a keyboard or a touch turns
  it off, and a stick returning to centre is not one of those.

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

[0.5.3]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.5.3
[0.5.2]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.5.2
[0.5.1]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.5.1
[0.5.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.5.0
[0.4.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.4.0
[0.3.1]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.3.1
[0.3.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.3.0
[0.2.3]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.3
[0.2.2]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.2
[0.2.1]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.1
[0.2.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.2.0
[0.1.1]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.1.1
[0.1.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.1.0
