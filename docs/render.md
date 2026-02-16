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

// Access camera-specific rendering
camera := cont.get(engine.world.cameras, engine.world.main_camera)
```

## Custom Cameras

Create additional cameras for render-to-texture effects:

```odin
// Create secondary camera
secondary_camera, ok := mjolnir.create_camera(
  engine,
  width = 1024,
  height = 1024,
  enabled_passes = {.SHADOW, .GEOMETRY, .LIGHTING},
  position = {0, 5, 10},
  target = {0, 0, 0},
  fov = 1.57079632679,
  near_plane = 0.1,
  far_plane = 100.0,
)

// Get camera attachment for use as texture
color_attachment, ok := mjolnir.get_camera_attachment(
  engine,
  secondary_camera,
  .COLOR,
  frame_index = 0,
)

// Use attachment as texture in material
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
  cast_shadow = true, // Enable shadows
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
  cast_shadow = true, // This mesh casts shadows
}
```

## Rendering Architecture

The render system is organized into subsystems:

- **Geometry Renderer**: Handles opaque geometry with PBR materials
- **Lighting/Shadow Renderer**: Computes lighting and shadow maps
- **Transparency Renderer**: Renders transparent objects with proper blending
- **Particle Renderer**: GPU-based particle systems
- **Post-process Renderer**: Screen-space effects
- **Camera/Visibility**: Frustum culling and visibility determination
- **UI Renderer**: 2D overlay rendering

Too lazy to go into detail now :(
