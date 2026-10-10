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
- `update(&r, dt)` advances render's own clock once per update tick:
  emitter accumulators and debug line lifetimes.
- `frame` closes the debug UI, uploads staged changes, acquires a
  swapchain image (recreating the swapchain when the framebuffer size
  changed), records every pass, submits, presents and retires
  deferred GPU resources. It returns false on a GPU error.
  `show_stats = true` adds a stats window to the debug UI.

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

To change a look in place, `render.attachment(&r, slot, T)` returns a
pointer to the slot's attachment of type `T`; edit its fields (light
color, radius, `disabled`, mesh handle, material, …) and call
`render.mark_slot_dirty(&r, slot)` to stage the change. Do this from
the update thread.

## Resources

- **Meshes.** `render/mesh` defines the vertex format (`Vertex`,
  `SkinningData`, `Geometry`), primitive builders (`make_cube`,
  `make_sphere`, `make_capsule`, …) and `from_triangles` for plain
  position + index data. `load_obj(path, scale)` reads the positions
  and fan-triangulated faces of an OBJ file into an
  `ObjMesh{positions, indices}` (free with `obj_mesh_destroy`).
  `render.create_mesh(&r, geometry)` uploads one into the mesh arena.
  Builtin primitives are in `r.builtin_meshes` (and colors in
  `r.builtin_materials`).
- **Textures.** `create_texture_from_path` / `create_texture_from_data`
  return a bindless `Texture2DHandle`; `destroy_texture` releases it.
- **Materials.** `create_material` and the `material_pbr`,
  `material_wireframe`, `material_transparent` shorthands. Edit fields
  through `material(&r, h)`, then call `mark_material_dirty`.
- **Sprites.** `create_sprite(&r, texture, columns, rows)` makes a
  sprite sheet; `set_sprite_frame(&r, h, frame)` shows one cell.
  Animate it by setting the frame as time advances.
- **Emitters, force fields.** `create_emitter` / `create_forcefield`,
  edited in place through `emitter(&r, h)` / `forcefield(&r, h)`;
  `update` uploads them every tick.
- **Lights** have no resource; a light is an attachment
  (`point_light_attachment`, `directional_light_attachment`,
  `spot_light_attachment`).

`render.stats(&r)` reports texture, mesh, material and slot counts
and the main camera's opaque draw count.

## Staging

Every mutation marks an entry dirty in a mutex-guarded staging set.
`render.frame` uploads dirty entries once per frame on the render
thread. Bone palettes live in per-frame buffers and are re-uploaded
until every frame in flight has them; everything else is written once.
Freed meshes, materials, sprites, emitters and force fields hold their
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
- **`render/bindless`** defines render's arrays on top of that
  mechanism: the 2D texture, cube texture and sampler arrays
  (`TextureManager`), the mesh arena (`MeshManager`: shared vertex,
  index and skinning buffers sub-allocated by a slab allocator), the
  scene descriptor set, and the indirect draw lists (`DrawPipeline`,
  `DrawBuffers`) that culling writes and draws consume.
- **`render/mesh`** is the mesh format described above. It is plain
  data with no Vulkan, so tools and tests can build geometry without
  a device.
- One subpackage per pass: `geometry`, `ambient`, `direct_light`,
  `shadow`, `forward`, `particles` (simulation compute + draw),
  `occlusion_culling` (depth pyramid + cull), `debug_line`,
  `post_process`, `ui`.
- **`render/gltf`** loads the render part of a glTF file (meshes,
  materials, textures).

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
light. The IBL environment map comes from `load_environment_map`.
A light's volume (sphere for point, cone for spot, fullscreen
triangle for directional) is rasterized with reversed depth test so
only fragments actually reached by that light get shaded.

## Shadows

- **2D shadow maps** for directional + spot lights. One compute pass
  per light clips draws against the light frustum; one depth-only
  graphics pass writes a 512² R32_SFLOAT slice.
- **Cubemap shadow maps** for point lights. The same compute pass
  clips against the box around the light's range; one
  geometry-shader-amplified draw
  writes all six faces. Requires
  `-define:REQUIRE_GEOMETRY_SHADER=true` at build time.

Each frame the first `MAX_SHADOW_MAPS` shadow casters, in slot order,
take the fixed shadow slots. A slot's draw buffers are created on first
use and kept until shutdown; its textures switch between cube and 2D
when it changes to a light of the other kind.

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

- **Game UI.** `render.stage_ui(&r, list)` takes a `draw2d.DrawList`
  (from `ui.draw_list` or anywhere else). The list holds the frame's
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

The effect stack lives in `r.post_process`; push effects with
`post_process.add_*` (tonemap, bloom, blur, directional blur, fog,
outline, DoF, crosshatch, grayscale) and reset it with
`clear_effects`. Effects run in insertion order inside the
`POST_PROCESS` pass of every camera that has it.
