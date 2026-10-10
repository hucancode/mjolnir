---
title: Engine
---

Layer 3, optional. The `mjolnir` package is a reference run loop plus
glTF assembly and a few spawn helpers. It owns the default
`platform`, `world`, `render` and `ui`. It provides no glue between
modules: the per-tick hops (world → render, physics → world,
animation → render) are user code in the `update` callback — see
[glue](glue.html). Everything here is built on public layer-2 APIs,
so any of it can be rewritten in user code.

```odin
Engine :: struct {
  platform:          platform.Platform,
  world:             world.World,
  render:            render.Manager, // owns the Vulkan context, swapchain and frame
  ui:                ui.System,
  input:             input.State,    // this tick's snapshot
  mouse_captured:    bool,           // a UI owns the mouse this tick
  keyboard_captured: bool,           // a UI owns the keyboard this tick
  camera_controller: render.CameraController,
  // user callbacks, timing, debug UI flags, user_data
}
```

## Entry point

`mjolnir.run_app(RunConfig)` allocates the engine, installs a logger,
runs the loop and tears down on exit. The config takes user callbacks
(`setup`, `update`, `pre_render`, `post_render`) plus a
`user_data: rawptr` for app state.

For a hand-rolled lifecycle, call `init` → loop → `shutdown` yourself.

## Frame timeline

```
update:  input snapshot → debug UI / ui input → camera controller → update callback → render.update
render:  poll events → throttle to RENDER_FPS → ui stage → pre_render
         → render.frame → post_render
```

The `update` callback is where the application steps its own systems
and runs the glue, typically ending with `world.update` and the world
→ render feed.

## Levels

`mjolnir.setup` and `mjolnir.teardown` set up and tear down one level.
`teardown` clears the scene graph, every render slot and the cameras;
`setup` recreates render's level state, loads the environment map and
calls the `setup` callback. Call them from the `update` callback, not
`pre_render` / `post_render` (the render thread is building UI
there). To reload a level from a button or key, set a flag and act on
it at the top of the next update:

```odin
update :: proc(e: ^mjolnir.Engine, dt: f32) {
  if reset_requested {
    reset_requested = false
    mjolnir.teardown(e)
    mjolnir.setup(e)
    return
  }
  // ...
}
```
 State the application
owns (physics, navigation, animators) is torn down by the
application.

## Input

At the start of every update tick the engine snapshots the platform's
accumulator into `engine.input` and feeds it to the debug UI
(`render.debug_ui_input`) and the retained UI (`ui.process_input`,
skipped while the debug UI owns the mouse). It then sets
`engine.mouse_captured` and `engine.keyboard_captured` when either UI
owns that device. Read input in `update`:

```odin
update :: proc(e: ^mjolnir.Engine, dt: f32) {
  if !e.keyboard_captured && input.key_pressed(&e.input, .SPACE) do jump()
}
```

## Camera controller

`engine.camera_controller` drives the main camera every tick from
`engine.input`, ignoring captured devices; it starts as
`render.orbit_controller()`. Assign `render.free_controller()`,
`render.follow_controller(...)` or your own to switch, or `{}` to
disable it. Tune the active one through its data, e.g.
`&engine.camera_controller.data.(render.FreeCameraData)`, and its
keys through `engine.camera_controller.bindings`.

## Helpers

| Proc | Does |
|---|---|
| `spawn`, `spawn_mesh`, `spawn_primitive_mesh`, `spawn_ground` | world node + render attachment at its slot |
| `load_gltf` | world nodes + render meshes / materials / textures + animation rigs |
| `cursor_world_ray` | ray from the main camera through `engine.input.cursor` |

`load_gltf` returns a `GltfScene{roots, rigs, skinned}`. It parses the
file, lets `render/gltf` (`load_meshes`) create one render mesh per
glTF mesh and `animation/gltf` (`load_rig`) one `animation.Rig` per
skin with every animation as a clip, then builds the world nodes;
`skinned` pairs each skinned node with its rig. Use the two loaders
directly to import into a single module. The caller creates the
animators and frees the scene with `gltf_scene_destroy`.

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
