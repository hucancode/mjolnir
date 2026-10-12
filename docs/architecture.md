---
title: Architecture
---

Mjolnir is a deferred-shading, bindless, GPU-driven game engine in
Odin + Vulkan 1.3. This page is about *why* the engine is shaped the
way it is, not what the code does.

## Guiding rules

1. **Single source of truth.** Don't store derived state unless
   profiling demands it.
2. **No duplicated data across structs.** No pointer fields on
   structs — handles only.
3. **Keep struct definition count to a minimum.**
4. **Modules in layers.** Dependency goes top → bottom only.
5. **Avoid indirection / wrappers** when the underlying call already
   reads well.
6. **Do not leak internal detail to user code.**
7. **Expose Vulkan.** Vulkan is not hidden; mjolnir codifies the
   patterns that make it manageable.

---

## Layered modules

The codebase splits into three layers. **Higher layer depends on
lower; never the reverse, never sideways.** Every layer-2 module
compiles and runs without its siblings, so each can be swapped out or
split into its own repository.

```mermaid
flowchart TB
  subgraph L3["Layer 3 — Engine"]
    engine["mjolnir (optional)<br/>run loop<br/>glTF assembly"]
  end

  subgraph L2["Layer 2 — Subsystems"]
    direction LR
    platform["platform<br/>GLFW window<br/>vulkan surface"]
    world["world<br/>scene graph<br/>change feed"]
    render["render<br/>Vulkan, frame, passes<br/>bindless, looks<br/>2D overlay"]
    ui["ui<br/>2D layout<br/>hit testing"]
    animation["animation<br/>tracks, skeletons<br/>animators, IK"]
    physics["physics<br/>rigid body<br/>BVH broadphase"]
    nav["navigation<br/>runtime: detour, crowd<br/>bake: recast"]
  end

  subgraph L1["Layer 1 — Primitives"]
    direction LR
    geometry["geometry<br/>math, AABB, frustum<br/>BVH, octree"]
    containers["containers<br/>handle pool<br/>slab allocator"]
    input["input<br/>per-tick snapshot<br/>keys, mouse, text"]
    font["font<br/>text metrics<br/>glyphs, atlas"]
  end

  L3 --> L2
  L2 --> L1
```

- No layer-2 module imports another layer-2 module.
- `render` is the only Vulkan user. Its subpackage `render/gpu` is
  the Vulkan layer (context, swapchain, buffers, images, pipelines,
  deferred destruction and the bindless descriptor-array mechanism).
  `render/mesh` holds the vertex format, primitive builders and OBJ
  loader, and `render/gltf` the glTF loader. The passes and render's
  own descriptor arrays (textures 2D and cube, samplers, the mesh arena,
  the scene sets, the indirect draw lists) are private files of
  `package render`. Shaders (`render/shader`)
  and embedded assets (`render/assets`) live inside the module, so
  the folder lifts out whole.
- `platform` is the only GLFW user, including layer 3 and the
  examples. It hands render the instance extensions, the
  proc-address loader and a surface; render never sees a window. It
  writes device events into an `input.Accumulator`; everything else
  reads the per-tick `input.State` snapshot.
- `geometry` is math and spatial structures only. No vertex formats,
  no Vulkan.
- `navigation` splits into a runtime (`navigation`,
  `navigation/detour`, `navigation/crowd`) that never imports Recast
  and a baker (`navigation/bake`) that turns triangles into a
  `NavMesh`; `navigation.init` loads pre-baked data.
- `animation` is headless: it samples tracks and poses skeletons
  into flat arrays. Applying the result (moving a node, uploading a
  skin palette) is the caller's job.

### Layer 3

The `mjolnir` package is optional and holds three things:

- **A run loop** (`run`): update and render cadence and the optional
  update thread. It drives the application's `update` / `frame`
  callbacks and imports no layer-2 module.
- **Asset loading** (`load_gltf`): world nodes over the `render/gltf`
  and `animation/gltf` loaders. It stays here because one asset fills
  several modules.
- **Camera controllers** (`orbit_controller`, `free_controller`,
  `follow_controller`): plain values that drive render's main camera
  from the tick's `input.State` via
  `camera_controller_update(&ctl, &r, &state, dt)`. They ignore
  devices that `state` marks captured. Keys are fixed: WASD + QE to
  move, shift to pan or boost, left drag to orbit. The orbit
  controller reads distance, yaw and pitch from the camera's pose each
  tick, so moving the camera directly never makes it snap back.

Everything else is the application's:

- owning the module values and bringing them up;
- every hop between modules (world → render, input → UIs, UI →
  render, physics → world, animation → render).

Each hop is one or two calls, so swapping a layer-2 module never
touches layer 3. Code that touches a single module belongs in that
module.

---

## World vs render

**World is the logical world; render is the looks.**

- `world` holds nodes: hierarchy, transforms, visibility and user
  tag bits. No meshes, materials, lights, cameras or skeletons. It
  runs headless.
- `render` owns everything that only affects appearance: meshes,
  materials, textures, emitters, force fields, lights and
  cameras, plus their staging into GPU buffers.
- `animation` owns poses. An `Animator` is a plain value the
  application keeps next to the node it drives.

The boundary is the **transform slot**: a `u32` that render keys
every instance on. The convention is slot = world node index, so
`render.attach(&r, node.index, ...)` puts a look on a node. World
publishes what changed each update; render consumes it. Neither
imports the other.

---

## Glue

**Modules never call each other, and the engine provides no glue.**
Cross-module glue is user code made of trivial feed → consume loops;
each module owns its own timing and thread safety, so a hop never
needs scheduling or locking. The world → render hop, for example:

```odin
world.update(&app.scene)
for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
```

These lines live in the application's `update` callback, next to the
physics pose copy and one
`render.stage_bones(&app.renderer, node.index, animator.palette)` per
skinned node. See [engine](engine.html#wiring-modules) for every hop.

---

## Frame phases

```
update tick:  update callback (input snapshot → debug UI / UI / camera input → app + glue → render.update)
render frame: frame callback (poll events → debug UI widgets → ui → overlay
              commands → render.frame (flush → acquire → record → submit + present))
```

- **Update** runs at `UPDATE_FPS` (defaults to `RENDER_FPS`). On its
  own thread if `USE_PARALLEL_UPDATE=true`.
- **Glue** runs inside the `update` callback on the update thread;
  every `render.stage_*` and `render.attach` call is thread-safe.
  `render.update` advances render's own clock (emitters, debug line
  lifetimes).
- **Frame** is one `render.frame` call on the render thread: it
  drains staging into GPU buffers, acquires a swapchain image
  (recreating the swapchain on resize), records, submits, presents
  and retires deferred GPU resources.
- **Record** builds the full pipeline (cull → shadow → geometry →
  lighting → particles → transparency → debug → post-process → UI)
  via dynamic rendering. The UI pass draws game UI and the debug UI.

Update and render are decoupled. Render's staging is the only contact
point.

---

## Render-owned staging

Mutating a look (`attach`, `stage_transforms`, `set_material`,
`create_mesh`, …) writes CPU state and marks the slot dirty in a
mutex-guarded staging set. `render.frame` uploads dirty entries once
per frame on the render thread.

- **Each entry ages per upload.** An update is re-uploaded until
  every frame in flight has it, then dropped.
- **Releases are deferred by `FRAMES_IN_FLIGHT`.** A removal doesn't
  free GPU memory until the GPU is past every frame that might still
  read it. No fence chain per resource.
- **Despawned node slots are held back.** World keeps a despawned
  node's index reserved for `RETIRE_GRACE` updates so the removal
  reaches render before the slot is reused.

---

## Cameras as first-class render targets

Cameras live in render. Each `Camera` carries per-frame attachments
for every G-buffer slot and renders the full scene. The main camera is
the one post-processed and presented; a minimap is just another
camera.

`render.camera_attachment(&r, cam, .FINAL_IMAGE, frame)` returns a
bindless texture handle. Compositing camera B's output into camera
A's material or UI quad is just another bindless index.

Following a logical entity is one glue line:
`render.camera_set_transform(cam, world.world_matrix(&w, player))`.
Orbit, free and follow controllers are render procs that read the
per-tick `input.State` with fixed keys; the application runs the
active one each update tick (`mjolnir.camera_controller_update`).

---

## Deferred shading + light volumes

Forward shading scales as `pixels × lights`. The G-buffer is filled
once; ambient + IBL run as a single fullscreen pass; each direct
light rasterizes its volume (sphere / cone / fullscreen triangle)
with reversed depth so only fragments it can reach get shaded.
Avoids the per-pixel-per-light loop without needing tile or cluster
infrastructure.

---

## Shadows

- **2D maps** for directional + spot. Compute pass clips against the
  light frustum; depth-only graphics pass writes a 512² slice.
- **Cubemap** for point lights. Six frustum-culled depth passes, one
  per face, reuse the same depth-only vertex shader as the 2D maps.

Shadow maps live in `MAX_SHADOW_MAPS` fixed slots. A shadow caster
keeps its map while it casts; new casters, in slot order, take a free
map of their kind first, so maps rarely reallocate.

---

## Physics step

Physics is a user-owned `physics.World`. The user steps it and copies
poses back into the scene graph:

```odin
physics.step(&phys, dt)
for b in physics.body_poses(&phys) do world.set_world_pose(&app.scene, world.NodeHandle(b.user), b.position, b.rotation)
```

Inside `step`:

```
warmstart cache → CCD (park fast bodies before impact) → BVH rebuild if dirty
→ refit → broadphase → narrow-phase (once per frame) → prepare contacts

substep × NUM_SUBSTEPS:
  integrate velocity → warmstart → soft-bias solve
  → integrate position + rotation → relax solve

restitution → sensor overlaps → island sleep
```

Key choices: BVH (not grid) broadphase with moving and static trees,
collide once and solve in substeps with soft contacts (TGS-soft),
speculative contacts plus CCD only for fast bodies, island sleeping.
See [physics](physics.html).

---

## Where to go next

- [`engine`](engine.html) — building an application and wiring modules together.
- [`platform`](platform.html),
  [`world`](world.html), [`render`](render.html),
  [`physics`](physics.html), [`navigation`](navigation.html),
  [`ui`](ui.html), [`animation`](animation.html) — module intros.
- [`examples`](examples.html) — runnable examples and notes.
