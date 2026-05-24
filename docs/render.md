---
title: Render
---
# Render Module (`mjolnir/render/*`)

The Render module provides rendering subsystems including geometry rendering, lighting, shadows, transparency, particles, post-processing, and camera management.

## Post-Processing

```odin
import post_process "../../mjolnir/render/post_process"

// Add crosshatch effect
post_process.add_crosshatch(&engine.render.post_process, {800, 600})
```

## Camera Configuration

```odin
// Toggle visibility culling stats
engine.render.visibility.stats_enabled = false

// Access main camera
camera, _ := mjolnir.main_camera(engine)
```

## Custom Cameras

Create additional cameras for render-to-texture effects:

```odin
// Create secondary camera
secondary_camera := mjolnir.create_camera(
  engine,
  width  = 1024,
  height = 1024,
  enabled_passes = {.GEOMETRY, .LIGHTING},
  position = {0, 5, 10},
  target   = {0, 0, 0},
  fov      = math.PI * 0.5,
  near_plane = 0.1,
  far_plane  = 100.0,
)

// Get camera attachment for use as a bindless texture
color_attachment, ok := mjolnir.get_camera_attachment(
  engine, secondary_camera, .FINAL_IMAGE, engine.frame_index,
)
// Use `color_attachment` as a texture in a material — see render_to_texture example
```

## Render Passes

Cameras can selectively enable render passes:

```odin
world.PassType:
  .SHADOW         // Shadow map generation
  .GEOMETRY       // Opaque geometry
  .LIGHTING       // Lighting calculations
  .TRANSPARENCY   // Transparent objects
  .PARTICLES      // Particle systems
  .POST_PROCESS   // Post-processing effects
```

## Material Types

Different material types control how objects are rendered:

```odin
// PBR material (default)
mjolnir.material_pbr(engine, metallic = 0.8, roughness = 0.2)

// Random color (debugging)
mjolnir.create_material(engine, type = .RANDOM_COLOR)

// Line strip rendering
mjolnir.create_material(
  engine,
  type              = .LINE_STRIP,
  base_color_factor = {1.0, 0.8, 0.0, 1.0},
)
```

## Shadows

```odin
// Lights with shadow casting (color.w doubles as intensity)
dir := mjolnir.spawn_light_directional(engine,
  position = {0, 10, 0}, color = {1, 1, 1, 10.0},
  radius = 12, cast_shadow = true)

point := mjolnir.spawn_light_point(engine,
  position = {5, 3, 5}, color = {1, 0.8, 0.6, 100.0},
  radius = 8, cast_shadow = true)

spot := mjolnir.spawn_light_spot(engine,
  position = {0, 10, 0}, color = {0.8, 0.9, 1, 50.0},
  radius = 20, angle = math.PI * 0.25, cast_shadow = true)

// Per-mesh shadow casting
mesh_attachment := world.MeshAttachment{
  handle      = mesh,
  material    = material,
  cast_shadow = true,
}
```

For internals (passes, BVH culling, staging) see
[architecture.html](architecture.html).
