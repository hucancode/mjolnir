# Render Module (`mjolnir/render/*`)

The Render module provides rendering subsystems including geometry rendering, lighting, shadows, transparency, particles, post-processing, and camera management. It is driven by a **declarative frame graph** that handles resource lifetime, barrier inference, and pass scheduling automatically.

## Rendering Architecture

The render system is organized as a set of sub-module renderers coordinated by a frame graph:

- **`render/geometry`** — Opaque PBR geometry
- **`render/ambient`** — Ambient lighting pass
- **`render/direct_light`** — Per-light (point/spot/directional) direct lighting
- **`render/shadow_render`** / **`render/shadow_sphere_render`** — Shadow map generation
- **`render/shadow_culling`** / **`render/shadow_sphere_culling`** — GPU shadow cull per light
- **`render/occlusion_culling`** — GPU occlusion cull per camera
- **`render/depth_pyramid`** — Hierarchical depth pyramid for occlusion queries
- **`render/transparent`** — Transparent/blended objects
- **`render/particles_compute`** / **`render/particles_render`** — GPU particle simulation and rendering
- **`render/post_process`** — Screen-space post-processing effects
- **`render/ui`** — 2D overlay rendering

## Frame Graph

The frame graph is compiled from **pass declarations** before the first frame and recompiled whenever the scene topology changes (camera or light count changes).

### Pass Scopes

Each pass runs at one of five scopes:

```odin
rg.PassScope :: enum {
  GLOBAL,               // Runs once per frame
  PER_CAMERA,           // Runs once per active camera
  PER_POINT_LIGHT,      // Runs once per active point light
  PER_SPOT_LIGHT,       // Runs once per active spot light
  PER_DIRECTIONAL_LIGHT // Runs once per active directional light
}
```

### Pass Declaration Pattern

Each render sub-module declares its resources and execute callback:

```odin
PassDecl :: struct {
  name:              string,
  queue:             QueueType, // .GRAPHICS or .COMPUTE
  scope:             PassScope,
  declare_resources: PassSetupProc,  // proc(setup: ^PassSetup, builder: ^PassBuilder)
  execute:           PassExecuteProc, // proc(ctx: rawptr, resources: ^PassResources, cmd: vk.CommandBuffer, fi: u32)
}
```

### Resource Declaration

During `declare_resources`, passes declare what they read, write, and create:

```odin
declare_resources :: proc(setup: ^rg.PassSetup, builder: ^rg.PassBuilder) {
  // Create a graph-owned texture (auto-scoped to this pass's scope)
  gbuffer_color := rg.create_texture(setup, builder, "gbuffer_color", rg.TextureDesc{
    width  = setup.camera_extents[setup.instance_idx].width,
    height = setup.camera_extents[setup.instance_idx].height,
    format = .R8G8B8A8_SRGB,
    usage  = {.COLOR_ATTACHMENT, .SAMPLED},
    aspect = {.COLOR},
  })

  // Declare write access
  rg.write_texture(builder, gbuffer_color)

  // Register external resource (managed outside the graph)
  depth := rg.register_external_texture(setup, builder, "depth", rg.TextureDesc{...})

  // Declare read access on a resource from another scope
  shadow_map := rg.read_texture_by_name(setup, builder, "shadow_map_spot_0")
}
```

### Resource Naming

Resources are auto-scoped by the graph based on their pass scope:
- `"gbuffer_color"` declared in a `PER_CAMERA` pass at instance 0 → `"gbuffer_color_cam_0"`
- Cross-scope reads use explicit scoped names: `"shadow_map_spot_0"`, `"gbuffer_cam_1"`

### Execute Callback

At runtime, execute callbacks resolve resources by name:

```odin
execute :: proc(ctx: rawptr, resources: ^rg.PassResources, cmd: vk.CommandBuffer, fi: u32) {
  // Resolve texture as VkImage for attachment
  color_image := rg.get_texture_image(resources, "gbuffer_color", fi)
  depth_image := rg.get_texture_image(resources, "depth", fi)

  // Resolve buffer
  vertex_buf := rg.get_buffer(resources, "vertex_buffer")

  // Scope is embedded in resources — simple names auto-resolve
}
```

### Execute Loop

The engine drives the frame graph using a pass iterator:

```odin
iter := rg.make_pass_iterator(
  &self.render.frame_graph,
  self.frame_index,
  graphics_cmd,
  compute_cmd,
)
for {
  pass := rg.next_pass(&iter) or_break
  pass.execute(&self.render, &iter.resources, iter.cmd, self.frame_index)
  rg.pass_done(&iter)
}
```

### External Resource Updates

Before each frame, external resources (swapchain, depth buffer) must be updated:

```odin
rg.update_external_texture(&render.frame_graph, "swapchain", image, view)
rg.update_external_texture(&render.frame_graph, "depth", depth_image, depth_view)
```

## Post-Processing

```odin
import post_process "../../mjolnir/render/post_process"

// Add crosshatch effect
post_process.add_crosshatch(&engine.render.post_process, {800, 600})
```

## Material Types

Different material types control how objects are rendered:

```odin
// PBR material (default)
world.create_material(
  &engine.world,
  type = .PBR,
  metallic_value = 0.8,
  roughness_value = 0.2,
)

// Random color (debugging)
world.create_material(
  &engine.world,
  type = .RANDOM_COLOR,
)

// Line strip rendering
world.create_material(
  &engine.world,
  type = .LINE_STRIP,
  base_color_factor = {1.0, 0.8, 0.0, 1.0},
)
```

## Shadows

```odin
// Enable shadow casting for lights
directional_light := world.create_directional_light_attachment(
  {1.0, 1.0, 1.0, 1.0},
  intensity = 10.0,
  cast_shadow = true,
)

point_light := world.create_point_light_attachment(
  {1.0, 0.8, 0.6, 1.0},
  intensity = 100.0,
  cast_shadow = true,
)

spot_light := world.create_spot_light_attachment(
  {0.8, 0.9, 1.0, 1.0},
  intensity = 50.0,
  outer_cone_angle = math.PI * 0.25,
  cast_shadow = true,
)

// Enable shadow casting for meshes
mesh_attachment := world.MeshAttachment{
  handle = mesh,
  material = material,
  cast_shadow = true,
}
```

## Render Pass List

The 19 declared passes in execution order:

| Pass | Scope | Queue |
|------|-------|-------|
| `particles_compute` | GLOBAL | Compute |
| `depth_pyramid` | PER_CAMERA | Compute |
| `occlusion_culling` | PER_CAMERA | Compute |
| `shadow_culling_spot` | PER_SPOT_LIGHT | Compute |
| `shadow_culling_directional` | PER_DIRECTIONAL_LIGHT | Compute |
| `shadow_culling_sphere` | PER_POINT_LIGHT | Compute |
| `shadow_render_spot` | PER_SPOT_LIGHT | Graphics |
| `shadow_render_directional` | PER_DIRECTIONAL_LIGHT | Graphics |
| `shadow_render_sphere` | PER_POINT_LIGHT | Graphics |
| `geometry` | PER_CAMERA | Graphics |
| `ambient` | PER_CAMERA | Graphics |
| `direct_light_point` | PER_CAMERA | Graphics |
| `direct_light_spot` | PER_CAMERA | Graphics |
| `direct_light_directional` | PER_CAMERA | Graphics |
| `particles_render` | PER_CAMERA | Graphics |
| `transparent` | PER_CAMERA | Graphics |
| `post_process` | GLOBAL | Graphics |
| `ui` | GLOBAL | Graphics |
| `debug_ui` | GLOBAL | Graphics |

## Graph Rebuild

The frame graph is automatically rebuilt when scene topology changes:

```odin
// Trigger on next frame
engine.render.force_graph_rebuild = true
```

Rebuild happens automatically when a camera or light is added/removed.
