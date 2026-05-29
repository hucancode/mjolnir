package mjolnir

import alg "algebra"
import "base:runtime"
import cont "containers"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "gpu"
import nav "navigation"
import "physics"
import "render"
import ui_module "ui"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"
import "world"

// Verify world and GPU handle types have identical memory layout for safe transmutes
#assert(size_of(world.MeshHandle) == size_of(gpu.MeshHandle))

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
  frame_index:               u32,
  swapchain:                 gpu.Swapchain,
  world:                     world.World,
  physics:                   physics.World,
  nav:                       nav.NavigationSystem,
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
  ui:                        ui_module.System, // NEW: Logical UI system (moved from render.Manager)
  render:                    render.Manager,
  cursor_pos:                [2]i32,
  debug_ui_enabled:          bool,
  update_thread:             Maybe(^thread.Thread),
  update_active:             bool,
  last_render_timestamp:     time.Time,
  camera_controller_enabled: bool,
  ui_hovered_widget:         Maybe(ui_module.UIWidgetHandle),
  // Set on PRESS when debug UI captured the click. Cleared on RELEASE.
  // Used so the matching RELEASE is also withheld from user procs and
  // camera controller, regardless of where the cursor ends up.
  ui_captured_mouse_button:  [8]bool,
  // Opaque user pointer — stash app state here instead of using globals.
  user_data:                 rawptr,
}

// True when the debug UI is hovered or has an active pop-up. Mouse input
// (click / move / scroll) should not propagate to camera or game callbacks.
debug_ui_wants_mouse :: proc(self: ^Engine) -> bool {
  return self.render.debug_ui.ctx.hover_root != nil
}

// True when the debug UI has keyboard focus (e.g. text box). Keyboard input
// should not propagate to camera or game callbacks.
debug_ui_wants_keyboard :: proc(self: ^Engine) -> bool {
  return self.render.debug_ui.ctx.focus_id != 0
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
  if !physics.init(&self.physics) do return .ERROR_INITIALIZATION_FAILED
  if !nav.init(&self.nav) do return .ERROR_INITIALIZATION_FAILED
  self.camera_controller_enabled = true
  self.start_timestamp = time.now()
  self.last_frame_timestamp = self.start_timestamp
  self.last_update_timestamp = self.start_timestamp
  if !world.init(&self.world) do return .ERROR_INITIALIZATION_FAILED
  gpu.swapchain_init(&self.swapchain, &self.gctx, self.window) or_return
  if !ui_module.init(&self.ui) do return .ERROR_INITIALIZATION_FAILED
  render.init(
    &self.render,
    &self.gctx,
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
      if key >= 0 && int(key) < len(engine.input.keys) {
        is_pressed := action == glfw.PRESS || action == glfw.REPEAT
        engine.input.key_holding[key] = is_pressed && engine.input.keys[key]
        engine.input.keys[key] = is_pressed
      }
      if engine.key_press_proc != nil && !debug_ui_wants_keyboard(engine) {
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
      btn_idx := int(button)
      captured := false
      switch action {
      case glfw.PRESS, glfw.REPEAT:
        if debug_ui_wants_mouse(engine) {
          if btn_idx >= 0 && btn_idx < len(engine.ui_captured_mouse_button) {
            engine.ui_captured_mouse_button[btn_idx] = true
          }
          captured = true
        }
      case glfw.RELEASE:
        if btn_idx >= 0 && btn_idx < len(engine.ui_captured_mouse_button) {
          if engine.ui_captured_mouse_button[btn_idx] {
            engine.ui_captured_mouse_button[btn_idx] = false
            captured = true
          }
        }
      }
      if engine.mouse_press_proc != nil && !captured {
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
      drag_captured_by_ui := false
      for held in engine.ui_captured_mouse_button {
        if held {
          drag_captured_by_ui = true
          break
        }
      }
      block := drag_captured_by_ui || debug_ui_wants_mouse(engine)
      if engine.mouse_move_proc != nil && !block {
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
      if debug_ui_wants_mouse(engine) {
        return
      }
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
  setup(self) or_return
  if self.camera_controller_enabled {
    world.setup_camera_controller_callbacks(self.window)
    self.world.orbit_controller = world.camera_controller_orbit_init(
      self.window,
    )
    self.world.free_controller = world.camera_controller_free_init(self.window)
    if main_camera := get_main_camera(self); main_camera != nil {
      world.camera_controller_sync(&self.world.orbit_controller, main_camera)
      world.camera_controller_sync(&self.world.free_controller, main_camera)
    }
    self.world.active_controller = &self.world.orbit_controller
  }
  when FRAME_LIMIT > 0 {
    log.infof("Frame limit set to %d", FRAME_LIMIT)
  }
  log.infof("Engine initialized")
  return .SUCCESS
}

setup :: proc(self: ^Engine) -> (ret: vk.Result) {
  render.setup(
    &self.render,
    &self.gctx,
    self.swapchain.extent,
    self.swapchain.format.format,
  ) or_return
  defer if ret != .SUCCESS {
    render.teardown(&self.render, &self.gctx)
  }
  // Initialize UI GPU resources (font atlas, default texture)
  ui_module.init_gpu_resources(
    &self.ui,
    &self.gctx,
    &self.render.texture_manager,
  )
  // Create main camera if it doesn't exist yet
  if cont.get(self.world.cameras, self.world.main_camera) == nil {
    main_world_handle, main_world_camera, ok_main_camera := cont.alloc(
      &self.world.cameras,
      world.CameraHandle,
    )
    if !ok_main_camera do return .ERROR_INITIALIZATION_FAILED
    self.world.main_camera = main_world_handle
    if !world.camera_init(
      main_world_camera,
      self.swapchain.extent.width,
      self.swapchain.extent.height,
      camera_position = {3, 4, 3},
      camera_target = {0, 0, 0},
      fov = math.PI * 0.5,
      near_plane = 0.1,
      far_plane = 1000.0,
    ) {
      return .ERROR_INITIALIZATION_FAILED
    }
  }
  world.stage_camera_data(&self.world.staging, self.world.main_camera)
  if self.setup_proc != nil {
    self.setup_proc(self)
  }
  return .SUCCESS
}

teardown :: proc(self: ^Engine) {
  vk.DeviceWaitIdle(self.gctx.device)
  ui_module.shutdown_gpu_resources(
    &self.ui,
    &self.gctx,
    &self.render.texture_manager,
  )
  render.teardown(&self.render, &self.gctx)
}

@(private = "file")
get_main_camera :: proc(self: ^Engine) -> ^world.Camera {
  return cont.get(self.world.cameras, self.world.main_camera)
}

update_input :: proc(self: ^Engine) -> bool {
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
    mouse_pos := [2]f32 {
      f32(self.input.mouse_pos.x),
      f32(self.input.mouse_pos.y),
    }
    current_widget := ui_module.pick_widget(&self.ui, mouse_pos)

    // Handle hover in/out events
    if old_handle, had_old := self.ui_hovered_widget.?; had_old {
      if new_handle, has_new := current_widget.?; has_new {
        // Check if it's a different widget
        old_raw := transmute(cont.Handle)old_handle
        new_raw := transmute(cont.Handle)new_handle
        if old_raw.index != new_raw.index ||
           old_raw.generation != new_raw.generation {
          // Hover out from old widget
          event := ui_module.MouseEvent {
            type     = .HOVER_OUT,
            position = mouse_pos,
            button   = 0,
            widget   = old_handle,
          }
          ui_module.dispatch_mouse_event(&self.ui, old_handle, event, true)

          // Hover in to new widget
          event.type = .HOVER_IN
          event.widget = new_handle
          ui_module.dispatch_mouse_event(&self.ui, new_handle, event, true)
        }
      } else {
        // No widget under cursor, hover out from old
        event := ui_module.MouseEvent {
          type     = .HOVER_OUT,
          position = mouse_pos,
          button   = 0,
          widget   = old_handle,
        }
        ui_module.dispatch_mouse_event(&self.ui, old_handle, event, true)
      }
    } else if new_handle, has_new := current_widget.?; has_new {
      // Hover in to new widget (no previous widget)
      event := ui_module.MouseEvent {
        type     = .HOVER_IN,
        position = mouse_pos,
        button   = 0,
        widget   = new_handle,
      }
      ui_module.dispatch_mouse_event(&self.ui, new_handle, event, true)
    }

    // Handle click events
    if widget_handle, has_widget := current_widget.?; has_widget {
      for i in 0 ..< len(self.input.mouse_buttons) {
        if self.input.mouse_buttons[i] && !self.input.mouse_holding[i] {
          // Mouse down
          event := ui_module.MouseEvent {
            type     = .CLICK_DOWN,
            position = mouse_pos,
            button   = i32(i),
            widget   = widget_handle,
          }
          ui_module.dispatch_mouse_event(&self.ui, widget_handle, event, true)
        } else if !self.input.mouse_buttons[i] && self.input.mouse_holding[i] {
          // Mouse up
          event := ui_module.MouseEvent {
            type     = .CLICK_UP,
            position = mouse_pos,
            button   = i32(i),
            widget   = widget_handle,
          }
          ui_module.dispatch_mouse_event(&self.ui, widget_handle, event, true)
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

update :: proc(self: ^Engine) -> bool {
  context.user_ptr = self
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  self.last_update_timestamp = time.now()
  render.set_particle_params(
    &self.render,
    {
      delta_time = delta_time,
      emitter_count = u32(
        min(len(self.world.emitters.entries), world.MAX_EMITTERS),
      ),
      forcefield_count = u32(
        min(len(self.world.forcefields.entries), world.MAX_FORCE_FIELDS),
      ),
    },
  )
  if self.camera_controller_enabled && self.world.active_controller != nil {
    main_camera := get_main_camera(self)
    if main_camera != nil {
      self.world.active_controller.mouse_blocked = debug_ui_wants_mouse(self)
      self.world.active_controller.keyboard_blocked = debug_ui_wants_keyboard(self)
      switch self.world.active_controller.type {
      case .ORBIT:
        world.camera_controller_orbit_update(
          self.world.active_controller,
          main_camera,
          delta_time,
        )
      case .FREE:
        world.camera_controller_free_update(
          self.world.active_controller,
          main_camera,
          delta_time,
        )
      case .FOLLOW:
        world.camera_controller_follow_update(
          self.world.active_controller,
          main_camera,
          delta_time,
        )
      case .CINEMATIC:
      }
      world.stage_camera_data(&self.world.staging, self.world.main_camera)
    }
  }
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
  }
  physics.step(&self.physics, delta_time)
  world.sync_all_physics_to_world(&self.world, &self.physics)
  world.update_node_animations(&self.world, delta_time)
  world.update_skeletal_animations(&self.world, delta_time)
  world.update_sprite_animations(&self.world, delta_time)
  world.tick_emitters(&self.world, delta_time)
  self.last_update_timestamp = time.now()
  return true
}

shutdown :: proc(self: ^Engine) {
  teardown(self)
  render.shutdown(&self.render, &self.gctx)
  ui_module.shutdown(&self.ui)
  world.shutdown(&self.world)
  physics.shutdown(&self.physics)
  nav.shutdown(&self.nav)
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
    {},
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
        cont.count(self.render.texture_manager.images_2d),
      ),
    )
    mu.label(
      &self.render.debug_ui.ctx,
      fmt.tprintf(
        "Materials %d",
        len(self.world.materials.entries) -
        len(self.world.materials.free_indices),
      ),
    )
    mu.label(
      &self.render.debug_ui.ctx,
      fmt.tprintf(
        "Meshes %d",
        len(self.world.meshes.entries) - len(self.world.meshes.free_indices),
      ),
    )
    if main_camera := get_main_camera(self); main_camera != nil {
      stats := render.visibility_stats(
        &self.render,
        self.world.main_camera.index,
        self.frame_index,
      )
      mu.label(
        &self.render.debug_ui.ctx,
        fmt.tprintf("Total Objects: %d", stats.node_count),
      )
      mu.label(
        &self.render.debug_ui.ctx,
        fmt.tprintf("Draw count: %d draws", stats.opaque_draw_count),
      )
    }
  }
}

@(private = "file")
recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  old_extent := engine.swapchain.extent
  gpu.swapchain_recreate(
    &engine.gctx,
    &engine.swapchain,
    engine.window,
  ) or_return
  new_aspect_ratio :=
    f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
  for &entry, cam_index in engine.world.cameras.entries {
    if !entry.active do continue
    world_camera := &entry.item
    world.camera_update_aspect_ratio(world_camera, new_aspect_ratio)
    if world_camera.extent[0] == old_extent.width &&
       world_camera.extent[1] == old_extent.height {
      world.camera_resize(
        world_camera,
        engine.swapchain.extent.width,
        engine.swapchain.extent.height,
      )
    }
    world.stage_camera_data(
      &engine.world.staging,
      world.CameraHandle {
        index = u32(cam_index),
        generation = entry.generation,
      },
    )
    if cam, ok := &engine.render.cameras[u32(cam_index)]; ok {
      render.camera_resize(
        &engine.gctx,
        cam,
        &engine.render.texture_manager,
        vk.Extent2D{world_camera.extent[0], world_camera.extent[1]},
        engine.swapchain.format.format,
        vk.Format.D32_SFLOAT,
      ) or_return
      render.camera_allocate_descriptors(&engine.render, &engine.gctx, cam) or_return
    }
  }
  render.resize(
    &engine.render,
    &engine.gctx,
    engine.swapchain.extent,
    engine.swapchain.format.format,
    get_window_dpi(engine.window),
  ) or_return
  return .SUCCESS
}

render_and_present :: proc(self: ^Engine) -> vk.Result {
  gpu.acquire_next_image(
    self.gctx.device,
    &self.swapchain,
    self.frame_index,
  ) or_return
  active_camera_indices := make(
    [dynamic]u32,
    0,
    len(self.world.cameras.entries),
    context.temp_allocator,
  )
  defer delete(active_camera_indices)
  for &entry, cam_index in self.world.cameras.entries {
    if !entry.active do continue
    append(&active_camera_indices, u32(cam_index))
  }
  populate_debug_ui(self)
  mu.end(&self.render.debug_ui.ctx)
  render.record_frame(
    &self.render,
    &self.gctx,
    self.frame_index,
    self.swapchain.images[self.swapchain.image_index],
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
    self.world.main_camera.index,
    active_camera_indices[:],
    self.debug_ui_enabled,
  ) or_return
  graphics_cmd := self.render.internal.command_buffers[self.frame_index]
  compute_cmd := self.render.internal.compute_command_buffers[self.frame_index]
  gpu.submit_queue_and_present(
    &self.gctx,
    &self.swapchain,
    &graphics_cmd,
    &compute_cmd,
    self.frame_index,
  ) or_return
  self.frame_index = alg.next(self.frame_index, FRAMES_IN_FLIGHT)
  self.last_render_timestamp = time.now()
  return .SUCCESS
}

// One-stop entry point. Allocates the engine, installs a console logger,
// runs to window close, and tears down. Example:
//
//   main :: proc() {
//     mjolnir.run_app({ title = "Cube", setup = setup })
//   }
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

run_app :: proc(cfg: RunConfig) {
  context.logger = log.create_console_logger()
  engine := new(Engine)
  defer free(engine)
  engine.setup_proc        = cfg.setup
  engine.update_proc       = cfg.update
  engine.pre_render_proc   = cfg.pre_render
  engine.post_render_proc  = cfg.post_render
  engine.key_press_proc    = cfg.key_press
  engine.mouse_press_proc  = cfg.mouse_press
  engine.mouse_move_proc   = cfg.mouse_move
  engine.mouse_scroll_proc = cfg.mouse_scroll
  engine.mouse_drag_proc   = cfg.mouse_drag
  engine.user_data         = cfg.user_data
  engine.debug_ui_enabled  = cfg.debug_ui
  w := cfg.width  if cfg.width  != 0 else 800
  h := cfg.height if cfg.height != 0 else 600
  run(engine, w, h, cfg.title)
}

run :: proc(self: ^Engine, width, height: u32, title: string) {
  if init(self, width, height, title) != .SUCCESS {
    return
  }
  defer shutdown(self)
  when USE_PARALLEL_UPDATE {
    self.update_active = true
    update_thread := thread.create(update_thread_proc)
    update_thread.data = self
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
    debug_pre_frame(self)
    world.begin_frame(&self.world, 0.016, nil)
    mu.begin(&self.render.debug_ui.ctx)
    sync_staging_to_gpu(self)
    {
      n := u32(len(self.world.nodes.entries))
      for ; n > 0; n -= 1 do if self.world.nodes.entries[n - 1].active do break
      render.set_node_count(&self.render, n)
    }
    sync_ui_to_renderer(self)
    if self.pre_render_proc != nil {
      self.pre_render_proc(self)
    }
    context.user_ptr = self
    res := render_and_present(self)
    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
      recreate_swapchain(self) or_continue
    }
    if self.post_render_proc != nil {
      self.post_render_proc(self)
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
  engine := cast(^Engine)thread.data
  for engine.update_active {
    if !update(engine) do time.sleep(time.Millisecond * 2)
  }
  log.info("Update thread terminating")
}
