package mjolnir

import "animation"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "gpu"
import "render/debug_ui"
import "render/particles"
import "render/retained_ui"
import "resources"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"
import "world"

MAX_FRAMES_IN_FLIGHT :: 2
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
USE_PARALLEL_UPDATE :: true

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
  window:                 glfw.WindowHandle,
  gctx:                   gpu.GPUContext,
  rm:                     resources.Manager,
  frame_index:            u32,
  swapchain:              gpu.Swapchain,
  world:                  world.World,
  last_frame_timestamp:   time.Time,
  last_update_timestamp:  time.Time,
  start_timestamp:        time.Time,
  input:                  InputState,
  setup_proc:             SetupProc,
  update_proc:            UpdateProc,
  key_press_proc:         KeyInputProc,
  mouse_press_proc:       MousePressProc,
  mouse_drag_proc:        MouseDragProc,
  mouse_move_proc:        MouseMoveProc,
  mouse_scroll_proc:      MouseScrollProc,
  pre_render_proc:        PreRenderProc,
  post_render_proc:       PostRenderProc,
  render_error_count:     u32,
  render:                 Renderer,
  command_buffers:        [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  cursor_pos:             [2]i32,
  debug_ui_enabled:       bool,
  pending_node_deletions: [dynamic]resources.Handle,
  update_thread:          Maybe(^thread.Thread),
  update_active:          bool,
  last_render_timestamp:  time.Time,
}

get_window_dpi :: proc(window: glfw.WindowHandle) -> f32 {
  sw, sh := glfw.GetWindowContentScale(window)
  if sw != sh {
    log.warnf("DPI scale x (%v) and y (%v) not the same, using x", sw, sh)
  }
  return sw
}

init :: proc(self: ^Engine, width, height: u32, title: string) -> vk.Result {
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
  self.start_timestamp = time.now()
  self.last_frame_timestamp = self.start_timestamp
  self.last_update_timestamp = self.start_timestamp
  world.init(&self.world)
  gpu.swapchain_init(&self.swapchain, &self.gctx, self.window) or_return
  world.init_gpu(
    &self.world,
    &self.gctx,
    &self.rm,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  self.pending_node_deletions = make([dynamic]resources.Handle, 0)
  vk.AllocateCommandBuffers(
    self.gctx.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = self.gctx.command_pool,
      level = .PRIMARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.command_buffers[:]),
  ) or_return
  renderer_init(
    &self.render,
    &self.gctx,
    &self.rm,
    self.swapchain.extent,
    self.swapchain.format.format,
    get_window_dpi(self.window),
  ) or_return
  glfw.SetKeyCallback(
    self.window,
    proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      retained_ui.input_key(&engine.render.retained_ui, int(key), int(action))
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
        mu.input_key_down(&engine.render.ui.ctx, mu_key)
      case glfw.RELEASE:
        mu.input_key_up(&engine.render.ui.ctx, mu_key)
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
        mu.input_mouse_down(&engine.render.ui.ctx, x, y, mu_btn)
      case glfw.RELEASE:
        mu.input_mouse_up(&engine.render.ui.ctx, x, y, mu_btn)
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
        &engine.render.ui.ctx,
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
        &engine.render.ui.ctx,
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
      mu.input_text(&engine.render.ui.ctx, text_str)
      retained_ui.input_text(&engine.render.retained_ui, text_str)
    },
  )
  if self.setup_proc != nil {
    self.setup_proc(self)
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

get_main_camera :: proc(self: ^Engine) -> ^resources.Camera {
  return resources.get(self.rm.cameras, self.render.main_camera)
}

get_retained_ui :: proc(self: ^Engine) -> ^retained_ui.Manager {
  return &self.render.retained_ui
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
  for k in 0 ..< len(self.input.keys) {
    is_pressed := glfw.GetKey(self.window, c.int(k)) == glfw.PRESS
    self.input.key_holding[k] = is_pressed && self.input.keys[k]
    self.input.keys[k] = is_pressed
  }
  if self.mouse_move_proc != nil {
    self.mouse_move_proc(self, self.input.mouse_pos, delta)
  }
  return true
}

update :: proc(self: ^Engine) -> bool {
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  params := gpu.mutable_buffer_get(&self.render.particles.params_buffer, 0)
  params.delta_time = delta_time
  params.emitter_count = u32(
    min(len(self.rm.emitters.entries), resources.MAX_EMITTERS),
  )
  params.forcefield_count = u32(
    min(len(self.rm.forcefields.entries), resources.MAX_FORCE_FIELDS),
  )
  retained_ui.update_input(
    &self.render.retained_ui,
    f32(self.input.mouse_pos.x),
    f32(self.input.mouse_pos.y),
    self.input.mouse_holding[0],
  )
  retained_ui.update(&self.render.retained_ui, self.frame_index)
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
  }
  // Update skeletal animations after user update so IK targets are current
  world.update_skeletal_animations(&self.world, &self.rm, delta_time)
  world.update_sprite_animations(&self.rm, delta_time)
  self.last_update_timestamp = time.now()
  return true
}

shutdown :: proc(self: ^Engine) {
  vk.DeviceWaitIdle(self.gctx.device)
  gpu.free_command_buffers(
    self.gctx.device,
    self.gctx.command_pool,
    self.command_buffers[:],
  )
  delete(self.pending_node_deletions)
  renderer_shutdown(
    &self.render,
    self.gctx.device,
    self.gctx.command_pool,
    &self.rm,
  )
  world.shutdown(&self.world, &self.gctx, &self.rm)
  resources.shutdown(&self.rm, &self.gctx)
  gpu.swapchain_destroy(&self.swapchain, self.gctx.device)
  gpu.shutdown(&self.gctx)
  glfw.DestroyWindow(self.window)
  glfw.Terminate()
  log.infof("Engine deinitialized")
}

@(private = "file")
render_debug_ui :: proc(self: ^Engine) {
  if mu.window(
    &self.render.ui.ctx,
    "Engine",
    {40, 40, 350, 280},
    {.NO_CLOSE},
  ) {
    mu.label(
      &self.render.ui.ctx,
      fmt.tprintf(
        "Objects %d",
        len(self.world.nodes.entries) - len(self.world.nodes.free_indices),
      ),
    )
    mu.label(
      &self.render.ui.ctx,
      fmt.tprintf(
        "Textures %d",
        len(self.rm.image_2d_buffers.entries) -
        len(self.rm.image_2d_buffers.free_indices),
      ),
    )
    mu.label(
      &self.render.ui.ctx,
      fmt.tprintf(
        "Materials %d",
        len(self.rm.materials.entries) - len(self.rm.materials.free_indices),
      ),
    )
    mu.label(
      &self.render.ui.ctx,
      fmt.tprintf(
        "Meshes %d",
        len(self.rm.meshes.entries) - len(self.rm.meshes.free_indices),
      ),
    )
    if main_camera := get_main_camera(self); main_camera != nil {
      main_stats := world.visibility_system_get_stats(
        &self.world.visibility,
        main_camera,
        self.render.main_camera.index,
        self.frame_index,
      )
      mu.label(
        &self.render.ui.ctx,
        fmt.tprintf("Total Objects: %d", self.world.visibility.node_count),
      )
      mu.label(
        &self.render.ui.ctx,
        fmt.tprintf("Draw count: %d draws", main_stats.late_draw_count),
      )
    }
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
  resize(
    &engine.render,
    &engine.gctx,
    &engine.rm,
    engine.swapchain.extent,
    engine.swapchain.format.format,
    get_window_dpi(engine.window),
  ) or_return
  return .SUCCESS
}

render :: proc(self: ^Engine) -> vk.Result {
  gpu.acquire_next_image(
    self.gctx.device,
    &self.swapchain,
    self.frame_index,
  ) or_return
  mu.begin(&self.render.ui.ctx)
  command_buffer := self.command_buffers[self.frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  render_delta_time := f32(
    time.duration_seconds(time.since(self.last_render_timestamp)),
  )
  world.begin_frame(&self.world, &self.rm)
  main_camera_handle := self.render.main_camera
  main_camera := resources.get(self.rm.cameras, main_camera_handle)
  if main_camera == nil do return .ERROR_UNKNOWN
  for &entry, cam_index in self.rm.cameras.entries {
    if !entry.active do continue
    resources.camera_upload_data(&self.rm, &entry.item, u32(cam_index))
  }
  resources.update_light_shadow_camera_transforms(&self.rm, self.frame_index)
  if self.pre_render_proc != nil {
    self.pre_render_proc(self)
  }
  record_camera_visibility(
    &self.render,
    self.frame_index,
    &self.gctx,
    &self.rm,
    &self.world,
    command_buffer,
  ) or_return
  for &entry, cam_index in self.rm.cameras.entries {
    if !entry.active do continue
    if u32(cam_index) == main_camera_handle.index do continue
    cam_handle := resources.Handle {
      index      = u32(cam_index),
      generation = entry.generation,
    }
    cam := &entry.item
    if resources.PassType.GEOMETRY in cam.enabled_passes {
      record_geometry_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        &self.rm,
        &self.world,
        cam_handle,
      )
    }
    if resources.PassType.LIGHTING in cam.enabled_passes {
      record_lighting_pass(
        &self.render,
        self.frame_index,
        &self.rm,
        cam_handle,
        self.swapchain.format.format,
      )
    }
    if resources.PassType.PARTICLES in cam.enabled_passes {
      record_particles_pass(
        &self.render,
        self.frame_index,
        &self.rm,
        cam_handle,
        self.swapchain.format.format,
      )
    }
    if resources.PassType.TRANSPARENCY in cam.enabled_passes {
      record_transparency_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        &self.rm,
        &self.world,
        cam_handle,
        self.swapchain.format.format,
      )
    }
    portal_buffers := [dynamic]vk.CommandBuffer{}
    defer delete(portal_buffers)
    if resources.PassType.GEOMETRY in cam.enabled_passes {
      append(&portal_buffers, cam.geometry_commands[self.frame_index])
    }
    if resources.PassType.LIGHTING in cam.enabled_passes {
      append(&portal_buffers, cam.lighting_commands[self.frame_index])
    }
    if resources.PassType.PARTICLES in cam.enabled_passes {
      append(&portal_buffers, self.render.particles.commands[self.frame_index])
    }
    if resources.PassType.TRANSPARENCY in cam.enabled_passes {
      append(&portal_buffers, cam.transparency_commands[self.frame_index])
    }
    if len(portal_buffers) > 0 {
      vk.CmdExecuteCommands(
        command_buffer,
        u32(len(portal_buffers)),
        raw_data(portal_buffers[:]),
      )
    }
  }
  if self.post_render_proc != nil {
    self.post_render_proc(self)
  }
  record_geometry_pass(
    &self.render,
    self.frame_index,
    &self.gctx,
    &self.rm,
    &self.world,
    main_camera_handle,
  )
  record_lighting_pass(
    &self.render,
    self.frame_index,
    &self.rm,
    main_camera_handle,
    self.swapchain.format.format,
  )
  record_particles_pass(
    &self.render,
    self.frame_index,
    &self.rm,
    main_camera_handle,
    self.swapchain.format.format,
  )
  record_transparency_pass(
    &self.render,
    self.frame_index,
    &self.gctx,
    &self.rm,
    &self.world,
    main_camera_handle,
    self.swapchain.format.format,
  )
  record_post_process_pass(
    &self.render,
    self.frame_index,
    &self.rm,
    main_camera_handle,
    self.swapchain.format.format,
    self.swapchain.extent,
    self.swapchain.images[self.swapchain.image_index],
    self.swapchain.views[self.swapchain.image_index],
  )
  particles.simulate(
    &self.render.particles,
    command_buffer,
    self.rm.world_matrix_descriptor_set,
    &self.rm,
  )
  buffers := [?]vk.CommandBuffer {
    main_camera.geometry_commands[self.frame_index],
    main_camera.lighting_commands[self.frame_index],
    self.render.particles.commands[self.frame_index],
    main_camera.transparency_commands[self.frame_index],
    self.render.post_process.commands[self.frame_index],
  }
  vk.CmdExecuteCommands(command_buffer, len(buffers), raw_data(buffers[:]))
  render_debug_ui(self)
  mu.end(&self.render.ui.ctx)
  if self.debug_ui_enabled {
    debug_ui.begin_pass(
      &self.render.ui,
      command_buffer,
      self.swapchain.views[self.swapchain.image_index],
      self.swapchain.extent,
    )
    debug_ui.render(&self.render.ui, command_buffer)
    debug_ui.end_pass(&self.render.ui, command_buffer)
  }
  retained_ui.begin_pass(
    &self.render.retained_ui,
    command_buffer,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
  )
  retained_ui.render(
    &self.render.retained_ui,
    command_buffer,
    self.frame_index,
    &self.rm,
    &self.gctx,
  )
  retained_ui.end_pass(command_buffer)
  gpu.transition_image_to_present(
    command_buffer,
    self.swapchain.images[self.swapchain.image_index],
  )
  vk.EndCommandBuffer(command_buffer) or_return
  gpu.submit_queue_and_present(
    &self.gctx,
    &self.swapchain,
    &command_buffer,
    self.frame_index,
  ) or_return
  self.frame_index = (self.frame_index + 1) % MAX_FRAMES_IN_FLIGHT
  process_pending_deletions(self)
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
  for !glfw.WindowShouldClose(self.window) {
    update_input(self)
    when !USE_PARALLEL_UPDATE {
      update(self)
    }
    if time.duration_milliseconds(time.since(self.last_frame_timestamp)) <
       FRAME_TIME_MILIS {
      continue
    }
    res := render(self)
    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
      recreate_swapchain(self) or_continue
    }
    if res != .SUCCESS {
      log.errorf("Error during rendering %v", res)
      self.render_error_count += 1
      if self.render_error_count >=
         MAX_CONSECUTIVE_RENDER_ERROR_COUNT_ALLOWED {
        log.errorf("Too many render errors, exiting...")
        break
      }
    } else {
      self.render_error_count = 0
    }
    self.last_frame_timestamp = time.now()
    frame += 1
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

queue_node_deletion :: proc(engine: ^Engine, handle: resources.Handle) {
  append(&engine.pending_node_deletions, handle)
}

process_pending_deletions :: proc(engine: ^Engine) {
  for handle in engine.pending_node_deletions {
    world.despawn(&engine.world, handle)
  }
  clear(&engine.pending_node_deletions)
  world.cleanup_pending_deletions(&engine.world, &engine.rm, &engine.gctx)
}
