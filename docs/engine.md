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

## Engine-rooted shortcuts

Every `world.*` / `physics.*` / `nav.*` proc that takes a `^World` /
`^physics.World` / `^NavigationSystem` has a sibling on `mjolnir.*`
taking `^Engine`. Pure forwarders — they exist only so user code can
write `mjolnir.spawn(engine, ...)` instead of
`world.spawn(&engine.world, ...)`. Full list in
`mjolnir/shortcuts.odin`.

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
`create_texture_*` shortcuts. All freed in `shutdown`.

User owns: the `^Engine` itself (you `new` it), callback function
pointers, and any `[dynamic]NodeHandle` slices returned by
`load_gltf`.
