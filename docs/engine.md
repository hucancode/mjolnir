---
title: Engine
---
# Engine Module (`mjolnir`)

The Engine module is the entry point for Mjolnir applications. It owns the
window, GPU context, swapchain, frames-in-flight, the main loop, and wires
together all subsystems (world, physics, navigation, rendering, UI).

## Basic Application Structure

The recommended entry point is `mjolnir.run_app`, which allocates the
engine, installs a console logger, drives the main loop, and tears down on
exit.

```odin
package main

import "../../mjolnir"

main :: proc() {
  mjolnir.run_app({
    title  = "My App",
    width  = 800, height = 600,
    setup  = proc(engine: ^mjolnir.Engine) {
      mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
      mjolnir.main_camera_look_at(engine, {3, 2, 3}, {0, 0, 0})
    },
    update = proc(engine: ^mjolnir.Engine, dt: f32) {
      // game logic
    },
  })
}
```

If you need a hand-rolled lifecycle, call `mjolnir.init` → loop →
`mjolnir.shutdown` yourself.

## Engine-rooted shortcuts

Every public `world.*` / `physics.*` / `nav.*` proc that takes a `^World`,
`^physics.World`, or `^NavigationSystem` has a sibling in `mjolnir.*` that
takes `^Engine`. User code says `mjolnir.spawn(engine, ...)` instead of
`world.spawn(&engine.world, ...)`. Full list: see
[`api_engine` §Shortcuts](api_engine.html#shortcuts).

```odin
mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
mjolnir.translate_by(engine, h, y = dt)
mjolnir.find_path(engine, a, b)
mjolnir.create_dynamic_body(engine, pos, rot, mass, collider)
```

## Input Handling

```odin
mjolnir.run_app({
  // ...
  key_press = proc(engine: ^mjolnir.Engine, key, action, mods: int) {
    if action == glfw.PRESS {
      switch key {
      case glfw.KEY_1:     log.info("Key 1 pressed")
      case glfw.KEY_SPACE: log.info("Space pressed")
      }
    }
  },
  mouse_press = proc(engine: ^mjolnir.Engine, button, action, mods: int) {
    if action == glfw.PRESS {
      mx, my := glfw.GetCursorPos(engine.window)
      log.infof("click at %v,%v", mx, my)
    }
  },
})
```

`engine.input.keys[KEY]` / `engine.input.mouse_buttons[BTN]` work for
polling inside `update`.

## Loading GLTF Models

```odin
nodes: [dynamic]mjolnir.NodeHandle

setup :: proc(engine: ^mjolnir.Engine) {
  nodes = mjolnir.load_gltf(engine, "assets/Duck.glb")
  for handle in nodes {
    node := mjolnir.node(engine, handle) or_continue
    log.infof("Loaded node: %s", node.name)
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  rot := dt * math.PI * 0.5
  for handle in nodes do mjolnir.rotate_by(engine, handle, rot)
}
```

## Creating Primitive Meshes

```odin
// Simple one-liner with all defaults
cube := mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)

// With position, rotation, and scale
sphere := mjolnir.spawn_primitive_mesh(
  engine,
  primitive      = .SPHERE,
  color          = .BLUE,
  position       = {0, 5, 0},
  rotation_angle = math.PI * 0.25,
  rotation_axis  = {0, 1, 0},
  scale_factor   = 2.0,
  cast_shadow    = true,
)
```

## Subsystem Access

The `Engine` struct exposes each subsystem directly:

```odin
engine.world       // Scene graph, nodes, meshes, materials, cameras
engine.render      // Rendering subsystems (lighting, post-process, etc.)
engine.gctx        // GPU context (Vulkan)
engine.ui          // 2D UI system
engine.nav         // Navigation (navmesh, pathfinding)
engine.physics     // Rigid-body physics world
engine.window      // GLFW window handle
engine.user_data   // Opaque rawptr — stash app state here
```

`engine.physics` is stepped and synced to the scene graph automatically
each tick. Spawn bodies; the engine does the rest.

## Texture Management

```odin
texture, ok := mjolnir.create_texture_from_path(
  engine, "assets/image.png",
  format = .R8G8B8A8_SRGB, generate_mips = true,
)

render_target, ok := mjolnir.create_texture_empty(
  engine,
  extent = {width = 1024, height = 1024},
  format = .R8G8B8A8_SRGB,
  usage  = {.COLOR_ATTACHMENT, .SAMPLED},
)
```

## Stashing app state with `user_data`

Pass any pointer via `RunConfig.user_data` and cast back inside callbacks:

```odin
GameState :: struct { score: i32, player: mjolnir.NodeHandle }
state: GameState

mjolnir.run_app({
  user_data = &state,
  update    = proc(e: ^mjolnir.Engine, dt: f32) {
    s := (^GameState)(e.user_data)
    s.score += 1
  },
})
```
