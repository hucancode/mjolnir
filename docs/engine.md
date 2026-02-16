# Engine Module (`mjolnir`)

The Engine module is the main entry point for Mjolnir applications. It manages initialization, the main loop, and provides unified access to all subsystems (world, physics, navigation, rendering, UI).

## Basic Application Structure

```odin
import "../../mjolnir"
import "../../mjolnir/world"

main :: proc() {
  engine := new(mjolnir.Engine)

  // Setup phase - called once before main loop
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    // Create primitive mesh
    mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)

    // Position camera
    world.main_camera_look_at(&engine.world, {3, 2, 3}, {0, 0, 0})
  }

  // Update phase - called every frame
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Update game logic here
  }

  // Start the engine
  mjolnir.run(engine, 800, 600, "My App")
}
```

## Input Handling

```odin
// Handle keyboard input
engine.key_press_proc = proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  if action == 1 { // Key press
    switch key {
    case '1': log.info("Key 1 pressed")
    case 32: log.info("Space pressed")
    }
  }
}

// Handle mouse input
engine.mouse_press_proc = proc(engine: ^mjolnir.Engine, button, action, mods: int) {
  if action == 1 { // Mouse button press
    mouse_x, mouse_y := glfw.GetCursorPos(engine.window)
  }
}
```

## Loading GLTF Models

```odin
nodes: [dynamic]world.NodeHandle

engine.setup_proc = proc(engine: ^mjolnir.Engine) {
  // Load GLTF file - returns root nodes
  nodes = mjolnir.load_gltf(engine, "assets/Duck.glb")

  // Iterate through loaded nodes
  for handle in nodes {
    node := cont.get(engine.world.nodes, handle) or_continue
    log.infof("Loaded node: %s", node.name)
  }
}

engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Animate loaded models
  rotation := delta_time * math.PI * 0.5
  for handle in nodes {
    world.rotate_by(&engine.world, handle, rotation)
  }
}
```

## Creating Primitive Meshes

```odin
// Simple one-liner with all defaults
cube := mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)

// With position, rotation, and scale
sphere := mjolnir.spawn_primitive_mesh(
  engine,
  primitive = .SPHERE,
  color = .BLUE,
  position = {0, 5, 0},
  rotation_angle = math.PI * 0.25,
  rotation_axis = {0, 1, 0},
  scale_factor = 2.0,
  cast_shadow = true,
)
```

## Subsystem Access

The Engine provides access to all major subsystems:

```odin
engine.world       // Scene graph, nodes, meshes, materials
engine.render      // Rendering subsystems (lighting, post-process, etc.)
engine.gctx        // GPU context (Vulkan)
engine.ui          // UI system for 2D elements
engine.nav         // Navigation (navmesh, pathfinding)
engine.window      // GLFW window handle
```

## Texture Management

```odin
// Load texture from file
texture, ok := mjolnir.create_texture_from_path(
  engine,
  "assets/image.png",
  format = .R8G8B8A8_SRGB,
  generate_mips = true,
)

// Create empty texture for render targets
render_target, ok := mjolnir.create_texture_empty(
  engine,
  width = 1024,
  height = 1024,
  format = .R8G8B8A8_SRGB,
  usage = {.COLOR_ATTACHMENT, .SAMPLED},
)
```
