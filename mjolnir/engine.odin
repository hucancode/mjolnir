package mjolnir

import "base:runtime"
import "core:c"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"

import linalg "core:math/linalg"
import glfw "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

import "animation"
import "geometry"
import "resource"

RENDER_FPS :: 60.0
FRAME_TIME :: 1.0 / RENDER_FPS
FRAME_TIME_MILIS :: FRAME_TIME * 1_000.0
UPDATE_FPS :: 60.0
UPDATE_FRAME_TIME :: 1.0 / UPDATE_FPS
UPDATE_FRAME_TIME_MILIS :: UPDATE_FRAME_TIME * 1_000.0
MOUSE_SENSITIVITY_X :: 0.005
MOUSE_SENSITIVITY_Y :: 0.005
SCROLL_SENSITIVITY :: 0.5
MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED :: 20

Handle :: resource.Handle

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
Render2DProc :: #type proc(engine: ^Engine, ctx: ^mu.Context)
KeyInputProc :: #type proc(engine: ^Engine, key, action, mods: int)
MousePressProc :: #type proc(engine: ^Engine, key, action, mods: int)
MouseDragProc :: #type proc(engine: ^Engine, delta, offset: linalg.Vector2f64)
MouseScrollProc :: #type proc(engine: ^Engine, offset: linalg.Vector2f64)
MouseMoveProc :: #type proc(engine: ^Engine, pos, delta: linalg.Vector2f64)

CollectLightsContext :: struct {
  engine:        ^Engine,
  light_uniform: ^SceneLightUniform,
}

RenderMeshesContext :: struct {
  engine:         ^Engine,
  command_buffer: vk.CommandBuffer,
  camera_frustum: geometry.Frustum,
  rendered_count: ^u32,
}

ShadowRenderContext :: struct {
  engine:          ^Engine,
  command_buffer:  vk.CommandBuffer,
  obstacles_count: ^u32,
  shadow_idx:      u32,
  shadow_layer:    u32,
  frustum:         geometry.Frustum,
}

InputState :: struct {
  mouse_pos:         linalg.Vector2f64,
  mouse_drag_origin: linalg.Vector2f32,
  mouse_buttons:     [8]bool,
  mouse_holding:     [8]bool,
  key_holding:       [512]bool,
  keys:              [512]bool,
}

Engine :: struct {
  window:                glfw.WindowHandle,
  swapchain:             Swapchain,
  renderer:              Renderer,
  scene:                 Scene,
  ui:                    RendererUI,
  last_frame_timestamp:  time.Time,
  last_update_timestamp: time.Time,
  start_timestamp:       time.Time,
  input:                 InputState,
  setup_proc:            SetupProc,
  update_proc:           UpdateProc,
  render2d_proc:         Render2DProc,
  key_press_proc:        KeyInputProc,
  mouse_press_proc:      MousePressProc,
  mouse_drag_proc:       MouseDragProc,
  mouse_move_proc:       MouseMoveProc,
  mouse_scroll_proc:     MouseScrollProc,
  render_error_count:    u32,
}

g_context: runtime.Context

init :: proc(
  engine: ^Engine,
  width: u32,
  height: u32,
  title: string,
) -> vk.Result {
  context.user_ptr = engine
  g_context = context

  // glfw.SetErrorCallback(glfw_error_callback)
  if !glfw.Init() {
    log.errorf("Failed to initialize GLFW")
    return .ERROR_INITIALIZATION_FAILED
  }
  if !glfw.VulkanSupported() {
    log.errorf("GLFW: Vulkan Not Supported")
    return .ERROR_INITIALIZATION_FAILED
  }
  glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
  engine.window = glfw.CreateWindow(
    c.int(width),
    c.int(height),
    strings.clone_to_cstring(title),
    nil,
    nil,
  )
  if engine.window == nil {
    log.errorf("Failed to create GLFW window")
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof("Window created %v\n", engine.window)
  vulkan_context_init(engine.window) or_return
  factory_init()
  engine.start_timestamp = time.now()
  engine.last_frame_timestamp = engine.start_timestamp
  engine.last_update_timestamp = engine.start_timestamp
  scene_init(&engine.scene)
  build_renderer(engine) or_return
  ui_init(
    &engine.ui,
    engine,
    engine.swapchain.format.format,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
  )
  glfw.SetScrollCallback(
    engine.window,
    proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      geometry.camera_orbit_zoom(
        &engine.scene.camera,
        -f32(yoffset) * SCROLL_SENSITIVITY,
      )
      if engine.mouse_scroll_proc != nil {
        engine.mouse_scroll_proc(engine, {xoffset, yoffset})
      }
    },
  )
  glfw.SetKeyCallback(
    engine.window,
    proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      if engine.key_press_proc != nil {
        engine.key_press_proc(engine, int(key), int(action), int(mods))
      }
    },
  )

  glfw.SetMouseButtonCallback(
    engine.window,
    proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      if engine.mouse_press_proc != nil {
        engine.mouse_press_proc(engine, int(button), int(action), int(mods))
      }
    },
  )
  if engine.setup_proc != nil {
    engine.setup_proc(engine)
  }
  log.infof("Engine initialized")
  return .SUCCESS
}

build_renderer :: proc(engine: ^Engine) -> vk.Result {
  swapchain_init(&engine.swapchain, engine.window) or_return
  renderer_init(
    &engine.renderer,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
    .D32_SFLOAT,
  ) or_return
  return .SUCCESS
}

get_delta_time :: proc(engine: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(engine.last_update_timestamp)))
}

time_since_app_start :: proc(engine: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(engine.start_timestamp)))
}

update :: proc(engine: ^Engine) -> bool {
  glfw.PollEvents()
  delta_time := get_delta_time(engine)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  scene_traverse(&engine.scene)
  for &entry in engine.scene.nodes.entries {
    if !entry.active {
      continue
    }
    data, is_mesh := &entry.item.attachment.(MeshAttachment)
    if !is_mesh {
      continue
    }
    skinning, has_skin := &data.skinning.?
    if !has_skin {
      continue
    }
    anim_inst, has_animation := &skinning.animation.?
    if !has_animation {
      continue
    }
    animation.instance_update(anim_inst, delta_time)
    mesh, found := resource.get(g_meshes, data.handle)
    if !found {
      continue
    }
    mesh_skin, mesh_has_skin := mesh.skinning.?
    if !mesh_has_skin {
      continue
    }
    frame := engine.renderer.frame_index
    buffer := skinning.bone_buffers[frame]
    bone_matrices := slice.from_ptr(buffer.mapped, len(mesh_skin.bones))
    sample_clip(mesh, anim_inst.clip_handle, anim_inst.time, bone_matrices)
    //animation.pose_flush(&skinning.pose, buffer.mapped)
  }
  // update_emitters(&engine.renderer.particle.pipeline_comp, delta_time)
  update_emitters(&engine.renderer.particle, delta_time)
  last_mouse_pos := engine.input.mouse_pos
  engine.input.mouse_pos.x, engine.input.mouse_pos.y = glfw.GetCursorPos(
    engine.window,
  )
  delta := engine.input.mouse_pos - last_mouse_pos
  for i in 0 ..< len(engine.input.mouse_buttons) {
    is_pressed := glfw.GetMouseButton(engine.window, c.int(i)) == glfw.PRESS
    engine.input.mouse_holding[i] = is_pressed && engine.input.mouse_buttons[i]
    engine.input.mouse_buttons[i] = is_pressed
  }
  for k in 0 ..< len(engine.input.keys) {
    is_pressed := glfw.GetKey(engine.window, c.int(k)) == glfw.PRESS
    engine.input.key_holding[k] = is_pressed && engine.input.keys[k]
    engine.input.keys[k] = is_pressed
  }
  if engine.input.mouse_holding[glfw.MOUSE_BUTTON_1] {
    geometry.camera_orbit_rotate(
      &engine.scene.camera,
      f32(delta.x * MOUSE_SENSITIVITY_X),
      f32(delta.y * MOUSE_SENSITIVITY_Y),
    )
  }
  if engine.mouse_move_proc != nil {
    engine.mouse_move_proc(engine, engine.input.mouse_pos, delta)
  }
  if engine.update_proc != nil {
    engine.update_proc(engine, delta_time)
  }
  engine.last_update_timestamp = time.now()
  return true
}

deinit :: proc(engine: ^Engine) {
  vk.DeviceWaitIdle(g_device)
  renderer_ui_deinit(&engine.ui)
  scene_deinit(&engine.scene)
  renderer_deinit(&engine.renderer)
  swapchain_deinit(&engine.swapchain)
  vulkan_context_deinit()
  glfw.DestroyWindow(engine.window)
  glfw.Terminate()
  log.infof("Engine deinitialized")
}

recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  swapchain_recreate(&engine.swapchain, engine.window) or_return
  new_aspect_ratio :=
    f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
  geometry.camera_update_aspect_ratio(engine.scene.camera, new_aspect_ratio)
  renderer_recreate_images(
    &engine.renderer,
    engine.swapchain.format.format,
    engine.swapchain.extent,
  ) or_return
  return .SUCCESS
}

run :: proc(engine: ^Engine, width: u32, height: u32, title: string) {
  if init(engine, width, height, title) != .SUCCESS {
    return
  }
  defer deinit(engine)
  for !glfw.WindowShouldClose(engine.window) {
    update(engine)
    if time.duration_milliseconds(time.since(engine.last_frame_timestamp)) <
       FRAME_TIME_MILIS {
      continue
    }
    res := render(engine)
    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
      recreate_swapchain(engine) or_continue
    }
    if res != .SUCCESS {
      log.errorf("Error during rendering", res)
      engine.render_error_count += 1
      if engine.render_error_count >=
         MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED {
        log.errorf("Too many render errors, exiting...")
        break
      }
    } else {
      engine.render_error_count = 0
    }
    engine.last_frame_timestamp = time.now()
    // break
  }
}
