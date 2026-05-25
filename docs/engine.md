---
title: Engine
---

Layer 3. Owns the window, GPU context, swapchain, frames-in-flight,
and the main loop. Wires `world`, `render`, `physics`, `navigation`,
and `ui` into a single `Engine` value without ever leaking their
internals back through.

## Entry point

`mjolnir.run_app(RunConfig)` allocates the engine, installs a logger,
runs the loop, tears down on exit. The config takes user callbacks
(`setup`, `update`, `pre_render`, `post_render`, input handlers) plus a
`user_data: rawptr` for app state — that way user code avoids
file-scope globals.

For a hand-rolled lifecycle, call `init` → loop → `shutdown` yourself.
Useful if you need to intersperse render-pass recording with your own
GPU work.

## Frame timeline

```
poll input → update_proc → world stages → throttle to RENDER_FPS
           → sync_staging_to_gpu → pre_render
           → record_frame (cull → shadow → geom → light → ...)
           → submit + present → post_render
```

See [architecture](architecture.html) for the full sequence diagram
and the staging-pipeline contract.

## Public API surface

User code imports `mjolnir` for engine lifecycle and the small set of
cross-package composites listed below, plus whichever sub-packages it
actually needs (`world`, `physics`, `navigation`, `geometry`, `gpu`,
`animation`, `render`, `render/post_process`, `ui`). Sub-package procs
take their own data pointer (`^World`, `^physics.World`,
`^NavigationSystem`), not `^Engine` — e.g. `world.spawn(&engine.world,
...)`, `physics.raycast_trigger(&engine.physics, ...)`,
`nav.find_path(&engine.nav, ...)`.

Composites that genuinely cross sub-package boundaries live in
`mjolnir/engine.odin`:

| Proc | Crosses |
|---|---|
| `spawn_static` / `spawn_dynamic` / `spawn_trigger` | world + physics |
| `viewport_to_world_ray` / `cursor_world_ray` | window DPI + main camera + world raycast |
| `build_navmesh` | NavMeshConfig translation + `nav.init` |

Engine-scope helpers that need `^Engine` directly (texture loading,
glTF, camera attachments, navmesh bake, run loop wiring) live in
`mjolnir/engine.odin`.

## Threading

- `update` runs on the main thread by default; with
  `-define:USE_PARALLEL_UPDATE=true` it moves to a dedicated thread.
- All world mutations from any thread go through a mutexed staging
  queue (`world.staging`).
- `sync_staging_to_gpu` always runs on the main thread, holding the
  staging mutex once per frame, and drains the queue.
- GPU submission uses the classic fence + semaphore double-buffer
  pattern provided by `gpu.Swapchain`.

## Allocation ownership

Engine owns: window, GPU context, swapchain, render manager, world,
UI, navigation, staging buffers, textures created via the
`create_texture`. All freed in `shutdown`.

User owns: the `^Engine` itself (you `new` it), callback function
pointers, and any `[dynamic]NodeHandle` slices returned by
`load_gltf`.
