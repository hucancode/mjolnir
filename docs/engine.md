---
title: Engine
---

Layer 3. The `mjolnir` package owns the default `platform`, `world`,
`render` and `ui`, runs the main loop, and hosts the few helpers that
span two or more layer-2 modules. Everything here is built on public
layer-2 APIs, so any of it can be rewritten in user code.

```odin
Engine :: struct {
  platform: platform.Platform,
  world:    world.World,
  render:   render.Manager, // owns the Vulkan context, swapchain and frame
  ui:       ui.System,
  // user callbacks, timing, debug UI flags, user_data
}
```

## Entry point

`mjolnir.run_app(RunConfig)` allocates the engine, installs a logger,
runs the loop and tears down on exit. The config takes user callbacks
(`setup`, `update`, `sync`, `pre_render`, `post_render`, input
handlers) plus a `user_data: rawptr` for app state.

For a hand-rolled lifecycle, call `init` → loop → `shutdown` yourself.

## Frame timeline

```
update:  input → main camera controller → update → world.update → sync → render.update
render:  poll events → throttle to RENDER_FPS → ui stage → pre_render
         → render.frame → post_render
```

`sync` is where the application moves world and animation results
into render — see [glue](glue.html).

## Input

`platform.Input` holds the per-tick snapshot; query it directly with
`platform.input_key_down(&engine.platform.input, .W)` and friends.
Once per tick the engine dispatches edges to the `key_press`,
`mouse_press`, `mouse_move` and `mouse_scroll` callbacks, withholding
what the debug UI captures: a mouse button pressed over the debug UI
belongs to it until released (`UICapture`), and keys are withheld
while it has keyboard focus. Platform events also feed the debug
UI's microui context as they arrive.

## Inter-module helpers

| Proc | Crosses |
|---|---|
| `spawn`, `spawn_mesh`, `spawn_primitive_mesh`, `spawn_ground`, `spawn_sprite`, `spawn_emitter`, `spawn_forcefield` | world node + render attachment |
| `spawn_static` / `spawn_dynamic` / `spawn_trigger`, `collider_visual_scale` | world + render + physics (body `user` = node) |
| `load_gltf` | world nodes + render meshes / materials / textures + animation rigs |
| `viewport_to_world_ray` / `cursor_world_ray` | platform DPI + cursor, render main camera |
| `debug_skeleton` | animation pose → render debug lines |

`load_gltf` returns a `GltfScene{roots, rigs, skinned}`. It creates
one render mesh per glTF mesh and one `animation.Rig` per skin with
every animation as a clip; `skinned` pairs each skinned node with its
rig. The caller creates the animators and frees the scene with
`gltf_scene_destroy`.

Single-module work goes straight to that module: `world.translate`,
`render.create_material`, `physics.raycast`, `nav.find_path`, …

## Threading

- `update` runs on the main thread by default; with
  `-define:USE_PARALLEL_UPDATE=true` it moves to a dedicated thread.
- World and animators are touched only from the update thread.
- Render's `stage_*` / `attach` calls are mutex-guarded, so the update
  thread can call them while the render thread runs `render.frame`.

## Allocation ownership

Engine owns: platform, world, render, UI. All freed in `shutdown`.

User owns: the `^Engine` when not using `run_app`, animators, physics
worlds and bodies, navmeshes and crowds, and the `GltfScene` returned
by `load_gltf`.
