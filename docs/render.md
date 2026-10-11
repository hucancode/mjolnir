---
title: Render
---

Layer 2. GPU-driven, bindless, deferred-shading renderer, and the
owner of every look: meshes, materials, textures, emitters,
force fields, lights and cameras. It is the only module that uses
Vulkan. User code picks material types, light kinds and a
post-process stack; the pipeline itself is fixed.

## Lifecycle

`render.Manager` owns the Vulkan context, the swapchain and the
frame-in-flight index. Callers use the procs below only; the
`Manager` fields are render's own state. Render never sees a window; the caller passes
in what the windowing library provides:

```odin
render.init(&r, title, platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(),
            platform.create_surface, &p, platform.framebuffer_size(&p), platform.dpi_scale(&p))
render.load_environment_map(&r, "assets/Cannon_Exterior.hdr")
// every update tick
render.update(&r, dt)
// every frame
render.frame(&r, platform.framebuffer_size(&p), platform.dpi_scale(&p))
// level change
render.teardown(&r)
render.setup(&r)
// exit
render.teardown(&r)
render.shutdown(&r)
```

- `init` / `shutdown` create and destroy the instance, the window
  surface (through the `create_surface` callback, called with the
  pointer passed after it), the device, swapchain, pass pipelines and
  resource pools. `init` also sets up the first level. It returns
  false and logs the Vulkan error on failure.
- `setup` / `teardown` create and destroy per-level state: bindless
  arrays, cameras, scene buffers, the environment map. Both are safe
  to call at any point outside `frame` and are no-ops when the level
  is already in that state. `teardown` waits for every frame in
  flight, then frees every slot and pending deferred release.
- `load_environment_map(&r, path)` loads an equirectangular HDR image
  as the skybox and precomputes image-based lighting from it. Call it
  after `setup`; without one, IBL and the skybox are black.
  `r.ambient.ibl_intensity` scales the image-based lighting;
  `r.ambient.skybox_enabled`, `skybox_blur` (0..1) and
  `skybox_intensity` show or hide the skybox and set its blur and
  brightness. `setup` resets them to their defaults.
- `update(&r, dt)` advances render's own clock once per update tick:
  particle time, emitter accumulators and debug line lifetimes. The
  next frame emits and simulates everything accumulated since the
  previous one, so particles keep their speed whatever the update and
  render rates.
- `frame` closes the debug UI, uploads staged changes, acquires a
  swapchain image (recreating the swapchain when the framebuffer size
  changed), records every pass, submits, presents and retires
  deferred GPU resources. It returns false on a GPU error.
  `show_stats = true` adds a stats window to the debug UI.

## Transform slots

Render draws *instances*. An instance lives at a `u32` transform slot
and holds one `Attachment` (mesh, light, emitter or force
field). Render does not know where slots come from; by convention
slot = world node index.

- `render.attach(&r, slot, attachment)` sets what a slot draws,
  replacing what it drew before.
- `render.stage_transform(&r, slot, world_matrix, visible)` moves it.
- `render.stage_bones(&r, slot, matrices)` uploads a skin palette.
- `render.stage_slot_removal(&r, slot)` frees it.

All of these are thread-safe and callable from the update thread.

To change a look, `render.attachment(&r, slot, T)` returns a copy of
the slot's attachment of type `T`; edit its fields (light color,
radius, `disabled`, mesh handle, material, …) and pass it back to
`attach`:

```odin
if l, ok := render.attachment(&r, slot, render.PointLightAttachment); ok {
  l.color = {1, 0, 0, 1}
  render.attach(&r, slot, l)
}
```

## Resources

- **Meshes.** `render/mesh` defines the vertex format (`Vertex`,
  `SkinningData`, `Geometry`), primitive builders (`make_cube`,
  `make_sphere`, `make_capsule`, …) and `from_triangles` for plain
  position + index data.
  `render.create_mesh(&r, geometry)` uploads one into the mesh arena.
  `r.builtin_meshes[.CUBE]` is a builtin primitive and
  `r.builtin_materials[.RED]` a builtin solid color;
  `primitive(&r, shape, color)` pairs them into a `MeshAttachment`.
- **Textures.** `create_texture_from_path` / `create_texture_from_data`
  return a bindless `Texture2DHandle`; `destroy_texture` releases it.
  Textures live for one level: `teardown` destroys them all.
- **Materials.** `create_material` and the `material_pbr`,
  `material_wireframe`, `material_transparent` shorthands. Materials
  outlive `teardown`, so destroy a material that samples a texture
  before the level ends; a texture handle from an earlier level points
  at whatever the new level allocates in its place.
  `material(&r, h)` returns a `^Material`; edit it and write it back
  with `set_material(&r, h, m^)` to stage the upload.
- **Sprites.** `material_sprite(&r, texture, columns, rows, tint)`
  makes a sprite-sheet material; attach it as a `MeshAttachment` with
  `r.builtin_meshes[.QUAD_XY]` and it faces the camera.
  `set_sprite_frame(&r, material, frame)` shows one cell.
  Animate it by setting the frame as time advances.
- **Emitters, force fields.** `create_emitter` / `create_forcefield`.
  `emitter(&r, h)` / `forcefield(&r, h)` return a pointer; write
  changes back with `set_emitter` / `set_forcefield`, which keep the
  emission progress and the attached slot. Emitters are uploaded
  every frame; force field changes are staged.
- **Lights** have no resource; a light is an attachment
  (`point_light_attachment`, `directional_light_attachment`,
  `spot_light_attachment`).

`render.stats(&r)` reports texture, mesh, material and slot counts
and the main camera's opaque draw count.

## Staging

Every mutation marks an entry dirty in a mutex-guarded staging set.
`render.frame` uploads dirty entries once per frame on the render
thread. Everything the CPU can change while a frame is in flight
(node transforms, bone palettes, materials, emitters, force fields,
cameras) lives in one buffer per frame in flight; a dirty entry is
re-uploaded until every frame's copy has it. Mesh descriptions are
written once: an index is only reused after its grace period.
Freed meshes, materials, emitters and force fields hold their
slot (and a mesh its GPU memory) for `FRAMES_IN_FLIGHT + 1` frames
before reuse.

## Subpackages

- **`render/gpu`** is the Vulkan layer. It imports only Vulkan and
  `core`, and codifies the patterns render relies on without hiding
  Vulkan:
  - `GPUContext` (instance, device, queues, descriptor and command
    pools) and `Swapchain` (frames-in-flight fences and semaphores).
  - `MutableBuffer(T)` (host-visible, mapped) and `ImmutableBuffer(T)`
    (device-local, uploaded through a staging buffer); images,
    samplers, shader modules.
  - `create_graphics_pipeline(gctx, GraphicsPipelineDesc)` builds a
    dynamic-rendering pipeline from one description struct.
  - Deferred destruction: resources queued with `defer_destroy_*`
    are released once the GPU is past every frame that could use
    them.
  - The bindless mechanism: `create_descriptor_array_layout` makes
    `PARTIALLY_BOUND` descriptor arrays, and
    `write_descriptor_array_element` fills one slot.
- **`render/mesh`** is the mesh format described above. It is plain
  data with no Vulkan, so tools and tests can build geometry without
  a device.
- **`render/gltf`** loads the render part of a glTF file (meshes,
  materials, textures).

Everything else is private to `package render`:

- `bindless_*.odin` define render's arrays on top of the `gpu`
  mechanism: the 2D texture, cube texture and sampler arrays
  (`TextureManager`), the mesh arena (`MeshManager`: shared vertex,
  index and skinning buffers sub-allocated by the containers slab
  allocator), the scene descriptor sets, and the indirect draw lists
  (`DrawPipeline`, `DrawBuffers`) that culling writes and draws consume.
- `pass_*.odin` hold one pass each: `gbuffer`, `ambient`,
  `direct_light`, `shadow`, `forward`, `particles` (draw) and
  `particles_compute` (simulation), `occlusion_culling` (depth pyramid
  + cull), `debug_line`, `post_process`. A pass's record proc takes the
  `Manager` and reads the scene buffers from it.

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
a G-buffer (normal, albedo, metallic-roughness, emissive, depth) once
per visible fragment; the lighting passes rebuild world position from
depth and the camera's inverse view-projection. It then runs one fullscreen ambient
pass (IBL + BRDF LUT) plus a per-light volume pass for each direct
light. The IBL environment map comes from `load_environment_map`.
A light's volume (sphere for point, cone for spot, fullscreen
triangle for directional) is rasterized with reversed depth test so
only fragments actually reached by that light get shaded.

## Shadows

- **2D shadow maps** for directional + spot lights. One compute pass
  per light clips draws against the light frustum; one depth-only
  graphics pass writes a 512² D32_SFLOAT map.
- **Cubemap shadow maps** for point lights. Each of the six faces is
  its own 90° view: the compute pass clips draws against the face
  frustum and a depth-only pass writes that face.

Lighting samples both kinds through a depth-compare sampler, which
filters the shadow test over 2×2 texels.

There are `MAX_SHADOW_MAPS` fixed shadow slots. A shadow caster keeps
its slot while it casts; new casters, in slot order, take a free slot
of their kind first. A slot's draw buffers are created on first use
and kept until shutdown; its textures switch between cube and 2D when
it goes to a light of the other kind.

## Cameras

`render.create_camera` makes a camera with its own per-frame
attachments. Every camera runs the geometry, lighting, particle and
forward passes; the main camera also gets post-process, debug lines and
UI, and is presented to the swapchain. `render.camera_attachment(&r, cam, .FINAL_IMAGE, frame)`
returns a bindless handle — feed it to a UI quad or a material for
minimaps, mirrors and render-to-texture surfaces.

Controllers (`orbit_controller`, `free_controller`,
`follow_controller`) are plain values that drive the main camera from
the tick's `input.State` via
`camera_controller_update(&ctl, &r, &state, dt)`. They ignore devices
that `state` marks captured. Keys are fixed: WASD + QE to move, shift
to pan or boost, left drag to orbit. Render does not store
controllers; the caller owns one. The orbit
controller reads distance, yaw and pitch from the camera's pose each
tick, so moving the camera directly never makes it snap back.

## UI and debug UI

The UI pass draws two things with one pipeline:

- **Game UI.** `render.stage_ui(&r, list)` takes a `DrawList`
  (from `render.draw_list` or anywhere else). The list holds the frame's
  commands and, when it changed, the glyph atlas.
- **Debug UI.** A microui context owned by render. `debug_ui(&r)`
  returns it, opening it on the first call of the frame. Build
  widgets before `frame`, which closes and draws it. Frames that never
  call `debug_ui` draw no debug UI. `debug_ui_input(&r, &state)` feeds
  it one `input.State` tick (call it first on the update tick). It
  marks the mouse captured while the debug UI is hovered or holds a
  press made over it, and the keyboard captured while a widget has
  focus.

## Debug drawing

`debug_segment`, `debug_aabb`, `debug_cube`, `debug_circle`,
`debug_sphere`, `debug_arrow`, `debug_axes` and `debug_point` queue
line primitives. A line lasts `life` seconds of render's clock
(advanced by `update`); zero draws it for one frame.

## Post-process

`render.add_effect(&r, effect)` appends one effect value
(`ToneMapEffect`, `BloomEffect`, `BlurEffect`, `FogEffect`,
`OutlineEffect`, `DoFEffect`, `CrossHatchEffect`, `GrayscaleEffect`)
and `clear(&r.post_process.effect_stack)` empties the stack:

```odin
clear(&r.post_process.effect_stack)
render.add_effect(&r, render.BloomEffect{threshold = 1, intensity = 2, blur_radius = 32})
render.add_effect(&r, render.ToneMapEffect{exposure = 1, gamma = 2.2})
```

Effects run in insertion order inside the `POST_PROCESS` pass of every
camera that has it. Blur and bloom run as two separable passes
(horizontal, then vertical); `add_effect` sets their `direction`. A
`GrayscaleEffect` with zero `weights` uses Rec. 601 luma weights.
