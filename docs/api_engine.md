# `mjolnir` (engine.odin) — API Reference

Layer 3. Single file. Owns the window, swapchain, frames-in-flight, the
`Engine` struct, and the main loop. Wires together world/render/physics/
navigation/UI without ever leaking their internals back through.

The user-facing API is just three procs to start (`init`, `run`, `shutdown`)
plus a set of callback fields on the `Engine` struct.

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
}
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
init    (self, width, height: u32, title: string) -> vk.Result
shutdown(self)
run     (self, width, height: u32, title: string)
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
