---
title: mjolnir API
---
# `mjolnir` (engine.odin) — API Reference

Layer 3. Owns the window, swapchain, frames-in-flight, the `Engine` struct,
and the main loop. Wires together world/render/physics/navigation/UI without
ever leaking their internals back through.

Two entry points: `run_app(RunConfig)` for the common case, or
`init`/`run`/`shutdown` for a hand-rolled lifecycle. Plus a set of callback
fields on `Engine` and the [shortcut procs](#shortcuts) that let user code
say `mjolnir.spawn(engine, ...)` instead of `world.spawn(&engine.world, ...)`.

## Engine

```odin
Engine :: struct {
  window:                    glfw.WindowHandle,
  gctx:                      gpu.GPUContext,
  frame_index:               u32,
  swapchain:                 gpu.Swapchain,

  world:                     world.World,
  nav:                       nav.NavigationSystem,
  ui:                        ui_module.System,
  render:                    render.Manager,

  last_frame_timestamp:      time.Time,
  last_update_timestamp:     time.Time,
  start_timestamp:           time.Time,
  last_render_timestamp:     time.Time,

  input:                     InputState,
  cursor_pos:                [2]i32,
  ui_hovered_widget:         Maybe(ui_module.UIWidgetHandle),

  setup_proc:                SetupProc,
  update_proc:               UpdateProc,
  key_press_proc:            KeyInputProc,
  mouse_press_proc:          MousePressProc,
  mouse_drag_proc:           MouseDragProc,
  mouse_move_proc:           MouseMoveProc,
  mouse_scroll_proc:         MouseScrollProc,
  pre_render_proc:           PreRenderProc,
  post_render_proc:          PostRenderProc,

  debug_ui_enabled:          bool,
  camera_controller_enabled: bool,
  update_thread:             Maybe(^thread.Thread),
  update_active:             bool,

  user_data:                 rawptr,   // opaque user pointer; stash app state here
}
```

`user_data` lets app code avoid file-scope globals. Cast it back to your own
struct pointer inside callbacks:

```odin
GameState :: struct { score: i32, player: mjolnir.NodeHandle }
state: GameState

mjolnir.run_app({
  user_data = &state,
  update    = proc(e: ^mjolnir.Engine, dt: f32) {
    s := (^GameState)(e.user_data)
    s.score += 1
  },
})
```

## InputState

```odin
InputState :: struct {
  mouse_pos:         [2]f64,
  mouse_drag_origin: [2]f32,
  mouse_buttons:     [8]bool,
  mouse_holding:     [8]bool,    // pressed last frame AND this frame
  key_holding:       [512]bool,  // pressed last frame AND this frame
  keys:              [512]bool,  // current frame
}
```

## Callback signatures

```odin
SetupProc        :: #type proc(engine: ^Engine)
UpdateProc       :: #type proc(engine: ^Engine, delta_time: f32)
KeyInputProc     :: #type proc(engine: ^Engine, key, action, mods: int)
MousePressProc   :: #type proc(engine: ^Engine, button, action, mods: int)
MouseDragProc    :: #type proc(engine: ^Engine, delta, offset: [2]f64)    // currently a stub
MouseMoveProc    :: #type proc(engine: ^Engine, pos, delta: [2]f64)
MouseScrollProc  :: #type proc(engine: ^Engine, offset: [2]f64)
PreRenderProc    :: #type proc(engine: ^Engine)
PostRenderProc   :: #type proc(engine: ^Engine)
```

| Callback | Fires | Thread | Allowed mutations |
|---|---|---|---|
| `setup_proc` | once after init, before main loop | main | world, render setup |
| `update_proc` | per UPDATE_FPS tick | main *or* update thread | world (staging is mutex-safe) |
| `key_press_proc` | per key event (twice: before+after microui) | GLFW callback ctx | input state |
| `mouse_press_proc` | per button event | GLFW callback ctx | input state |
| `mouse_move_proc` | per frame in `update_input` | main | input state |
| `mouse_scroll_proc` | per scroll event | GLFW callback ctx | `world.g_scroll_deltas` |
| `mouse_drag_proc` | not currently fired (stub) | — | — |
| `pre_render_proc` | once per frame after sync | main | render state (pre-record) |
| `post_render_proc` | once per frame after present | main | metrics, async load triggers |

## Build constants

```odin
FRAMES_IN_FLIGHT                            :: #config(FRAMES_IN_FLIGHT, 2)
RENDER_FPS                                  :: #config(RENDER_FPS, 60)
FRAME_TIME                                  :: 1.0 / RENDER_FPS
FRAME_TIME_MILIS                            :: FRAME_TIME * 1_000.0
UPDATE_FPS                                  :: #config(UPDATE_FPS, RENDER_FPS)
UPDATE_FRAME_TIME                           :: 1.0 / UPDATE_FPS
UPDATE_FRAME_TIME_MILIS                     :: UPDATE_FRAME_TIME * 1_000.0
MOUSE_SENSITIVITY_X                         :: 0.005
MOUSE_SENSITIVITY_Y                         :: 0.005
SCROLL_SENSITIVITY                          :: 0.5
MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED  :: 20
USE_PARALLEL_UPDATE                         :: #config(USE_PARALLEL_UPDATE, false)
FRAME_LIMIT                                 :: #config(FRAME_LIMIT, 0)   // 0 = unlimited
```

## Lifecycle

```odin
RunConfig :: struct {
  title:        string,
  width:        u32,             // 0 → 800
  height:       u32,             // 0 → 600
  setup:        SetupProc,
  update:       UpdateProc,
  pre_render:   PreRenderProc,
  post_render:  PostRenderProc,
  key_press:    KeyInputProc,
  mouse_press:  MousePressProc,
  mouse_move:   MouseMoveProc,
  mouse_scroll: MouseScrollProc,
  mouse_drag:   MouseDragProc,
  user_data:    rawptr,
  debug_ui:     bool,
}

run_app (cfg: RunConfig)                                      // recommended entry point
init    (self, width, height: u32, title: string) -> vk.Result
shutdown(self)
run     (self, width, height: u32, title: string)
```

`run_app` allocates the engine, installs a console logger, calls `run`, and
frees on exit. Smallest app:

```odin
mjolnir.run_app({
  title = "Cube",
  setup = proc(e: ^mjolnir.Engine) {
    mjolnir.spawn_primitive_mesh(e, .CUBE, .RED)
    mjolnir.main_camera_look_at(e, {3, 2, 3}, {0, 0, 0})
  },
})
```

`run` calls `init` → loop → `shutdown`. Don't call `init`/`shutdown`
yourself unless you need to drive the loop manually.

`init` does, in order:
1. `glfw.Init` and create window.
2. `gpu.gpu_context_init`.
3. `nav.init`.
4. `world.init`.
5. `gpu.swapchain_init`.
6. `ui_module.init`.
7. `render.init` and `render.setup`.
8. Register input callbacks (key, mouse, cursor, scroll, char).
9. Register camera-controller callbacks if enabled.
10. Create main camera if not present.
11. Call user `setup_proc`.

`shutdown` does the inverse, in reverse order, after `vkDeviceWaitIdle`.

## Per-frame procs

```odin
update          (self) -> bool        // returns false if delta < UPDATE_FRAME_TIME
update_input    (self) -> bool

get_delta_time  (self) -> f32         // elapsed since last update tick
time_since_start(self) -> f32         // elapsed since engine start

sync_staging_to_gpu(self) -> vk.Result
sync_ui_to_renderer(self)

render_and_present (self) -> vk.Result
recreate_swapchain (engine: ^Engine) -> vk.Result
```

`run` orchestrates all of these. You only call them yourself if you build a
custom loop on top of `init` + `shutdown`.

## Shortcuts {#shortcuts}

Every public `world.*` / `physics.*` / `nav.*` proc that takes a `^World`,
`^physics.World`, or `^NavigationSystem` has a sibling here that takes
`^Engine`. Pure forwarders — zero behavior change. They eliminate the
`&engine.world` / `&engine.physics` / `&engine.nav` plumbing.

```odin
// Old
world.spawn_primitive_mesh(&engine.world, .CUBE, .RED)
world.translate_by(&engine.world, h, y = dt)
nav.find_path(&engine.nav, a, b)
physics.create_dynamic_body(&engine.physics, pos, rot, mass, collider)

// New
mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED)
mjolnir.translate_by(engine, h, y = dt)
mjolnir.find_path(engine, a, b)
mjolnir.create_dynamic_body(engine, pos, rot, mass, collider)
```

Re-exported type aliases (interchangeable with `world.*` originals):

```odin
NodeHandle, MeshHandle, MaterialHandle, CameraHandle, ClipHandle,
EmitterHandle, SpriteHandle, Primitive, Color, NodeTag, NodeTagSet,
MeshAttachment, NodeAttachment, SpiderLegSpec
```

Shortcut groups (full signatures live in the relevant API page):

| Group | Procs |
|---|---|
| **Spawn** | `spawn`, `spawn_child`, `spawn_mesh`, `spawn_primitive_mesh`, `spawn_light_directional`, `spawn_light_point`, `spawn_light_spot`, `spawn_emitter`, `spawn_forcefield`, `despawn`, `attach` |
| **Transform** | `translate`, `translate_by`, `rotate`, `rotate_by`, `scale`, `scale_xyz` |
| **Accessors** | `node`, `mesh`, `material`, `camera`, `main_camera`, `main_camera_handle`, `valid`, `point_light`, `directional_light`, `spot_light`, `mesh_child`, `skinned_mesh`, `bone_rest_position`, `bone_rest_offset`, `node_mesh`, `tag`, `untag` |
| **Camera** | `main_camera_look_at`, `mark_camera_dirty` |
| **Materials & meshes** | `material_pbr`, `material_textured`, `material_unlit`, `material_wireframe`, `material_transparent`, `create_material`, `builtin_mesh`, `builtin_material`, `create_mesh` |
| **Setters** | `set_light_color`, `set_light_intensity`, `set_light_radius`, `mark_light_dirty`, `set_material_handle`, `set_mesh_handle`, `stage_material_data` |
| **Animation** | `play_animation`, `add_animation_layer`, `set_animation_layer_weight`, `transition_to_animation`, `add_ik_layer`, `add_ik_layer_chain`, `set_ik_layer_target`, `add_tail_modifier_layer`, `set_tail_modifier_params`, `add_path_modifier_layer`, `set_path_modifier_params`, `add_spider_leg_modifier_layer`, `set_spider_leg_modifier_params`, `get_spider_leg_target` |
| **Navigation** | `find_path`, `find_nearest_point` |
| **Physics** | `create_static_body`, `create_dynamic_body`, `get_dynamic_body`, `spawn_static`, `spawn_dynamic` |

`spawn_static` / `spawn_dynamic` are higher-level conveniences that combine
node spawn + body create + (optional) visual child + auto inertia from
collider in one call.

```odin
ground := mjolnir.spawn_static(engine, {0, -0.5, 0},
  physics.BoxCollider{half_extents = {20, 0.5, 20}},
  ground_mesh, ground_mat, visual_scale = {20, 0.5, 20})

cube_node, cube_body := mjolnir.spawn_dynamic(engine, {0, 10, 0}, mass = 50,
  physics.BoxCollider{half_extents = {1, 1, 1}}, cube_mesh, cube_mat)
```

`translate` / `rotate` / `scale` are overload groups — pass either xyz
floats, a `[3]f32`, a quaternion, or `(angle, axis)`. See `mjolnir/shortcuts.odin`
for the exact signatures.

## Asset loading

```odin
load_gltf(engine, path: string) -> (nodes: [dynamic]world.NodeHandle, ok: bool) #optional_ok
```

## Texture creation (overloaded)

```odin
create_texture :: proc {
  create_texture_from_path,
  create_texture_from_data,
  create_texture_from_pixels,
  create_texture_empty,
}

create_texture_from_path  (engine, path,    format = .R8G8B8A8_SRGB, generate_mips = false,
                           usage = {.SAMPLED}, is_hdr = false)
                          -> (gpu.Texture2DHandle, bool) #optional_ok

create_texture_from_data  (engine, data: []u8, format = .R8G8B8A8_SRGB, generate_mips = false)
                          -> (gpu.Texture2DHandle, bool) #optional_ok

create_texture_from_pixels(engine, pixels: []u8, extent: vk.Extent2D,
                           format = .R8G8B8A8_SRGB, generate_mips = false)
                          -> (gpu.Texture2DHandle, bool) #optional_ok

create_texture_empty      (engine, extent, format,
                           usage = {.COLOR_ATTACHMENT, .SAMPLED})
                          -> (gpu.Texture2DHandle, bool) #optional_ok
```

## Camera attachment lookup

```odin
get_camera_attachment(engine, camera_handle: world.CameraHandle,
                      attachment_type: render.AttachmentType,
                      frame_index: u32 = 0)
                     -> (gpu.Texture2DHandle, bool) #optional_ok
```

Returns the bindless texture handle for any of `POSITION`, `NORMAL`, `ALBEDO`,
`METALLIC_ROUGHNESS`, `EMISSIVE`, `FINAL_IMAGE`, `DEPTH` for the requested
camera. Use it to composite secondary cameras (minimaps, mirrors,
cubemap renders) into the main view.

## Navigation

```odin
NavMeshQuality :: enum { LOW, MEDIUM, HIGH, ULTRA }

NavMeshConfig :: struct {
  agent_height:    f32,
  agent_radius:    f32,
  agent_max_climb: f32,
  agent_max_slope: f32,    // radians
  quality:         NavMeshQuality,
}

DEFAULT_NAVMESH_CONFIG :: NavMeshConfig{
  agent_height = 2.0, agent_radius = 0.6, agent_max_climb = 0.9,
  agent_max_slope = math.PI * 0.25, quality = .MEDIUM,
}

setup_navmesh(engine, config = DEFAULT_NAVMESH_CONFIG,
              include_filter: world.NodeTagSet = {},
              exclude_filter: world.NodeTagSet = {}) -> bool
```

## Error codes

`vk.Result` values returned by `init` / `render_and_present`:

| Code | Meaning |
|---|---|
| `.SUCCESS` | All good. |
| `.ERROR_INITIALIZATION_FAILED` | GPU/GLFW init failed (from `init`). |
| `.ERROR_OUT_OF_DATE_KHR` | Swapchain stale; `run` calls `recreate_swapchain`. |
| `.SUBOPTIMAL_KHR` | Swapchain suboptimal; recreation recommended. `run` logs and continues. |
| other | Other Vulkan device errors. |

`run` exits if the engine accumulates `MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED`
(20) consecutive render errors.

## Threading

- `update` runs on the main thread by default.
- With `-define:USE_PARALLEL_UPDATE=true` it runs on a dedicated thread that
  sleeps 2 ms between ticks. The main thread keeps polling input and rendering
  independently.
- World mutations from any thread go through `world.staging` (mutex-protected).
- `sync_staging_to_gpu` always runs on the main thread, holding the staging
  mutex for the duration.
- GPU frame submission uses fences + semaphores in `gpu.Swapchain` for the
  classic double-buffer pattern.

## Allocation ownership

| Owned by engine, freed in `shutdown` | Owned by user |
|---|---|
| window, gctx, swapchain, render, world, ui, nav | callbacks (function pointers you set) |
| staging buffers (auto-aged) | array returned by `load_gltf` (you must `delete`) |
| created textures (lifetime tied to `texture_manager`) | `^Engine` itself (you `new` it) |

## Globals

```odin
g_context: runtime.Context     // captured in init, restored inside GLFW callbacks
world.g_scroll_deltas: map[glfw.WindowHandle]f32   // lazily populated
```
