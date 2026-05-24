---
title: render API
---
# `mjolnir/render` — API Reference

The rendering subsystem. The engine drives it for you each frame —
`engine.run` records the entire pipeline (geometry → shading → particles →
transparency → post-process → UI). User code mainly touches three things
here:

1. **Enums and flags** that describe meshes, materials, lights, and
   passes — used when you spawn nodes or build cameras.
2. **Post-process effects** — the stack you push onto your camera.
3. **Attachment lookup** — get the bindless texture of any camera's
   output (compositing minimaps, mirrors, etc.).

The render manager itself, its sub-passes, descriptor sets, push
constants, and pipeline layouts are engine internals. Read
`mjolnir/render/render.odin` if you build a custom main loop instead of
calling `engine.run`.

## Capacity constants

```odin
FRAMES_IN_FLIGHT      :: 2
MAX_NODES_IN_SCENE    :: 65536
MAX_ACTIVE_CAMERAS    :: 128
MAX_LIGHTS            :: 256
MAX_MESHES            :: 65536
MAX_MATERIALS         :: 4096
MAX_SPRITES           :: 4096
MAX_CAMERAS           :: 64
MAX_SHADOW_MAPS       :: 16
SHADOW_MAP_SIZE       :: 512
MAX_EMITTERS          :: 64
MAX_FORCE_FIELDS      :: 32
MAX_PARTICLES         :: 65536
```

## Enums

```odin
Primitive :: enum { CUBE, SPHERE, QUAD_XZ, QUAD_XY, CONE, CAPSULE, CYLINDER, TORUS }

ShaderFeature :: enum {
  ALBEDO_TEXTURE, METALLIC_ROUGHNESS_TEXTURE, NORMAL_TEXTURE,
  EMISSIVE_TEXTURE, OCCLUSION_TEXTURE,
}

NodeFlag :: enum u32 {
  VISIBLE, CULLING_ENABLED, MATERIAL_TRANSPARENT, MATERIAL_WIREFRAME,
  MATERIAL_SPRITE, MATERIAL_RANDOM_COLOR, MATERIAL_LINE_STRIP,
  CASTS_SHADOW, NAVIGATION_OBSTACLE,
}

AttachmentType :: enum {
  POSITION, NORMAL, ALBEDO, METALLIC_ROUGHNESS, EMISSIVE,
  FINAL_IMAGE, DEPTH,
}

PassType :: enum {
  SHADOW, GEOMETRY, LIGHTING, TRANSPARENCY, PARTICLES, SPRITE,
  WIREFRAME, LINE_STRIP, RANDOM_COLOR, POST_PROCESS,
  DEBUG_UI, DEBUG_BONE, UI,
}
PassTypeSet :: bit_set[PassType]
```

`AttachmentType` names the G-buffer slots and the final composite.
`FINAL_IMAGE` is what gets presented or composited into another camera.

`PassTypeSet` controls which passes run for a given camera — shadow-only
cameras enable just `SHADOW`, minimaps drop `POST_PROCESS` and `UI`, etc.

## Light types

```odin
PointLight       :: struct { color: [4]f32, position: [3]f32, radius: f32 }
SpotLight        :: struct { color: [4]f32, position, direction: [3]f32,
                              radius, angle_inner, angle_outer: f32 }
DirectionalLight :: struct { color: [4]f32, position, direction: [3]f32, radius: f32 }
Light            :: union  { PointLight, SpotLight, DirectionalLight }
```

You don't construct these directly — spawn a light node via the
attachment helpers in `world` (`create_point_light_attachment`,
`create_spot_light_attachment`, `create_directional_light_attachment`).
The render manager mirrors them into `Light` automatically.

## Post-process effects

Each camera has an effect stack. Effects run in insertion order during
`POST_PROCESS`. The stack lives on `engine.render.post_process`.

```odin
PostProcessEffectType :: enum {
  GRAYSCALE, TONEMAP, BLUR, BLOOM, OUTLINE, FOG, CROSSHATCH, DOF, NONE,
}

GrayscaleEffect  :: struct { weights: [3]f32, strength: f32 }
ToneMapEffect    :: struct { exposure, gamma: f32 }
BlurEffect       :: struct { radius, direction, weight_falloff: f32 }   // direction: 0=H, 1=V; falloff: 0=box, 1=gaussian
BloomEffect      :: struct { threshold, intensity, blur_radius, direction: f32 }
OutlineEffect    :: struct { color: [3]f32, thickness: f32 }
FogEffect        :: struct { color: [3]f32, density, start, end: f32 }
CrossHatchEffect :: struct { resolution: [2]f32, hatch_offset_y,
                              lum_threshold_01..04: f32 }
DoFEffect        :: struct { focus_distance, focus_range, blur_strength, bokeh_intensity: f32 }
```

Push effects via convenience procs (call once in `setup_proc`):

```odin
add_grayscale       (pp, strength = 1, weights = {0.299, 0.587, 0.114})
add_blur            (pp, radius: f32, gaussian = true)
add_directional_blur(pp, radius, direction: f32, gaussian = true)
add_bloom           (pp, threshold = 1, intensity = 0.6, blur_radius = 8)
add_tonemap         (pp, exposure = 1, gamma = 1)
add_outline         (pp, thickness, color: [3]f32)
add_fog             (pp, color, density, start, end: f32)
add_crosshatch      (pp, resolution: [2]f32, hatch_offset_y,
                     threshold_01..04: f32)
add_dof             (pp, focus_distance, focus_range, blur_strength, bokeh_intensity)

clear_effects       (pp)
```

```odin
import "mjolnir/render/post_process"

setup :: proc(engine: ^mjolnir.Engine) {
  pp := &engine.render.post_process
  post_process.add_tonemap(pp, exposure = 1.2)
  post_process.add_bloom(pp, threshold = 1.0, intensity = 0.5)
  post_process.add_outline(pp, thickness = 1.0, color = {0, 0, 0})
}
```

## Camera attachments

```odin
mjolnir.get_camera_attachment(engine, camera_handle, attachment_type,
                              frame_index = 0)
                             -> (gpu.Texture2DHandle, bool)
```

Returns the bindless texture handle for any of the `AttachmentType`
slots of a camera. Use it to composite a secondary camera (minimap,
mirror, security cam) into the main view by binding the returned handle
to a UI quad or material.

## Visibility stats (debug)

```odin
VisibilityStats :: struct {
  opaque_draw_count: u32,
  camera_index:      u32,
  frame_index:       u32,
}

visibility_stats           (manager, camera_index, frame_index: u32) -> VisibilityStats
set_visibility_stats_enabled(manager, enabled: bool)
```

Enable once at startup, then read per-frame to track how many opaque
draws survived culling for a given camera.

## Building a custom render loop

The default `engine.run` records everything. If you instead drive the
loop yourself (`init` → your own loop → `shutdown`), the public entry
point is `record_frame` on the manager. Sub-pass record procs
(`record_geometry_pass`, `record_lighting_pass`, …) are also exported so
you can intersperse your own work. Their signatures, push-constant
layouts, and descriptor requirements live in `mjolnir/render/render.odin`
and the per-renderer files under `mjolnir/render/*/`.
