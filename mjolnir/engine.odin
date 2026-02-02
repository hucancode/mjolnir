package mjolnir

import alg "algebra"
import "animation"
import "base:runtime"
import cont "containers"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "gpu"
import "level_manager"
import nav "navigation"
import "render"
import "render/debug_ui"
import "render/particles"
import "render/visibility"
import "resources"
import "ui"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"
import "world"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
RENDER_FPS :: #config(RENDER_FPS, 60)
FRAME_TIME :: 1.0 / RENDER_FPS
FRAME_TIME_MILIS :: FRAME_TIME * 1_000.0
UPDATE_FPS :: #config(UPDATE_FPS, RENDER_FPS)
UPDATE_FRAME_TIME :: 1.0 / UPDATE_FPS
UPDATE_FRAME_TIME_MILIS :: UPDATE_FRAME_TIME * 1_000.0
MOUSE_SENSITIVITY_X :: 0.005
MOUSE_SENSITIVITY_Y :: 0.005
SCROLL_SENSITIVITY :: 0.5
MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED :: 20
USE_PARALLEL_UPDATE :: #config(USE_PARALLEL_UPDATE, false)
FRAME_LIMIT :: #config(FRAME_LIMIT, 0)

g_context: runtime.Context

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
KeyInputProc :: #type proc(engine: ^Engine, key, action, mods: int)
MousePressProc :: #type proc(engine: ^Engine, key, action, mods: int)
MouseDragProc :: #type proc(engine: ^Engine, delta, offset: [2]f64)
MouseScrollProc :: #type proc(engine: ^Engine, offset: [2]f64)
MouseMoveProc :: #type proc(engine: ^Engine, pos, delta: [2]f64)
PreRenderProc :: #type proc(engine: ^Engine)
PostRenderProc :: #type proc(engine: ^Engine)
CameraController :: world.CameraController

UpdateThreadData :: struct {
  engine: ^Engine,
}

InputState :: struct {
  mouse_pos:         [2]f64,
  mouse_drag_origin: [2]f32,
  mouse_buttons:     [8]bool,
  mouse_holding:     [8]bool,
  key_holding:       [512]bool,
  keys:              [512]bool,
}

Engine :: struct {
  window:                    glfw.WindowHandle,
  gctx:                      gpu.GPUContext,
  rm:                        resources.Manager,
  frame_index:               u32,
  swapchain:                 gpu.Swapchain,
  world:                     world.World,
  nav_sys:                   nav.NavigationSystem,
  last_frame_timestamp:      time.Time,
  last_update_timestamp:     time.Time,
  start_timestamp:           time.Time,
  input:                     InputState,
  setup_proc:                SetupProc,
  update_proc:               UpdateProc,
  key_press_proc:            KeyInputProc,
  mouse_press_proc:          MousePressProc,
  mouse_drag_proc:           MouseDragProc,
  mouse_move_proc:           MouseMoveProc,
  mouse_scroll_proc:         MouseScrollProc,
  pre_render_proc:           PreRenderProc,
  post_render_proc:          PostRenderProc,
  render:                    render.Manager,
  command_buffers:           [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers:   [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  cursor_pos:                [2]i32,
  debug_ui_enabled:          bool,
  update_thread:             Maybe(^thread.Thread),
  update_active:             bool,
  last_render_timestamp:     time.Time,
  orbit_controller:          CameraController,
  free_controller:           CameraController,
  active_controller:         ^CameraController,
  camera_controller_enabled: bool,
  level_manager:             level_manager.Level_Manager,
  ui_hovered_widget:         Maybe(ui.UIWidgetHandle),
}

get_window_dpi :: proc(window: glfw.WindowHandle) -> f32 {
  sw, sh := glfw.GetWindowContentScale(window)
  if sw != sh {
    log.warnf("DPI scale x (%v) and y (%v) not the same, using x", sw, sh)
  }
  return sw
}

init :: proc(
  self: ^Engine,
  width, height: u32,
  title: string,
) -> (
  ret: vk.Result,
) {
  context.user_ptr = self
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
  title_cstr := strings.clone_to_cstring(title)
  defer delete(title_cstr)
  self.window = glfw.CreateWindow(
    c.int(width),
    c.int(height),
    title_cstr,
    nil,
    nil,
  )
  if self.window == nil {
    log.errorf("Failed to create GLFW window")
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof("Window created %v\n", self.window)
  gpu.gpu_context_init(&self.gctx, self.window) or_return
  resources.init(&self.rm, &self.gctx) or_return
  nav.init(&self.nav_sys)
  self.camera_controller_enabled = true
  self.start_timestamp = time.now()
  self.last_frame_timestamp = self.start_timestamp
  self.last_update_timestamp = self.start_timestamp
  world.init(&self.world)
  level_manager.init(&self.level_manager)
  gpu.swapchain_init(&self.swapchain, &self.gctx, self.window) or_return
  gpu.allocate_command_buffer(&self.gctx, self.command_buffers[:]) or_return
  defer if ret != .SUCCESS {
    gpu.free_command_buffer(&self.gctx, ..self.command_buffers[:])
  }
  if self.gctx.has_async_compute {
    gpu.allocate_compute_command_buffer(
      &self.gctx,
      self.compute_command_buffers[:],
    ) or_return
    defer if ret != .SUCCESS {
      gpu.free_compute_command_buffer(
        &self.gctx,
        self.compute_command_buffers[:],
      )
    }
  }
  render.init(
    &self.render,
    &self.gctx,
    &self.rm,
    self.swapchain.extent,
    self.swapchain.format.format,
    get_window_dpi(self.window),
  ) or_return
  if self.gctx.has_async_compute {
    log.infof(
      "Async compute bootstrap: both draw buffers initialized on compute queue",
    )
  } else {
    log.infof(
      "Sequential compute bootstrap: both draw buffers initialized on graphics queue",
    )
  }
  glfw.SetKeyCallback(
    self.window,
    proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      if engine.key_press_proc != nil {
        engine.key_press_proc(engine, int(key), int(action), int(mods))
      }
      mu_key: mu.Key
      switch key {
      case glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT:
        mu_key = .SHIFT
      case glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL:
        mu_key = .CTRL
      case glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT:
        mu_key = .ALT
      case glfw.KEY_BACKSPACE:
        mu_key = .BACKSPACE
      case glfw.KEY_DELETE:
        mu_key = .DELETE
      case glfw.KEY_ENTER:
        mu_key = .RETURN
      case glfw.KEY_LEFT:
        mu_key = .LEFT
      case glfw.KEY_RIGHT:
        mu_key = .RIGHT
      case glfw.KEY_HOME:
        mu_key = .HOME
      case glfw.KEY_END:
        mu_key = .END
      case glfw.KEY_A:
        mu_key = .A
      case glfw.KEY_X:
        mu_key = .X
      case glfw.KEY_C:
        mu_key = .C
      case glfw.KEY_V:
        mu_key = .V
      case:
        return
      }
      switch action {
      case glfw.PRESS, glfw.REPEAT:
        mu.input_key_down(&engine.render.debug_ui.ctx, mu_key)
      case glfw.RELEASE:
        mu.input_key_up(&engine.render.debug_ui.ctx, mu_key)
      case:
        return
      }
      if engine.key_press_proc != nil {
        engine.key_press_proc(engine, int(key), int(action), int(mods))
      }
    },
  )
  glfw.SetMouseButtonCallback(
    self.window,
    proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      mu_btn: mu.Mouse
      switch button {
      case glfw.MOUSE_BUTTON_LEFT:
        mu_btn = .LEFT
      case glfw.MOUSE_BUTTON_RIGHT:
        mu_btn = .RIGHT
      case glfw.MOUSE_BUTTON_MIDDLE:
        mu_btn = .MIDDLE
      }
      x := engine.cursor_pos.x
      y := engine.cursor_pos.y
      switch action {
      case glfw.PRESS, glfw.REPEAT:
        mu.input_mouse_down(&engine.render.debug_ui.ctx, x, y, mu_btn)
      case glfw.RELEASE:
        mu.input_mouse_up(&engine.render.debug_ui.ctx, x, y, mu_btn)
      }
      if engine.mouse_press_proc != nil {
        engine.mouse_press_proc(engine, int(button), int(action), int(mods))
      }
    },
  )
  glfw.SetCursorPosCallback(
    self.window,
    proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      engine.cursor_pos = {i32(math.round(xpos)), i32(math.round(ypos))}
      mu.input_mouse_move(
        &engine.render.debug_ui.ctx,
        engine.cursor_pos.x,
        engine.cursor_pos.y,
      )
      if engine.mouse_move_proc != nil {
        engine.mouse_move_proc(engine, {xpos, ypos}, {0, 0}) // TODO: pass delta
      }
    },
  )
  glfw.SetScrollCallback(
    self.window,
    proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      mu.input_scroll(
        &engine.render.debug_ui.ctx,
        -i32(math.round(xoffset)),
        -i32(math.round(yoffset)),
      )
      if world.g_scroll_deltas == nil {
        world.g_scroll_deltas = make(map[glfw.WindowHandle]f32)
      }
      world.g_scroll_deltas[window] = f32(yoffset)
      if engine.mouse_scroll_proc != nil {
        engine.mouse_scroll_proc(engine, {xoffset, yoffset})
      }
    },
  )
  glfw.SetCharCallback(
    self.window,
    proc "c" (window: glfw.WindowHandle, ch: rune) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      bytes, size := utf8.encode_rune(ch)
      text_str := string(bytes[:size])
      mu.input_text(&engine.render.debug_ui.ctx, text_str)
    },
  )
  if self.camera_controller_enabled {
    world.setup_camera_controller_callbacks(self.window)
    self.orbit_controller = world.camera_controller_orbit_init(self.window)
    self.free_controller = world.camera_controller_free_init(self.window)
    if main_camera := get_main_camera(self); main_camera != nil {
      world.camera_controller_sync(&self.orbit_controller, main_camera)
      world.camera_controller_sync(&self.free_controller, main_camera)
    }
    self.active_controller = &self.orbit_controller
  }
  if self.setup_proc != nil {
    self.setup_proc(self)
  }
  when FRAME_LIMIT > 0 {
    log.infof("Frame limit set to %d", FRAME_LIMIT)
  }
  log.infof("Engine initialized")
  return .SUCCESS
}

get_delta_time :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.last_update_timestamp)))
}

time_since_start :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.start_timestamp)))
}

@(private = "file")
get_main_camera :: proc(self: ^Engine) -> ^resources.Camera {
  return cont.get(self.rm.cameras, self.render.main_camera)
}

update_input :: proc(self: ^Engine) -> bool {
  if level_manager.is_transitioning(&self.level_manager) {
    return true
  }
  glfw.PollEvents()
  last_mouse_pos := self.input.mouse_pos
  self.input.mouse_pos.x, self.input.mouse_pos.y = glfw.GetCursorPos(
    self.window,
  )
  delta := self.input.mouse_pos - last_mouse_pos
  for i in 0 ..< len(self.input.mouse_buttons) {
    is_pressed := glfw.GetMouseButton(self.window, c.int(i)) == glfw.PRESS
    self.input.mouse_holding[i] = is_pressed && self.input.mouse_buttons[i]
    self.input.mouse_buttons[i] = is_pressed
  }
  // PERF: Disabled polling all 512 keys every frame (7ms~ CPU overhead)
  // for k in 0 ..< len(self.input.keys) {
  //   is_pressed := glfw.GetKey(self.window, c.int(k)) == glfw.PRESS
  //   self.input.key_holding[k] = is_pressed && self.input.keys[k]
  //   self.input.keys[k] = is_pressed
  // }

  // UI event handling
  {
    mouse_pos := [2]f32{f32(self.input.mouse_pos.x), f32(self.input.mouse_pos.y)}
    current_widget := ui.pick_widget(&self.render.ui_system, mouse_pos)

    // Handle hover in/out events
    if old_handle, had_old := self.ui_hovered_widget.?; had_old {
      if new_handle, has_new := current_widget.?; has_new {
        // Check if it's a different widget
        old_raw := transmute(cont.Handle)old_handle
        new_raw := transmute(cont.Handle)new_handle
        if old_raw.index != new_raw.index || old_raw.generation != new_raw.generation {
          // Hover out from old widget
          event := ui.MouseEvent {
            type = .HOVER_OUT,
            position = mouse_pos,
            button = 0,
            widget = old_handle,
          }
          ui.dispatch_mouse_event(&self.render.ui_system, old_handle, event, true)

          // Hover in to new widget
          event.type = .HOVER_IN
          event.widget = new_handle
          ui.dispatch_mouse_event(&self.render.ui_system, new_handle, event, true)
        }
      } else {
        // No widget under cursor, hover out from old
        event := ui.MouseEvent {
          type = .HOVER_OUT,
          position = mouse_pos,
          button = 0,
          widget = old_handle,
        }
        ui.dispatch_mouse_event(&self.render.ui_system, old_handle, event, true)
      }
    } else if new_handle, has_new := current_widget.?; has_new {
      // Hover in to new widget (no previous widget)
      event := ui.MouseEvent {
        type = .HOVER_IN,
        position = mouse_pos,
        button = 0,
        widget = new_handle,
      }
      ui.dispatch_mouse_event(&self.render.ui_system, new_handle, event, true)
    }

    // Handle click events
    if widget_handle, has_widget := current_widget.?; has_widget {
      for i in 0 ..< len(self.input.mouse_buttons) {
        if self.input.mouse_buttons[i] && !self.input.mouse_holding[i] {
          // Mouse down
          event := ui.MouseEvent {
            type = .CLICK_DOWN,
            position = mouse_pos,
            button = i32(i),
            widget = widget_handle,
          }
          ui.dispatch_mouse_event(&self.render.ui_system, widget_handle, event, true)
        } else if !self.input.mouse_buttons[i] && self.input.mouse_holding[i] {
          // Mouse up
          event := ui.MouseEvent {
            type = .CLICK_UP,
            position = mouse_pos,
            button = i32(i),
            widget = widget_handle,
          }
          ui.dispatch_mouse_event(&self.render.ui_system, widget_handle, event, true)
        }
      }
    }

    self.ui_hovered_widget = current_widget
  }

  if self.mouse_move_proc != nil {
    self.mouse_move_proc(self, self.input.mouse_pos, delta)
  }
  return true
}

update_visibility_node_count :: proc(
  render: ^render.Manager,
  world: ^world.World,
) {
  n := min(u32(len(world.nodes.entries)), render.visibility.max_draws)
  for ; n > 0; n -= 1 do if world.nodes.entries[n - 1].active do break
  render.visibility.node_count = n
}

update :: proc(self: ^Engine) -> bool {
  context.user_ptr = self
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  level_manager.update(&self.level_manager)
  if level_manager.is_transitioning(&self.level_manager) {
    self.last_update_timestamp = time.now()
    return true
  }
  params := gpu.get(&self.render.particles.params_buffer, 0)
  params.delta_time = delta_time
  params.emitter_count = u32(
    min(len(self.rm.emitters.entries), resources.MAX_EMITTERS),
  )
  params.forcefield_count = u32(
    min(len(self.rm.forcefields.entries), resources.MAX_FORCE_FIELDS),
  )
  if self.camera_controller_enabled && self.active_controller != nil {
    main_camera := get_main_camera(self)
    if main_camera != nil {
      switch self.active_controller.type {
      case .ORBIT:
        world.camera_controller_orbit_update(
          self.active_controller,
          main_camera,
          delta_time,
        )
      case .FREE:
        world.camera_controller_free_update(
          self.active_controller,
          main_camera,
          delta_time,
        )
      case .FOLLOW:
        world.camera_controller_follow_update(
          self.active_controller,
          main_camera,
          delta_time,
        )
      case .CINEMATIC:
      }
    }
  }
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
  }
  world.update_node_animations(&self.world, &self.rm, delta_time)
  world.update_skeletal_animations(
    &self.world,
    &self.rm,
    delta_time,
    self.frame_index,
  )
  world.update_sprite_animations(&self.rm, delta_time)
  self.last_update_timestamp = time.now()
  return true
}

shutdown :: proc(self: ^Engine) {
  vk.DeviceWaitIdle(self.gctx.device)
  level_manager.shutdown(&self.level_manager)
  gpu.free_command_buffer(&self.gctx, ..self.command_buffers[:])
  if self.gctx.has_async_compute {
    gpu.free_compute_command_buffer(&self.gctx, self.compute_command_buffers[:])
  }
  render.shutdown(&self.render, &self.gctx, &self.rm)
  world.shutdown(&self.world, &self.gctx, &self.rm)
  nav.shutdown(&self.nav_sys)
  resources.shutdown(&self.rm, &self.gctx)
  gpu.swapchain_destroy(&self.swapchain, self.gctx.device)
  gpu.shutdown(&self.gctx)
  glfw.DestroyWindow(self.window)
  glfw.Terminate()
  log.infof("Engine deinitialized")
}

@(private = "file")
populate_debug_ui :: proc(self: ^Engine) {
  if mu.window(
    &self.render.debug_ui.ctx,
    "Engine",
    {40, 40, 200, 200},
    {.NO_CLOSE},
  ) {
    mu.label(
      &self.render.debug_ui.ctx,
      fmt.tprintf(
        "Objects %d",
        len(self.world.nodes.entries) - len(self.world.nodes.free_indices),
      ),
    )
    mu.label(
      &self.render.debug_ui.ctx,
      fmt.tprintf(
        "Textures %d",
        len(self.rm.images_2d.entries) - len(self.rm.images_2d.free_indices),
      ),
    )
    mu.label(
      &self.render.debug_ui.ctx,
      fmt.tprintf(
        "Materials %d",
        len(self.rm.materials.entries) - len(self.rm.materials.free_indices),
      ),
    )
    mu.label(
      &self.render.debug_ui.ctx,
      fmt.tprintf(
        "Meshes %d",
        len(self.rm.meshes.entries) - len(self.rm.meshes.free_indices),
      ),
    )
    if main_camera := get_main_camera(self); main_camera != nil {
      main_stats := visibility.stats(
        &self.render.visibility,
        main_camera,
        self.render.main_camera.index,
        self.frame_index,
      )
      mu.label(
        &self.render.debug_ui.ctx,
        fmt.tprintf("Total Objects: %d", self.render.visibility.node_count),
      )
      mu.label(
        &self.render.debug_ui.ctx,
        fmt.tprintf("Draw count: %d draws", main_stats.opaque_draw_count),
      )
    }
  }
}

@(private)
create_light_camera :: proc(
  engine: ^Engine,
  light_handle: LightHandle,
) -> (
  camera_handle: CameraHandle,
  ok: bool,
) #optional_ok {
  light := cont.get(engine.rm.lights, light_handle) or_return
  // Only create cameras for lights that cast shadows
  if !light.cast_shadow do return {}, false
  #partial switch light.type {
  case .POINT:
    // Point lights use spherical cameras for omnidirectional shadows
    cam_handle, spherical_cam := cont.alloc(
      &engine.rm.spherical_cameras,
      SphereCameraHandle,
    ) or_return
    init_result := resources.spherical_camera_init(
      spherical_cam,
      &engine.gctx,
      &engine.rm,
      resources.SHADOW_MAP_SIZE,
      {0, 0, 0}, // center will be updated from light node
      light.radius,
      0.1, // near
      light.radius, // far
      .D32_SFLOAT,
      resources.MAX_NODES_IN_SCENE,
    )
    if init_result != .SUCCESS {
      cont.free(&engine.rm.spherical_cameras, cam_handle)
      return {}, false
    }
    // Allocate descriptors for the spherical camera
    alloc_result := resources.spherical_camera_allocate_descriptors(
      spherical_cam,
      &engine.gctx,
      &engine.rm,
      &engine.render.visibility.sphere_cam_descriptor_layout,
    )
    if alloc_result != .SUCCESS {
      cont.free(&engine.rm.spherical_cameras, cam_handle)
      return {}, false
    }
    // Update the light to reference this camera
    light.camera_handle = cam_handle
    light.camera_index = cam_handle.index
    resources.update_light_gpu_data(&engine.rm, light_handle)
    return cam_handle, true
  case .DIRECTIONAL:
    cam_handle, cam := cont.alloc(&engine.rm.cameras, CameraHandle) or_return
    ortho_size := light.radius * 2.0
    init_result := resources.camera_init_orthographic(
      cam,
      &engine.gctx,
      &engine.rm,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      engine.swapchain.format.format,
      .D32_SFLOAT,
      {.SHADOW},
      {0, 0, 0},
      {0, 0, -1},
      ortho_size,
      ortho_size,
      1.0,
      light.radius * 2.0,
    )
    if init_result != .SUCCESS {
      cont.free(&engine.rm.cameras, cam_handle)
      return {}, false
    }
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      alloc_result := resources.camera_allocate_descriptors(
        &engine.gctx,
        &engine.rm,
        cam,
        u32(frame),
        &engine.render.visibility.normal_cam_descriptor_layout,
        &engine.render.visibility.depth_reduce_descriptor_layout,
      )
      if alloc_result != .SUCCESS {
        cont.free(&engine.rm.cameras, cam_handle)
        return {}, false
      }
    }
    light.camera_handle = cam_handle
    light.camera_index = cam_handle.index
    resources.update_light_gpu_data(&engine.rm, light_handle)
    return cam_handle, true
  case .SPOT:
    cam_handle, cam := cont.alloc(&engine.rm.cameras, CameraHandle) or_return
    fov := light.angle_outer * 2.0
    init_result := resources.camera_init(
      cam,
      &engine.gctx,
      &engine.rm,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      engine.swapchain.format.format,
      .D32_SFLOAT,
      {.SHADOW},
      {0, 0, 0},
      {0, -1, 0},
      fov,
      light.radius * 0.01,
      light.radius,
    )
    if init_result != .SUCCESS {
      cont.free(&engine.rm.cameras, cam_handle)
      return {}, false
    }
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      alloc_result := resources.camera_allocate_descriptors(
        &engine.gctx,
        &engine.rm,
        cam,
        u32(frame),
        &engine.render.visibility.normal_cam_descriptor_layout,
        &engine.render.visibility.depth_reduce_descriptor_layout,
      )
      if alloc_result != .SUCCESS {
        cont.free(&engine.rm.cameras, cam_handle)
        return {}, false
      }
    }
    light.camera_handle = cam_handle
    light.camera_index = cam_handle.index
    resources.update_light_gpu_data(&engine.rm, light_handle)
    return cam_handle, true
  }
  return {}, false
}

@(private)
ensure_light_cameras :: proc(engine: ^Engine) {
  for light_handle in engine.rm.active_lights {
    light := cont.get(engine.rm.lights, light_handle) or_continue
    if !light.cast_shadow || light.camera_handle.generation > 0 do continue
    create_light_camera(engine, light_handle) or_continue
  }
}

@(private = "file")
recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  gpu.swapchain_recreate(
    &engine.gctx,
    &engine.swapchain,
    engine.window,
  ) or_return
  new_aspect_ratio :=
    f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
  if main_camera := get_main_camera(engine); main_camera != nil {
    resources.camera_update_aspect_ratio(main_camera, new_aspect_ratio)
    resources.camera_resize(
      main_camera,
      &engine.gctx,
      &engine.rm,
      engine.swapchain.extent.width,
      engine.swapchain.extent.height,
      engine.swapchain.format.format,
      vk.Format.D32_SFLOAT,
    ) or_return
  }
  render.resize(
    &engine.render,
    &engine.gctx,
    &engine.rm,
    engine.swapchain.extent,
    engine.swapchain.format.format,
    get_window_dpi(engine.window),
  ) or_return
  return .SUCCESS
}

render_and_present :: proc(self: ^Engine) -> vk.Result {
  ensure_light_cameras(self)
  context.user_ptr = self
  gpu.acquire_next_image(
    self.gctx.device,
    &self.swapchain,
    self.frame_index,
  ) or_return
  mu.begin(&self.render.debug_ui.ctx)
  command_buffer := self.command_buffers[self.frame_index]
  gpu.begin_record(command_buffer) or_return
  world.begin_frame(&self.world, &self.rm, 0.016, nil, self.frame_index)
  update_visibility_node_count(&self.render, &self.world)
  resources.update_light_camera(&self.rm, self.render.main_camera, self.frame_index)
  if self.pre_render_proc != nil {
    self.pre_render_proc(self)
  }
  render.render_camera_depth(
    &self.render,
    self.frame_index,
    &self.gctx,
    &self.rm,
    command_buffer,
  ) or_return
  for &entry, cam_index in self.rm.cameras.entries {
    if !entry.active do continue
    cam_handle := CameraHandle {
      index      = u32(cam_index),
      generation = entry.generation,
    }
    cam := &entry.item
    if resources.PassType.GEOMETRY in cam.enabled_passes {
      render.record_geometry_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        &self.rm,
        cam_handle,
        command_buffer,
      )
    }
    if resources.PassType.LIGHTING in cam.enabled_passes {
      render.record_lighting_pass(
        &self.render,
        self.frame_index,
        &self.rm,
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if resources.PassType.PARTICLES in cam.enabled_passes {
      render.record_particles_pass(
        &self.render,
        self.frame_index,
        &self.rm,
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if resources.PassType.TRANSPARENCY in cam.enabled_passes {
      render.record_transparency_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        &self.rm,
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if resources.PassType.DEBUG_DRAW in cam.enabled_passes {
      render.record_debug_draw_pass(
        &self.render,
        self.frame_index,
        &self.rm,
        cam_handle,
        command_buffer,
      )
    }
  }
  render.record_post_process_pass(
    &self.render,
    self.frame_index,
    &self.rm,
    self.render.main_camera,
    self.swapchain.format.format,
    self.swapchain.extent,
    self.swapchain.images[self.swapchain.image_index],
    self.swapchain.views[self.swapchain.image_index],
    command_buffer,
  )
  render.record_ui_pass(
    &self.render,
    self.frame_index,
    &self.gctx,
    &self.rm,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
    command_buffer,
  )
  compute_cmd_buffer: vk.CommandBuffer
  if self.gctx.has_async_compute {
    compute_cmd_buffer = self.compute_command_buffers[self.frame_index]
    gpu.begin_record(compute_cmd_buffer) or_return
  } else {
    compute_cmd_buffer = command_buffer
  }
  render.record_compute_commands(
    &self.render,
    self.frame_index,
    &self.gctx,
    &self.rm,
    compute_cmd_buffer,
  ) or_return
  if self.gctx.has_async_compute {
    gpu.end_record(compute_cmd_buffer) or_return
  }
  populate_debug_ui(self)
  if self.post_render_proc != nil {
    self.post_render_proc(self)
  }
  if level_manager.should_show_loading(&self.level_manager) {
    TEXT :: "Loading..."
    ctx := &self.render.debug_ui.ctx
    w := i32(self.swapchain.extent.width)
    h := i32(self.swapchain.extent.height)
    container_w: i32 = 400
    container_h: i32 = 200
    x := (w - container_w) / 2
    y := (h - container_h) / 2
    if mu.begin_window(
      ctx,
      "##loading",
      {x, y, container_w, container_h},
      {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL},
    ) {
      mu.layout_row(ctx, {-1}, 0)
      mu.layout_row(ctx, {-1}, 80)
      mu.label(ctx, TEXT)
      mu.end_window(ctx)
    }
  }
  mu.end(&self.render.debug_ui.ctx)
  if self.debug_ui_enabled {
    debug_ui.begin_pass(
      &self.render.debug_ui,
      command_buffer,
      self.swapchain.views[self.swapchain.image_index],
      self.swapchain.extent,
    )
    debug_ui.render(&self.render.debug_ui, command_buffer)
    debug_ui.end_pass(&self.render.debug_ui, command_buffer)
  }
  // Transition swapchain image to present layout
  present_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
    dstAccessMask = {},
    oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = self.swapchain.images[self.swapchain.image_index],
    subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.BOTTOM_OF_PIPE},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &present_barrier,
  )
  gpu.end_record(command_buffer) or_return
  gpu.submit_queue_and_present(
    &self.gctx,
    &self.swapchain,
    &command_buffer,
    &compute_cmd_buffer,
    self.frame_index,
  ) or_return
  self.frame_index = alg.next(self.frame_index, FRAMES_IN_FLIGHT)
  world.process_pending_deletions(&self.world, &self.rm, &self.gctx)
  self.last_render_timestamp = time.now()
  return .SUCCESS
}

run :: proc(self: ^Engine, width, height: u32, title: string) {
  if init(self, width, height, title) != .SUCCESS {
    return
  }
  defer shutdown(self)
  when USE_PARALLEL_UPDATE {
    self.update_active = true
    update_data := UpdateThreadData {
      engine = self,
    }
    update_thread := thread.create(update_thread_proc)
    update_thread.data = &update_data
    update_thread.init_context = context
    thread.start(update_thread)
    self.update_thread = update_thread
    defer {
      self.update_active = false
      thread.join(update_thread)
      thread.destroy(update_thread)
    }
  }
  frame := 0
  render_error_count := 0
  for !glfw.WindowShouldClose(self.window) {
    update_input(self)
    when !USE_PARALLEL_UPDATE {
      update(self)
    }
    if time.duration_milliseconds(time.since(self.last_frame_timestamp)) <
       FRAME_TIME_MILIS {
      continue
    }
    self.last_frame_timestamp = time.now()
    res := render_and_present(self)
    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
      recreate_swapchain(self) or_continue
    }
    if res != .SUCCESS {
      log.errorf("Error during rendering %v", res)
      render_error_count += 1
      if render_error_count >= MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED {
        log.errorf("Too many render errors, exiting...")
        break
      }
    } else {
      render_error_count = 0
    }
    frame += 1
    when FRAME_LIMIT > 0 {
      if frame >= FRAME_LIMIT {
        log.infof("Reached frame limit %d, exiting gracefully", FRAME_LIMIT)
        break
      }
    }
  }
}

update_thread_proc :: proc(thread: ^thread.Thread) {
  data := cast(^UpdateThreadData)thread.data
  engine := data.engine
  for engine.update_active {
    should_update := update(engine)
    if !should_update {
      time.sleep(time.Millisecond * 2)
    }
  }
  log.info("Update thread terminating")
}
