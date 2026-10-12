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
  `r.ambient.skybox_blur` (0..1) and `skybox_intensity` set the
  skybox's blur and brightness, 0 hiding it. `setup` resets them to
  their defaults.
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
- `render.stage_transforms(&r, changes)` moves slots: `changes` is a slice of
  any struct with `index` (the slot), `world_matrix` and `visible` fields,
  such as `world.changed_nodes(&w)`.
- `render.stage_bones(&r, slot, matrices)` uploads a skin palette.
- `render.stage_slot_removal(&r, slot)` frees it.

All of these are thread-safe and callable from the update thread.

To change a look, `render.attachment(&r, slot, T)` returns a copy of
the slot's attachment of type `T`; edit its fields (light color,
radius, mesh handle, material, …) and pass it back to `attach`.
A slot's `visible` flag hides everything it draws, lights included:

```odin
if l, ok := render.attachment(&r, slot, render.LightAttachment); ok {
  l.color = {1, 0, 0, 1}
  render.attach(&r, slot, l)
}
```

## Resources

- **Meshes.** `render/mesh` defines the vertex format (`Vertex`,
  `SkinningData`, `Geometry`), primitive builders (`make_cube`,
  `make_sphere`, `make_capsule`, …) and `from_triangles` for plain
  position + index data.
  `render.create_mesh(&r, geometry)` takes ownership of the geometry;
  the next frame uploads it into the mesh arena and frees it.
  `r.builtin_meshes[.CUBE]` is a builtin primitive and
  `r.builtin_materials[.RED]` a builtin solid color;
  `primitive(&r, shape, color)` pairs them into a `MeshAttachment`.
- **Textures.** `create_texture_from_path` / `create_texture_from_data`
  return a bindless `TextureHandle`; `destroy_texture` releases it.
  Textures live for one level: `teardown` destroys them all.
- **Materials.** `create_material` and the `material_pbr`,
  `material_wireframe`, `material_transparent` shorthands. Materials
  outlive `teardown`, so destroy a material that samples a texture
  before the level ends; a texture handle from an earlier level points
  at whatever the new level allocates in its place.
  A `Material` is stored as the shaders read it: its textures are
  bindless indices (`texture_index(handle)`, `NO_TEXTURE` for none).
  `material(&r, h)` returns a `^Material`; edit it and write it back
  with `set_material(&r, h, m^)` to stage the upload.
- **Sprites.** `material_sprite(&r, texture, columns, rows, tint)`
  makes a sprite-sheet material; attach it as a `MeshAttachment` with
  `r.builtin_meshes[.QUAD_XY]` and it faces the camera.
  `set_sprite_frame(&r, material, frame)` shows one cell.
  Animate it by setting the frame as time advances.
- **Emitters, force fields.** `create_emitter` / `create_forcefield`.
  Both are stored as the particle shaders read them; `attach` sets
  their `node_index`. `emitter(&r, h)` / `forcefield(&r, h)` return a
  pointer; edit it and write it back with `set_emitter` /
  `set_forcefield`. Emitters are uploaded every frame; force field
  changes are staged.
- **Lights** have no resource; a light is a `LightAttachment` whose
  `type` picks point, spot or directional
  (`point_light_attachment`, `directional_light_attachment`,
  `spot_light_attachment` fill in the defaults).

`render.frame(&r, ..., show_stats = true)` shows texture, mesh,
material and slot counts and the main camera's opaque draw count in the
debug UI.

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
    pools, the graphics and compute timeline semaphores and
    `frame_serial`, the one frame clock: `wait_frame`, deferred
    destruction, staging reuse and every pool's `RETIRE_GRACE` count
    submissions) and `Swapchain` (images and their semaphores).
  - `Buffer`, one plain struct for both memory kinds: host-visible and
    persistently mapped for data the CPU rewrites every frame (`mapped`
    views it as a typed slice), device-local for data written once or only
    by the GPU (mesh geometry and table, particles, draw lists, pyramid
    counters). Device-local buffers and images are filled through pooled
    staging blocks recorded in bulk at the start of the next command
    buffer (`record_uploads`): fills, one copy per destination buffer,
    one batch of blits per mip level.
  - `create_graphics_pipeline(gctx, GraphicsPipelineDesc)` builds a
    dynamic-rendering pipeline from one description struct.
  - Deferred destruction: resources queued with `defer_destroy` are
    released once the GPU is past every frame that could use them.
  - Descriptors: `create_descriptor_layout` makes a layout from
    `DescriptorBinding`s, every binding a `PARTIALLY_BOUND` array (the
    scene set's bindings are arrays of one), and `write_descriptor`
    fills one slot.
- **`render/mesh`** is the mesh format described above. It is plain
  data with no Vulkan, so tools and tests can build geometry without
  a device.
- **`render/gltf`** loads the render part of a glTF file (meshes,
  materials, textures).

Everything else is private to `package render`:

- Render keeps its state as flat fields of `Manager`: one array of
  pipelines per kind (`pipelines` by `PipelineId`, `material_pipelines`,
  `light_pipelines`), the bindless texture pool and samplers, the scene
  buffers. A pass is procs over that state, not a struct of its own.
- `bindless_*.odin` define render's arrays on top of the `gpu`
  mechanism: the texture array (2D and cube textures share it, the
  shaders aliasing a `textureCube` array onto its binding) and the
  sampler array, the mesh arena (one buffer per `MeshStream`: vertex,
  index and skinning, each sub-allocated by a containers slab
  allocator), the scene descriptor set, and the indirect draw lists
  (`DrawLists`) that culling writes and draws consume.
- One scene descriptor set (set 0, per frame in flight, bindings in
  `SceneBinding`) plus the bindless set (set 1) form one pipeline layout
  shared by every scene pipeline, compute and graphics; it is bound once
  per command buffer. Besides textures and samplers, set 1 holds the
  compute-only arrays at fixed slots: every draw list buffer (camera slot
  c, frame f at c * FRAMES_IN_FLIGHT + f, then the shadow lists), every
  depth pyramid mip as a storage image, and the pyramid counters.
- `MATERIAL_PIPELINES` describes every `MaterialType`: shaders, the pass
  that draws it, raster state, and whether it is occlusion tested and
  casts shadows. A material type's draw list, pipeline and cull rules all
  come from that table.
- `material_pass_record` (material_pipelines.odin) records the G-buffer
  and forward passes from `MATERIAL_PASS_TARGETS`; forward also draws
  particles.
- `pass_*.odin` hold one pass each: `direct_light` (every light type,
  ambient included), `ambient` (environment data) and
  `ambient_precompute` (IBL), `shadow`,
  `particles_compute` (simulation and draw), `occlusion_culling` (depth pyramid
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
per-mesh descriptor binding. Culling is one compute shader over a table
of views (`ViewGPU`): one thread tests one (node, view) pair against the
view's frustum and, when the view has a depth pyramid and the material
type is occlusion tested, its pyramid. Visible nodes are appended to the
draw lists the view names, in the list for their material type. A camera
is one view with one list per material type; the shadow views share one
list. A view also carries its matrices, extent, clip planes and, for a
camera, this frame's G-buffer images: every shader that renders for a
camera reads it from the view table. Every camera slot has a view, empty for a slot without a camera,
so one dispatch culls for all cameras. The depth pyramid is built in one
dispatch per camera: each group reduces a 32×32 tile to mip 5 in shared
memory, and the last group to finish reduces the rest.

Frame N's culling builds the depth pyramid from frame N-1's depth and
writes the draw lists frame N+1 draws. On a device with a dedicated
compute queue family, the pyramid and culling run there, overlapping frame
N's graphics work. Two timeline semaphores order the queues:

- compute N waits for graphics N-1, which wrote the depth compute N reads
  and drew from the lists compute N rewrites;
- graphics N waits for compute N-1 at indirect draw and depth test, since
  it draws compute N-1's lists and rewrites the depth compute N-1 read.

Buffers, camera depth and the pyramid use `CONCURRENT` sharing across the
two families, so no ownership transfers are needed. Particle simulation
always runs on the graphics queue at the end of the frame.

## Particles

Particles live in a ring of `MAX_PARTICLES` slots. Each frame the CPU
gives every emitter a range of the frame's new particles (an exclusive
prefix of emit counts) and the ring cursor; the emit dispatch runs one
thread per new particle, which finds its emitter by binary search. The
simulation advances every live slot and appends it to the alive list,
whose header is the indirect draw: the forward pass draws exactly the
live particles.

## Why deferred + light volumes

Forward shading scales as `pixels × lights`. The deferred pass writes
a G-buffer (normal, albedo, metallic-roughness, emissive, depth) once
per visible fragment; the lighting passes rebuild world position from
depth and the camera's inverse view-projection, with one instanced
volume draw per light type, all blended additively. The ambient light
(IBL + BRDF LUT, emissive and the skybox) is one more light type, one
instance per frame; its environment map comes from
`load_environment_map`. Lights are uploaded to a storage buffer sorted
by type, so each type is one draw of its volume (sphere for point, cone
for spot, fullscreen triangle for directional and ambient) with one
instance per light, rasterized with reversed depth test so only
fragments actually reached by a light get shaded. The fullscreen
triangle sits on the far plane, so directional lights skip the
background; ambient shades it to draw the skybox.

Cameras are recorded phase by phase: every camera's G-buffer scope, then
every camera's lighting scope, then every camera's forward scope. One
barrier separates each phase for all cameras, so the barrier count does
not grow with the camera count.

## Shadows

Shadow maps are layers of one 512² D32_SFLOAT 2D array image per frame
in flight. A map has one face per layer, `SHADOW_FACES[type]`: a
directional or spot light has one, a point light six (the cube faces,
each a 90° perspective view). Each face is one view in the cull's view
table, and shadow view i renders layer i. The image grows, doubling, as
more layers are needed; only the layers in use are rendered. One cull
dispatch over every (node, view) pair fills one shared list, each draw
tagged with its view; one layered draw renders every view, the vertex
shader picking the layer. Shadow views share the scene passes' raster
state: projections put clip-space y down and no viewport is flipped.

Lighting has one shadow path for every light type: it picks the face
(the major axis of the light-to-fragment direction for a point light,
the only face otherwise), projects the fragment with that face's view
and samples its layer through a depth-compare sampler, which filters the
shadow test over 2×2 texels. Before projecting, the fragment moves along
its normal by 1.5 shadow texels; the texel's world size is per light data
(`shadow_texel`), scaled by view depth for point and spot lights.

There are `MAX_SHADOW_MAPS` shadow maps. Every light has a shadow
bounds sphere (radius = range; around the shadow box for directional
lights, a box of half extent `shadow_radius` centered on the light). Each frame
the shadow casters whose sphere touches some camera's frustum are
ranked by `intensity × r² / (d² − r²)`, an estimate of the screen area
the sphere covers. The top `SHADOW_RANKED_CASTERS` get a map; the
remaining maps stay with casters that ranked within the last
`SHADOW_GRACE_FRAMES` frames. Other casters light unshadowed. A
selected caster keeps its map; the others take a free one.

## Cameras

`render.create_camera` makes a camera with its own per-frame
attachments. Every camera runs the geometry, lighting, particle and
forward passes; the main camera also gets post-process, debug lines and
UI, and is presented to the swapchain. `render.camera_attachment(&r, cam, .FINAL_IMAGE, frame)`
returns a bindless handle — feed it to a UI quad or a material for
minimaps, mirrors and render-to-texture surfaces.

There is no built-in camera controller. Drive `render.Camera` yourself
with `camera_look_at`, `camera_orbit` (+ `camera_orbit_state` to read
yaw/pitch/distance back from the pose), and `camera_lerp`,
`camera_lerp_look_at`, `camera_lerp_transform` to ease position and
rotation toward a pose. `examples/cameras` builds orbit, free-fly and
follow cameras this way.

## UI and debug UI

The UI pass draws two things with one pipeline:

- **2D overlay.** `render.stage_overlay(&r, list)` takes a `DrawList`:
  the frame's quad, mesh and text commands in framebuffer pixels, each
  with a z order and a clip rect, and, when it changed, the font atlas
  (`font.atlas`). Text commands are `font.Glyph` runs, their uvs in atlas
  texels. Render draws; laying a UI out is the `ui` module's job and
  turning its nodes into commands the application's.
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

Append effect values (`ToneMapEffect`, `BloomEffect`, `BlurEffect`,
`FogEffect`, `OutlineEffect`, `DoFEffect`, `CrossHatchEffect`,
`GrayscaleEffect`) to `r.post_process.effect_stack`; `clear` empties
it:

```odin
clear(&r.post_process.effect_stack)
append(&r.post_process.effect_stack, render.BloomEffect{threshold = 1, intensity = 2, blur_radius = 32})
append(&r.post_process.effect_stack, render.ToneMapEffect{exposure = 1, gamma = 2.2})
```

Effects run in insertion order inside the `POST_PROCESS` pass of every
camera that has it. `EFFECTS` gives each effect's shader and pass
count; each pass reads the previous pass's output (input) and the one
before it (original) from a ring of three images, plus its pass number.
Blur and bloom run two separable passes (horizontal, then vertical),
and bloom's vertical pass composites over its original. A
`GrayscaleEffect` with zero `weights` uses Rec. 601 luma weights.
