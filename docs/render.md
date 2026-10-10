---
title: Render
---

Layer 2. GPU-driven, bindless, deferred-shading renderer, and the
owner of every look: meshes, materials, textures, sprites, emitters,
force fields, lights and cameras. It is the only module that uses
Vulkan. User code picks material types, light kinds and a
post-process stack; the pipeline itself is fixed.

## Lifecycle

`render.Manager` owns the Vulkan context, the swapchain and the
frame-in-flight index. Render never sees a window; the caller passes
in what the windowing library provides:

```odin
render.create_instance(&r, title, platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr())
surface := platform.create_surface(&p, render.vulkan_instance(&r))
render.init(&r, surface, platform.framebuffer_size(&p), platform.dpi_scale(&p))
render.setup(&r)
// every frame
render.frame(&r, platform.framebuffer_size(&p), platform.dpi_scale(&p), debug_ui_enabled)
// level change
render.teardown(&r)
render.setup(&r)
// exit
render.teardown(&r)
render.shutdown(&r)
```

- `init` / `shutdown` create and destroy the device, swapchain, pass
  pipelines and resource pools.
- `setup` / `teardown` create and destroy per-level state: bindless
  arrays, cameras, scene buffers. `teardown` waits for the GPU, then
  frees every slot and pending deferred release.
- `frame` uploads staged changes, acquires a swapchain image
  (recreating the swapchain when the framebuffer size changed),
  records every pass, submits, presents and retires deferred GPU
  resources.

## Transform slots

Render draws *instances*. An instance lives at a `u32` transform slot
and holds one `Attachment` (mesh, sprite, light, emitter or force
field). Render does not know where slots come from; by convention
slot = world node index.

- `render.attach(&r, slot, attachment)` sets what a slot draws.
- `render.stage_transform(&r, slot, world_matrix, visible)` moves it.
- `render.stage_bones(&r, slot, matrices)` uploads a skin palette.
- `render.stage_slot_removal(&r, slot)` frees it.

All of these are thread-safe and callable from the update thread.

## Resources

- **Meshes.** `render/mesh` defines the vertex format (`Vertex`,
  `SkinningData`, `Geometry`), primitive builders (`make_cube`,
  `make_sphere`, `make_capsule`, …) and `from_triangles` for plain
  position + index data. `render.create_mesh(&r, geometry)` uploads
  one into the mesh arena. Builtin primitives are in
  `get_builtin_mesh`.
- **Textures.** `create_texture_from_path` / `create_texture_from_data`
  return a bindless `Texture2DHandle`; `destroy_texture` releases it.
- **Materials.** `create_material` and the `material_pbr`,
  `material_textured`, `material_unlit`, `material_wireframe`,
  `material_transparent` shorthands.
- **Sprites, emitters, force fields, lights.** `create_*` plus the
  matching `*_attachment` helpers.

`render.stats(&r)` reports texture, mesh, material and slot counts
and the main camera's opaque draw count.

## Staging

Every mutation marks an entry dirty in a mutex-guarded staging set.
`render.frame` uploads dirty entries once per frame on the render
thread. An update is re-uploaded until every frame in flight has it;
removals wait `FRAMES_IN_FLIGHT` frames before GPU memory is reused.

## Subpackages

- **`render/gpu`** is the Vulkan layer. It imports only Vulkan and
  `core`, and codifies the patterns render relies on without hiding
  Vulkan:
  - `GPUContext` (instance, device, queues, descriptor and command
    pools) and `Swapchain` (frames-in-flight fences and semaphores).
  - `MutableBuffer(T)` (host-visible, mapped) and `ImmutableBuffer(T)`
    (device-local, uploaded through a staging buffer); images,
    samplers, shader modules, pipeline helpers.
  - Deferred destruction: resources queued with `defer_destroy_*`
    are released once the GPU is past every frame that could use
    them.
  - The bindless mechanism: `create_descriptor_array_layout` makes
    `PARTIALLY_BOUND` descriptor arrays, and
    `write_descriptor_array_element` fills one slot.
- **`render/bindless`** defines render's arrays on top of that
  mechanism: the 2D texture, cube texture and sampler arrays
  (`TextureManager`), the mesh arena (`MeshManager`: shared vertex,
  index and skinning buffers sub-allocated by a slab allocator) and
  the scene descriptor set.
- **`render/mesh`** is the mesh format described above. It is plain
  data with no Vulkan, so tools and tests can build geometry without
  a device.
- One subpackage per pass: `geometry`, `ambient`, `direct_light`,
  `shadow`, `forward`, `particles_*`, `occlusion_culling`,
  `depth_pyramid`, `debug_line`, `post_process`, `ui`.

Design choices in `render/gpu`:

- **No render graph, no auto-barrier inference.** Passes record their
  own barriers. Easier to reason about, easier to debug in RenderDoc.
- **Dynamic rendering only.** No `VkRenderPass` / `VkFramebuffer`.
- **Pre-baked pipeline state.** Common rasterizer, blend and depth
  states are `ALL_CAPS` constants so pipelines compose declaratively.

## Frames in flight

`FRAMES_IN_FLIGHT = 2` by default. Per-frame resources are indexed by
the frame-in-flight index. Anything the GPU might still be reading
must outlive that window.

## Bindless + GPU-driven culling

A draw is "indirect dispatch + bindless indices"; there is no
per-mesh descriptor binding. Visibility culling runs as a compute
pass per camera (frustum + depth-pyramid occlusion) and writes the
indirect draw commands the next graphics pass consumes.

## Why deferred + light volumes

Forward shading scales as `pixels × lights`. The deferred pass writes
a G-buffer (position, normal, albedo, metallic-roughness, emissive,
depth) once per visible fragment, then runs one fullscreen ambient
pass (IBL + BRDF LUT) plus a per-light volume pass for each direct
light. The IBL environment map is the HDR file passed to `render.init`
(`environment_map_path`, default `assets/Cannon_Exterior.hdr`). A light's volume (sphere for point, cone for spot, fullscreen
triangle for directional) is rasterized with reversed depth test so
only fragments actually reached by that light get shaded.

## Shadows

- **2D shadow maps** for directional + spot lights. One compute pass
  per light clips draws against the light frustum; one depth-only
  graphics pass writes a 512² R32_SFLOAT slice.
- **Cubemap shadow maps** for point lights. One compute pass clips
  against the light's sphere; one geometry-shader-amplified draw
  writes all six faces. Requires
  `-define:REQUIRE_GEOMETRY_SHADER=true` at build time.

Shadow buffers are allocated lazily on the first cast and released
when the light's slot is removed.

## Cameras

`render.create_camera` makes a camera with its own per-frame
attachments and a `PassTypeSet`. The main camera is presented to the
swapchain. `render.camera_attachment(&r, cam, .FINAL_IMAGE, frame)`
returns a bindless handle — feed it to a UI quad or a material for
minimaps, mirrors and render-to-texture surfaces.

Controllers (`orbit_controller`, `free_controller`,
`follow_controller`) are plain values that drive a camera from a
`CameraInput` (deltas, scroll, movement axes) via
`camera_controller_update`. Render does not store them; the caller
owns one (the engine keeps `Engine.camera_controller`). The orbit
controller reads distance, yaw and pitch from the camera's pose each
tick, so moving the camera directly never makes it snap back.

## UI and debug UI

The UI pass draws two things with one pipeline:

- **Game UI.** `render.stage_ui(&r, commands)` takes `draw2d`
  commands (from the `ui` module or anywhere else);
  `stage_ui_font_atlas` uploads the glyph atlas.
- **Debug UI.** A microui context owned by render. Build it between
  `debug_ui_begin` and `debug_ui_end` (`debug_ui(&r)` returns the
  context); it is drawn when `frame` gets `debug_ui_enabled`.
  `debug_ui_wants_mouse` / `debug_ui_wants_keyboard` report whether
  the panel has the input focus. Feeding it input is the caller's
  job; the engine adapts platform events.

## Debug drawing

`debug_segment`, `debug_aabb`, `debug_sphere`, `debug_arrow`,
`debug_axes` and friends queue line primitives for the current frame.

## Post-process

Each camera has an effect stack pushed via
`render.post_process.add_*`. Effects run in insertion order inside
the `POST_PROCESS` pass: tonemap, bloom, blur, fog, outline, DoF,
crosshatch, grayscale.
