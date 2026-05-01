# Architecture

Mjolnir is a deferred-shading, bindless, GPU-driven game engine in Odin + Vulkan 1.3.
This page explains *why* the engine is shaped the way it is. Each design decision
maps back to one of the rules in [`ZEN.md`](../ZEN.md):

> 1. Single source of truth — avoid storing derived information unless evidence of perf issue
> 2. No duplicated information across structs, no pointer fields on structs
> 3. Keep struct definition count minimum
> 4. Modules organized in layers, dependency goes top → bottom
> 5. Avoid indirection / wrapper when possible
> 6. Do not leak internal detail to user

---

## 1. Layered module organization

The codebase is split into three strict layers. **Higher layer depends on lower
layer; never the reverse, never sideways.** A module on layer N must compile
without any module on layer N or N+1.

```mermaid
flowchart TB
  subgraph L3["Layer 3 — Engine"]
    engine["mjolnir/engine.odin<br/>window + main loop<br/>wires layer-2 systems<br/>user-facing API"]
  end

  subgraph L2["Layer 2 — Subsystems"]
    direction LR
    world["world<br/>scene graph<br/>nodes / cameras / lights"]
    render["render<br/>passes, GPU-driven<br/>bindless"]
    nav["navigation<br/>recast / detour"]
    physics["physics<br/>rigid body<br/>BVH broadphase"]
    ui["ui<br/>widgets, layout<br/>events"]
  end

  subgraph L1["Layer 1 — Primitives"]
    direction LR
    gpu["gpu<br/>vulkan thin wrap"]
    geometry["geometry<br/>BVH, AABB, frustum<br/>octree, vertex"]
    algebra["algebra<br/>pow2, ilog2, align"]
    containers["containers<br/>handle pool<br/>slab allocator"]
    animation["animation<br/>keyframe, spline<br/>FK / IK / modifiers"]
  end

  L3 --> L2
  L2 --> L1
```

---

## 2. Frame timeline

```mermaid
sequenceDiagram
  autonumber
  participant U as User code
  participant E as engine main loop
  participant W as world
  participant R as render
  participant G as GPU

  E->>E: glfw.PollEvents / update_input
  E->>U: key, mouse, scroll callbacks
  E->>U: ui.dispatch_mouse_event (HOVER/CLICK)

  rect rgb(245,245,255)
    note over E,W: update phase (own thread if USE_PARALLEL_UPDATE)
    E->>U: update_proc(delta_time)
    E->>W: update_node_animations / update_skeletal_animations
    E->>W: camera_controller_*_update
    W->>W: stage_node_data / stage_bone_matrices / ...
  end

  E->>E: throttle to FRAME_TIME_MILIS

  rect rgb(245,255,245)
    note over E,R: sync phase (under world.staging.mutex)
    E->>W: sync_staging_to_gpu
    W->>R: render.upload_node_data / upload_mesh_data / ...
    E->>R: sync_ui_to_renderer (compute_layout_all + stage_commands)
  end

  E->>U: pre_render_proc

  rect rgb(255,250,240)
    note over E,G: render phase
    E->>G: acquire_next_image
    E->>R: record_frame
    R->>G: compute culling per camera
    R->>G: shadow culling per light
    R->>G: shadow_render (2D + cubemap)
    R->>G: record_geometry_pass (G-buffer)
    R->>G: record_lighting_pass (ambient + direct)
    R->>G: record_particles_pass (compute + draw)
    R->>G: record_transparency_pass
    R->>G: record_debug_pass
    R->>G: record_post_process_pass
    R->>G: record_ui_pass
    R->>G: swapchain → PRESENT_SRC barrier
    E->>G: submit_queue_and_present
  end

  E->>U: post_render_proc
```

### Update vs render decoupling

- `RENDER_FPS` (default 60) governs `record_frame` cadence.
- `UPDATE_FPS` (default = `RENDER_FPS`) governs `update`.
- `USE_PARALLEL_UPDATE=true` moves `update` to a dedicated thread. Render
  thread keeps its own cadence; sync happens through `world.staging` (mutexed).

---

## 3. Bindless GPU resources

Mjolnir is **bindless** end-to-end. There are no per-draw descriptor binds
inside the geometry/lighting/shadow loops. All resources live in giant arrays
indexed by `u32`.

```mermaid
flowchart LR
  subgraph CPU
    direction TB
    nodes_pool["world.nodes<br/>Pool(Node)"]
    meshes_pool["world.meshes<br/>Pool(Mesh)"]
    mats_pool["world.materials<br/>Pool(Material)"]
    cams_pool["world.cameras<br/>Pool(Camera)"]
    tex_pool["texture_manager<br/>images_2d / images_cube"]
  end

  staging["world.staging<br/>(mutex'd queues)"]

  subgraph GPU["GPU (bindless storage buffers + texture arrays)"]
    direction TB
    node_buf["node_buffer[node_id]"]
    mesh_buf["mesh_buffer[mesh_id]"]
    mat_buf["material_buffer[material_id]"]
    cam_buf["camera_buffer[cam_id][frame]"]
    tex_arr["texture_array[idx] (1000 slots)<br/>cube_array[idx] (200 slots)"]
    vbuf["vertex_buffer (128 MB)<br/>index_buffer (64 MB)<br/>skinning_buffer (128 MB)"]
  end

  nodes_pool --> staging --> node_buf
  meshes_pool --> staging --> mesh_buf
  mats_pool --> staging --> mat_buf
  cams_pool --> staging --> cam_buf
  tex_pool --> tex_arr
  meshes_pool -. allocate_vertices/indices/skinning .-> vbuf
```

### How a draw call resolves on the GPU

```mermaid
flowchart LR
  draw["VkDrawIndexedIndirectCommand<br/>vertex_offset / first_index<br/>instance_id"]
  draw --> mesh["mesh_buffer[mesh_id]<br/>aabb / counts / slab offsets"]
  draw --> node["node_buffer[node_id]<br/>world_matrix<br/>material_id<br/>flags"]
  node --> mat["material_buffer[material_id]<br/>albedo_index<br/>features (bitset)<br/>roughness/metallic"]
  mat --> tex["bindless texture array<br/>textures[albedo_index]"]
  mesh --> vb["vertex_buffer<br/>(slab offset)"]
```

Push constants only carry per-pass info (camera index, light index). Per-object
state lives in storage buffers indexed by ID.

---

## 4. Handles, not pointers
Pointers to dynamic-array-backed pool entries are unstable: the underlying
`[dynamic]Entry(T)` reallocs on grow and the pointer once valid is then corrupted.
That encourage us to use handle-based object referencing.
Layer 1 (`containers/handle_pool.odin`) defines:

```odin
Handle :: struct {
  index:      u32,
  generation: u32,
}

Pool($T) :: struct {
  entries:      [dynamic]Entry(T),
  free_indices: [dynamic]u32,
}
```

Every long-lived object (Node, Mesh, Material, Camera, Light, Sprite, Emitter,
ForceField, Clip, Texture2D, TextureCube, RigidBody, Trigger, Widget) is owned
by a `Pool` and referenced by a `distinct` handle.

### Generational counter

```mermaid
stateDiagram-v2
  [*] --> Free
  Free --> Active: alloc — gen stays, active=true
  Active --> Free: free — gen += 1, active=false
  note right of Free
    Stale handles still pointing here
    miss: pool.get returns nil, false
    because gen mismatch
  end note
```

- Slot starts with `generation = 1`.
- Free → `generation += 1` (wraps but never lands on 0).
- `pool.get(handle)` returns `nil, false` if `entries[handle.index].generation != handle.generation`.

So:
- A handle held after free returns a clean miss (no UAF, no stale memory).
- You can serialize / load handles without rewiring pointers.

---

## 5. The staging pipeline (CPU mutation → GPU upload)

`world` module must not touch GPU buffers. Instead it
**stages** a change, and `sync_staging_to_gpu` drains the staging maps once
per frame on the render thread.

```mermaid
sequenceDiagram
  participant U as user / update thread
  participant W as world
  participant S as world.staging<br/>(maps + mutex)
  participant R as render

  U->>W: spawn / translate / despawn / set_animation_layer_weight
  activate W
  W->>W: Pool(Node).alloc / .free
  W->>S: stage_node_data(handle, op=Update)
  W->>S: stage_mesh_data(...) / stage_material_data(...)
  W-->>U: NodeHandle
  deactivate W

  note over U,R: ─── frame boundary ───

  U->>W: sync_staging_to_gpu (engine main thread)
  activate W
  W->>S: lock mutex
  loop for each entry in node_data / mesh_updates / ...
    alt op == Update
      W->>R: render.upload_node_data / upload_mesh_data / ...
    else op == Remove
      W->>R: release shadow / texture / slab allocations
    end
    W->>S: entry.age += 1<br/>drop after FRAMES_IN_FLIGHT
  end
  W->>S: unlock mutex
  deactivate W
```

Some design notes:

- **Frames in flight (default 2).** A `Remove` cannot happen the same frame —
  the GPU may still be reading the resource for frame `N-1`. Staging entries
  carry an `age: u16`; only after `age >= FRAMES_IN_FLIGHT` do we actually
  release the GPU side.
- **Single source of truth** CPU state in `world` is authoritative.
  GPU mirrors are derived. Drift is impossible because drift requires *two
  writers*, and `render` only ever reads from staging.
- **Threading.** `update` thread mutates `world` + queues staging entries
  under the staging mutex. The render thread acquires the same mutex once per
  frame in `sync_staging_to_gpu` and drains.

---

## 6. Camera

Each `world.Camera` carries a `PassTypeSet` describing which passes to run for
it. The render layer keeps a `CameraTarget` per camera, with **per-frame**
`[FRAMES_IN_FLIGHT]Texture2DHandle` for every `AttachmentType` (POSITION,
NORMAL, ALBEDO, METALLIC_ROUGHNESS, EMISSIVE, FINAL_IMAGE, DEPTH) plus its own
depth pyramid for occlusion culling.

```mermaid
flowchart TB
  subgraph A["Camera A — main view"]
    A1["enabled_passes:<br/>GEOMETRY, LIGHTING, TRANSPARENCY,<br/>POST_PROCESS, UI, ..."]
    A2["FINAL_IMAGE → swapchain<br/>depth pyramid → occlusion"]
  end
  subgraph B["Camera B — minimap (orthographic)"]
    B1["enabled_passes:<br/>GEOMETRY, LIGHTING"]
    B2["FINAL_IMAGE → bindless texture<br/>(read by camera A)"]
  end
  subgraph C["Camera C — shadow caster"]
    C1["enabled_passes: SHADOW"]
    C2["depth → bindless<br/>(read by lighting pass)"]
  end
  B2 -. sampled by .-> A
  C2 -. sampled by .-> A
```

`get_camera_attachment(engine, cam_handle, .FINAL_IMAGE)` returns the texture
handle, which is just a bindless index. Compositing camera-B-into-camera-A
costs nothing extra at the API level — Camera A's UI quad samples the returned
handle.

---

## 7. Deferred shading + light volumes

```mermaid
flowchart LR
  subgraph G["Geometry pass (record_geometry_pass)"]
    direction TB
    gp["draw opaque w/<br/>indirect draw + bindless"]
  end
  subgraph GB["G-buffer attachments"]
    direction TB
    pos["POSITION<br/>R32G32B32A32_SFLOAT"]
    nrm["NORMAL<br/>R8G8B8A8_UNORM (encoded)"]
    alb["ALBEDO"]
    mr["METALLIC_ROUGHNESS"]
    em["EMISSIVE"]
    dpt["DEPTH (D32_SFLOAT)"]
  end
  subgraph L["Lighting pass (record_lighting_pass)"]
    direction TB
    amb["ambient pass<br/>fullscreen tri<br/>+ IBL + BRDF LUT"]
    direct["direct passes<br/>per light volume<br/>(sphere/cone/fst)"]
  end
  fi["FINAL_IMAGE<br/>(additive accumulation)"]

  G --> GB
  GB --> amb
  GB --> direct
  amb --> fi
  direct --> fi
```

A light volume (sphere for point light, cone for spot light, fullscreen triangle for
directional light) is rasterized with depth-test reversed; only fragments inside the
light's reach are shaded. Avoids the "shade every pixel against every light"
loop without needing a tile / cluster yet (see §11).

---

## 8. Shadow strategy

```mermaid
flowchart TB
  subgraph TwoD["2D shadow (directional, spot)"]
    sc1["shadow_culling.execute<br/>(compute, frustum-clip per light)"]
    sr1["shadow_render.render<br/>depth-only graphics<br/>→ shadow_map_2d (R32_SFLOAT, 512²)"]
    sc1 --> sr1
  end
  subgraph Cube["Cubemap shadow (point)"]
    sc2["shadow_sphere_culling.execute<br/>(compute, sphere-clip per light)"]
    sr2["shadow_sphere_render.render<br/>geometry-shader cubemap pass<br/>→ shadow_map_cube"]
    sc2 --> sr2
  end
  upsert["render.upsert_light_entry<br/>(allocates shadow buffers lazily)"]
  release["render.release_shadow_2d / _cube<br/>(on light despawn)"]
  upsert --> TwoD
  upsert --> Cube
  TwoD --> release
  Cube --> release
```

Each shadow-casting light gets its own pair of buffers
(`MutableBuffer(vk.DrawIndexedIndirectCommand)` + count).
`INVALID_SHADOW_INDEX = 0xFFFFFFFF` flags lights that shouldn't cast.

Cubemap shadows need `REQUIRE_GEOMETRY_SHADER=true` at build time (one draw,
six layers via geometry shader).

---

## 9. Physics

```mermaid
flowchart TB
  start([step dt])
  sleep[update sleep timers]
  warm[cache prev_*_contacts<br/>for warmstart]
  grav[apply_gravity]
  integ[integrate_velocities<br/>forces → velocity, damping]
  ccd[CCD pass<br/>swept tests, clamp dt]
  bvh{killed_count ><br/>BVH_REBUILD_THRESHOLD?}
  rebuild[rebuild dynamic + static BVH]

  start --> sleep --> warm --> grav --> integ --> ccd --> bvh
  bvh -- yes --> rebuild --> sub
  bvh -- no --> sub

  subgraph SubLoop["substep loop (NUM_SUBSTEPS = 2)"]
    direction TB
    sub[bvh_refit]
    bp[broadphase BVH traversal<br/>contact candidates]
    nar[narrow-phase<br/>test_box_box / sphere_cyl / ...]
    prep[prepare_contact<br/>mass matrix, bias]
    ws[if first substep:<br/>warmstart_contact]
    solve[constraint solver<br/>CONSTRAINT_SOLVER_ITERS=4<br/>resolve with bias + restitution]
    stab[stabilization<br/>STABILIZATION_ITERS=2<br/>resolve_no_bias]
    ip[integrate_positions]
    ir[integrate_rotations]
    ua[update_cached_aabb]
    sub --> bp --> nar --> prep --> ws --> solve --> stab --> ip --> ir --> ua
  end

  SubLoop --> trig[trigger overlap detection]
  trig --> kill[mark bodies below KILL_Y dead<br/>deferred remove on next BVH rebuild]
  kill --> done([done])
```

---

## 10. Where to go next

| If you want to...                          | Read                                           |
| ------------------------------------------ | ---------------------------------------------- |
| Build something step by step               | [`cookbook.md`](cookbook.html)                 |
| Understand the public engine API           | [`api_engine.md`](api_engine.html)             |
| Understand scene graph + handles in detail | [`api_world.md`](api_world.html)               |
