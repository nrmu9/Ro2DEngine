# Changelog

All notable changes to Ro2D are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.1]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.1.1
[0.1.0]: https://github.com/nrmu9/Ro2DEngine/releases/tag/v0.1.0
