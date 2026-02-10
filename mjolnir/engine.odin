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
import d "data"
import "geometry"
import "gpu"
import "level_manager"
import nav "navigation"
import "render"
import render_camera "render/camera"
import "render/debug_draw"
import "render/debug_ui"
import "render/particles"
import "render/visibility"
import "render/ui"
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
    &self.world.materials,
    &self.world.meshes,
    &self.world.cameras,
    &self.world.spherical_cameras,
    &self.world.builtin_meshes,
    self.swapchain.extent,
    self.swapchain.format.format,
    get_window_dpi(self.window),
  ) or_return

  // Set up debug draw callbacks for world module
  self.world.debug_draw_line_strip =
  proc(
    points: []geometry.Vertex,
    duration_seconds: f64,
    color: [4]f32,
    bypass_depth: bool,
  ) {
    engine := cast(^Engine)context.user_ptr
    if engine == nil do return

    // Create mesh from points
    indices := make([]u32, len(points))
    defer delete(indices)
    for i in 0 ..< len(points) {
      indices[i] = u32(i)
    }
    vertices_copy := make([]geometry.Vertex, len(points))
    defer delete(vertices_copy)
    copy(vertices_copy, points)
    geom := geometry.Geometry {
      vertices = vertices_copy,
      indices  = indices,
      aabb     = geometry.aabb_from_vertices(points),
    }

    // Allocate mesh using render upload function
    mesh_handle, result := render.allocate_mesh_geometry(
      &engine.gctx,
      &engine.render,
      &engine.world.meshes,
      geom,
      auto_purge = true,
    )
    if result != .SUCCESS {
      log.warnf("Failed to allocate debug line strip mesh: %v", result)
      return
    }

    // Spawn debug object
    debug_draw.spawn_line_strip_temporary(
      &engine.render.debug_draw,
      mesh_handle,
      duration_seconds,
      color,
      bypass_depth,
    )
  }

  self.world.debug_draw_mesh =
  proc(
    mesh_handle: d.MeshHandle,
    transform: matrix[4, 4]f32,
    duration_seconds: f64,
    color: [4]f32,
    bypass_depth: bool,
  ) {
    engine := cast(^Engine)context.user_ptr
    if engine == nil do return
    debug_draw.spawn_mesh_temporary(
      &engine.render.debug_draw,
      mesh_handle,
      transform,
      duration_seconds,
      color,
      .UNIFORM_COLOR,
      bypass_depth,
    )
  }

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
get_main_camera :: proc(self: ^Engine) -> ^d.Camera {
  return cont.get(self.world.cameras, self.render.main_camera)
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
    mouse_pos := [2]f32 {
      f32(self.input.mouse_pos.x),
      f32(self.input.mouse_pos.y),
    }
    current_widget := ui.pick_widget(&self.render.ui_system, mouse_pos)

    // Handle hover in/out events
    if old_handle, had_old := self.ui_hovered_widget.?; had_old {
      if new_handle, has_new := current_widget.?; has_new {
        // Check if it's a different widget
        old_raw := transmute(cont.Handle)old_handle
        new_raw := transmute(cont.Handle)new_handle
        if old_raw.index != new_raw.index ||
           old_raw.generation != new_raw.generation {
          // Hover out from old widget
          event := ui.MouseEvent {
            type     = .HOVER_OUT,
            position = mouse_pos,
            button   = 0,
            widget   = old_handle,
          }
          ui.dispatch_mouse_event(
            &self.render.ui_system,
            old_handle,
            event,
            true,
          )

          // Hover in to new widget
          event.type = .HOVER_IN
          event.widget = new_handle
          ui.dispatch_mouse_event(
            &self.render.ui_system,
            new_handle,
            event,
            true,
          )
        }
      } else {
        // No widget under cursor, hover out from old
        event := ui.MouseEvent {
          type     = .HOVER_OUT,
          position = mouse_pos,
          button   = 0,
          widget   = old_handle,
        }
        ui.dispatch_mouse_event(
          &self.render.ui_system,
          old_handle,
          event,
          true,
        )
      }
    } else if new_handle, has_new := current_widget.?; has_new {
      // Hover in to new widget (no previous widget)
      event := ui.MouseEvent {
        type     = .HOVER_IN,
        position = mouse_pos,
        button   = 0,
        widget   = new_handle,
      }
      ui.dispatch_mouse_event(&self.render.ui_system, new_handle, event, true)
    }

    // Handle click events
    if widget_handle, has_widget := current_widget.?; has_widget {
      for i in 0 ..< len(self.input.mouse_buttons) {
        if self.input.mouse_buttons[i] && !self.input.mouse_holding[i] {
          // Mouse down
          event := ui.MouseEvent {
            type     = .CLICK_DOWN,
            position = mouse_pos,
            button   = i32(i),
            widget   = widget_handle,
          }
          ui.dispatch_mouse_event(
            &self.render.ui_system,
            widget_handle,
            event,
            true,
          )
        } else if !self.input.mouse_buttons[i] && self.input.mouse_holding[i] {
          // Mouse up
          event := ui.MouseEvent {
            type     = .CLICK_UP,
            position = mouse_pos,
            button   = i32(i),
            widget   = widget_handle,
          }
          ui.dispatch_mouse_event(
            &self.render.ui_system,
            widget_handle,
            event,
            true,
          )
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

sync_staging_to_gpu :: proc(self: ^Engine) {
  sync.mutex_lock(&self.world.staging.mutex)
  defer sync.mutex_unlock(&self.world.staging.mutex)
  stale_handles := make([dynamic]d.NodeHandle, context.temp_allocator)
  stale_meshes := make([dynamic]d.MeshHandle, context.temp_allocator)
  stale_materials := make([dynamic]d.MaterialHandle, context.temp_allocator)
  stale_bone_nodes := make([dynamic]d.NodeHandle, context.temp_allocator)
  stale_sprites := make([dynamic]d.SpriteHandle, context.temp_allocator)
  stale_emitters := make([dynamic]d.EmitterHandle, context.temp_allocator)
  stale_forcefields := make(
    [dynamic]d.ForceFieldHandle,
    context.temp_allocator,
  )
  stale_lights := make([dynamic]d.LightHandle, context.temp_allocator)
  for handle, &entry in self.world.staging.transforms {
    if entry.n < d.FRAMES_IN_FLIGHT {
      render.upload_node_transform(&self.render, handle, &entry.data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_handles, handle)
    }
  }
  for handle in stale_handles {
    delete_key(&self.world.staging.transforms, handle)
  }
  clear(&stale_handles)
  for handle, &entry in self.world.staging.node_data {
    node_data := entry.data
    if entry.n < d.FRAMES_IN_FLIGHT {
      node := cont.get(self.world.nodes, handle)
      if node == nil {
        render.release_bone_matrix_range_for_node(&self.render, handle)
        node_data.attachment_data_index = 0xFFFFFFFF
      } else if mesh_attachment, has_mesh := node.attachment.(world.MeshAttachment);
         has_mesh {
        if _, has_skin := mesh_attachment.skinning.?; has_skin {
          if bone_offset, has_offset :=
               self.render.bone_matrix_offsets[handle]; has_offset {
            node_data.attachment_data_index = bone_offset
          } else if bone_entry, has_bones :=
               self.world.staging.bone_updates[handle];
             has_bones && len(bone_entry.data) > 0 {
            bone_offset := render.ensure_bone_matrix_range_for_node(
              &self.render,
              handle,
              u32(len(bone_entry.data)),
            )
            node_data.attachment_data_index = bone_offset
          } else {
            render.release_bone_matrix_range_for_node(&self.render, handle)
            node_data.attachment_data_index = 0xFFFFFFFF
          }
        } else {
          render.release_bone_matrix_range_for_node(&self.render, handle)
          node_data.attachment_data_index = 0xFFFFFFFF
        }
      } else if _, has_sprite := node.attachment.(world.SpriteAttachment);
         has_sprite {
        render.release_bone_matrix_range_for_node(&self.render, handle)
        // attachment_data_index already set to sprite_handle.index by staging
      } else {
        render.release_bone_matrix_range_for_node(&self.render, handle)
        node_data.attachment_data_index = 0xFFFFFFFF
      }
      render.upload_node_data(&self.render, handle, &node_data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_handles, handle)
    }
  }
  for handle in stale_handles {
    delete_key(&self.world.staging.node_data, handle)
  }
  for handle, &entry in self.world.staging.mesh_updates {
    if entry.n < d.FRAMES_IN_FLIGHT {
      render.upload_mesh_data_raw(&self.render, handle, &entry.data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_meshes, handle)
    }
  }
  for handle in stale_meshes {
    delete_key(&self.world.staging.mesh_updates, handle)
  }
  for handle, &entry in self.world.staging.material_updates {
    if entry.n < d.FRAMES_IN_FLIGHT {
      render.upload_material_data_raw(&self.render, handle, &entry.data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_materials, handle)
    }
  }
  for handle in stale_materials {
    delete_key(&self.world.staging.material_updates, handle)
  }
  for handle, &entry in self.world.staging.bone_updates {
    if entry.n < d.FRAMES_IN_FLIGHT {
      bone_count := u32(len(entry.data))
      if bone_count > 0 {
        offset := render.ensure_bone_matrix_range_for_node(
          &self.render,
          handle,
          bone_count,
        )
        if offset != 0xFFFFFFFF {
          render.upload_bone_matrices(
            &self.render,
            self.frame_index,
            offset,
            entry.data[:],
          )
        }
      }
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_bone_nodes, handle)
    }
  }
  for handle in stale_bone_nodes {
    if entry, ok := self.world.staging.bone_updates[handle]; ok {
      delete(entry.data)
    }
    delete_key(&self.world.staging.bone_updates, handle)
  }
  for handle, &entry in self.world.staging.sprite_updates {
    if entry.n < d.FRAMES_IN_FLIGHT {
      render.upload_sprite_data(&self.render, handle, &entry.data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_sprites, handle)
    }
  }
  for handle in stale_sprites {
    delete_key(&self.world.staging.sprite_updates, handle)
  }
  for handle, &entry in self.world.staging.emitter_updates {
    if entry.n < d.FRAMES_IN_FLIGHT {
      render.upload_emitter_data(&self.render, handle, &entry.data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_emitters, handle)
    }
  }
  for handle in stale_emitters {
    delete_key(&self.world.staging.emitter_updates, handle)
  }
  for handle, &entry in self.world.staging.forcefield_updates {
    if entry.n < d.FRAMES_IN_FLIGHT {
      render.upload_forcefield_data(&self.render, handle, &entry.data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_forcefields, handle)
    }
  }
  for handle in stale_forcefields {
    delete_key(&self.world.staging.forcefield_updates, handle)
  }
  for handle, &entry in self.world.staging.light_updates {
    if entry.n < d.FRAMES_IN_FLIGHT {
      render.upload_light_data(&self.render, handle, &entry.data)
      entry.n += 1
    }
    if entry.n >= d.FRAMES_IN_FLIGHT {
      append(&stale_lights, handle)
    }
  }
  for handle in stale_lights {
    delete_key(&self.world.staging.light_updates, handle)
  }
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
    min(len(self.world.emitters.entries), d.MAX_EMITTERS),
  )
  params.forcefield_count = u32(
    min(len(self.world.forcefields.entries), d.MAX_FORCE_FIELDS),
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
  world.update_node_animations(&self.world, delta_time)
  world.update_skeletal_animations(
    &self.world,
    delta_time,
    self.render.debug_draw_ik,
    &self.render.debug_draw,
  )
  world.update_sprite_animations(&self.world, delta_time)
  self.last_update_timestamp = time.now()
  return true
}

shutdown :: proc(self: ^Engine) {
  vk.DeviceWaitIdle(self.gctx.device)
  level_manager.shutdown(&self.level_manager)
  gpu.free_command_buffer(&self.gctx, ..self.command_buffers[:])
  if self.gctx.has_async_compute {
    gpu.free_compute_command_buffer(
      &self.gctx,
      self.compute_command_buffers[:],
    )
  }
  render.shutdown(&self.render, &self.gctx)
  world.shutdown(&self.world)
  nav.shutdown(&self.nav_sys)
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
      fmt.tprintf("Textures %d", render.active_texture_2d_count(&self.render)),
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
      main_camera_gpu := &self.render.cameras_gpu[self.render.main_camera.index]
      main_stats := visibility.stats(
        &self.render.visibility,
        main_camera_gpu,
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
  light_handle: d.LightHandle,
) -> (
  camera_handle: d.CameraHandle,
  ok: bool,
) #optional_ok {
  light := cont.get(engine.world.lights, light_handle) or_return
  // Only create cameras for lights that cast shadows
  if !light.cast_shadow do return {}, false
  #partial switch light.type {
  case .POINT:
    // Point lights use spherical cameras for omnidirectional shadows
    cam_handle, spherical_cam := cont.alloc(
      &engine.world.spherical_cameras,
      d.SphereCameraHandle,
    ) or_return
    // Initialize CPU data
    init_ok := world.spherical_camera_init(
      spherical_cam,
      d.SHADOW_MAP_SIZE,
      radius = light.radius,
      near = 0.1,
      far = light.radius,
    )
    if !init_ok {
      cont.free(&engine.world.spherical_cameras, cam_handle)
      return {}, false
    }
    // Initialize GPU resources
    cam_gpu := &engine.render.spherical_cameras_gpu[cam_handle.index]
    gpu_result := render_camera.init_spherical_gpu(
      &engine.gctx,
      cam_gpu,
      &engine.render.texture_manager,
      d.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      d.MAX_NODES_IN_SCENE,
    )
    if gpu_result != .SUCCESS {
      cont.free(&engine.world.spherical_cameras, cam_handle)
      return {}, false
    }
    // Allocate descriptors for the spherical camera
    alloc_result := render_camera.allocate_descriptors_spherical(
      &engine.gctx,
      cam_gpu,
      &engine.render.visibility.sphere_cam_descriptor_layout,
      &engine.render.node_data_buffer,
      &engine.render.mesh_data_buffer,
      &engine.render.world_matrix_buffer,
      &engine.render.spherical_camera_buffer,
    )
    if alloc_result != .SUCCESS {
      cont.free(&engine.world.spherical_cameras, cam_handle)
      return {}, false
    }
    // Update the light to reference this camera
    light.camera_handle = cam_handle
    light.camera_index = cam_handle.index
    render.upload_light_data(&engine.render, light_handle, &light.data)
    return cam_handle, true
  case .DIRECTIONAL:
    cam_handle, cam := cont.alloc(
      &engine.world.cameras,
      d.CameraHandle,
    ) or_return
    ortho_size := light.radius * 2.0
    init_ok := world.camera_init_orthographic(
      cam,
      d.SHADOW_MAP_SIZE,
      d.SHADOW_MAP_SIZE,
      {.SHADOW},
      {0, 0, 0},
      {0, 0, -1},
      ortho_size,
      ortho_size,
      1.0,
      light.radius * 2.0,
    )
    if !init_ok {
      cont.free(&engine.world.cameras, cam_handle)
      return {}, false
    }
    cam_gpu := &engine.render.cameras_gpu[cam_handle.index]
    descriptor_set := engine.render.textures_descriptor_set
    set_descriptor :: proc(
      gctx: ^gpu.GPUContext,
      index: u32,
      view: vk.ImageView,
    ) {
      desc_set := (cast(^vk.DescriptorSet)context.user_ptr)^
      render.set_texture_2d_descriptor(gctx, desc_set, index, view)
    }
    context.user_ptr = &descriptor_set
    gpu_result := render_camera.init_orthographic_gpu(
      &engine.gctx,
      cam_gpu,
      cam,
      &engine.render.texture_manager,
      d.SHADOW_MAP_SIZE,
      d.SHADOW_MAP_SIZE,
      engine.swapchain.format.format,
      vk.Format.D32_SFLOAT,
      cam.enabled_passes,
      d.MAX_NODES_IN_SCENE,
    )
    if gpu_result != .SUCCESS {
      cont.free(&engine.world.cameras, cam_handle)
      return {}, false
    }
    alloc_result := render_camera.allocate_descriptors(
      &engine.gctx,
      cam_gpu,
      &engine.render.texture_manager,
      &engine.render.visibility.normal_cam_descriptor_layout,
      &engine.render.visibility.depth_reduce_descriptor_layout,
      &engine.render.node_data_buffer,
      &engine.render.mesh_data_buffer,
      &engine.render.world_matrix_buffer,
      &engine.render.camera_buffer,
    )
    if alloc_result != .SUCCESS {
      cont.free(&engine.world.cameras, cam_handle)
      return {}, false
    }
    light.camera_handle = cam_handle
    light.camera_index = cam_handle.index
    render.upload_light_data(&engine.render, light_handle, &light.data)
    return cam_handle, true
  case .SPOT:
    cam_handle, cam := cont.alloc(
      &engine.world.cameras,
      d.CameraHandle,
    ) or_return
    fov := light.angle_outer * 2.0
    init_ok := world.camera_init(
      cam,
      d.SHADOW_MAP_SIZE,
      d.SHADOW_MAP_SIZE,
      {.SHADOW},
      {0, 0, 0},
      {0, -1, 0},
      fov,
      light.radius * 0.01,
      light.radius,
    )
    if !init_ok {
      cont.free(&engine.world.cameras, cam_handle)
      return {}, false
    }
    cam_gpu := &engine.render.cameras_gpu[cam_handle.index]
    descriptor_set := engine.render.textures_descriptor_set
    set_descriptor :: proc(
      gctx: ^gpu.GPUContext,
      index: u32,
      view: vk.ImageView,
    ) {
      desc_set := (cast(^vk.DescriptorSet)context.user_ptr)^
      render.set_texture_2d_descriptor(gctx, desc_set, index, view)
    }
    context.user_ptr = &descriptor_set
    gpu_result := render_camera.init_gpu(
      &engine.gctx,
      cam_gpu,
      cam,
      &engine.render.texture_manager,
      d.SHADOW_MAP_SIZE,
      d.SHADOW_MAP_SIZE,
      engine.swapchain.format.format,
      vk.Format.D32_SFLOAT,
      cam.enabled_passes,
      d.MAX_NODES_IN_SCENE,
    )
    if gpu_result != .SUCCESS {
      cont.free(&engine.world.cameras, cam_handle)
      return {}, false
    }
    alloc_result := render_camera.allocate_descriptors(
      &engine.gctx,
      cam_gpu,
      &engine.render.texture_manager,
      &engine.render.visibility.normal_cam_descriptor_layout,
      &engine.render.visibility.depth_reduce_descriptor_layout,
      &engine.render.node_data_buffer,
      &engine.render.mesh_data_buffer,
      &engine.render.world_matrix_buffer,
      &engine.render.camera_buffer,
    )
    if alloc_result != .SUCCESS {
      cont.free(&engine.world.cameras, cam_handle)
      return {}, false
    }
    light.camera_handle = cam_handle
    light.camera_index = cam_handle.index
    render.upload_light_data(&engine.render, light_handle, &light.data)
    return cam_handle, true
  }
  return {}, false
}

@(private)
ensure_light_cameras :: proc(engine: ^Engine) {
  for light_handle in engine.world.active_lights {
    light := cont.get(engine.world.lights, light_handle) or_continue
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
    d.camera_update_aspect_ratio(main_camera, new_aspect_ratio)
    descriptor_set := engine.render.textures_descriptor_set
    set_descriptor :: proc(
      gctx: ^gpu.GPUContext,
      index: u32,
      view: vk.ImageView,
    ) {
      desc_set := (cast(^vk.DescriptorSet)context.user_ptr)^
      render.set_texture_2d_descriptor(gctx, desc_set, index, view)
    }
    context.user_ptr = &descriptor_set
    camera_gpu := &engine.render.cameras_gpu[engine.render.main_camera.index]
    render_camera.resize_gpu(
      &engine.gctx,
      camera_gpu,
      main_camera,
      &engine.render.texture_manager,
      engine.swapchain.extent.width,
      engine.swapchain.extent.height,
      engine.swapchain.format.format,
      vk.Format.D32_SFLOAT,
    ) or_return
    render_camera.allocate_descriptors(
      &engine.gctx,
      camera_gpu,
      &engine.render.texture_manager,
      &engine.render.visibility.normal_cam_descriptor_layout,
      &engine.render.visibility.depth_reduce_descriptor_layout,
      &engine.render.node_data_buffer,
      &engine.render.mesh_data_buffer,
      &engine.render.world_matrix_buffer,
      &engine.render.camera_buffer,
    ) or_return
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
  world.begin_frame(&self.world, 0.016, nil)
  sync_staging_to_gpu(self)
  update_visibility_node_count(&self.render, &self.world)
  render.update_light_camera(
    &self.render,
    self.world.cameras,
    self.world.spherical_cameras,
    self.world.lights,
    self.world.active_lights[:],
    self.render.main_camera,
    self.frame_index,
  )
  if self.pre_render_proc != nil {
    self.pre_render_proc(self)
  }
  render.render_camera_depth(
    &self.render,
    self.frame_index,
    &self.gctx,
    &self.world.cameras,
    &self.world.spherical_cameras,
    command_buffer,
  ) or_return
  for &entry, cam_index in self.world.cameras.entries {
    if !entry.active do continue
    cam_handle := CameraHandle {
      index      = u32(cam_index),
      generation = entry.generation,
    }
    cam := &entry.item
    if d.PassType.GEOMETRY in cam.enabled_passes {
      render.record_geometry_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        self.world.cameras,
        cam_handle,
        command_buffer,
      )
    }
    if d.PassType.LIGHTING in cam.enabled_passes {
      render.record_lighting_pass(
        &self.render,
        self.frame_index,
        self.world.cameras,
        self.world.meshes,
        self.world.lights,
        self.world.active_lights[:],
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if d.PassType.PARTICLES in cam.enabled_passes {
      render.record_particles_pass(
        &self.render,
        self.frame_index,
        self.world.cameras,
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if d.PassType.TRANSPARENCY in cam.enabled_passes {
      render.record_transparency_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        self.world.cameras,
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if d.PassType.DEBUG_DRAW in cam.enabled_passes {
      render.record_debug_draw_pass(
        &self.render,
        self.frame_index,
        self.world.cameras,
        self.world.meshes,
        &self.world.meshes,
        proc(ctx: rawptr, handle: d.MeshHandle) {
          mesh_pool := cast(^d.Pool(d.Mesh))ctx
          render.free_mesh_geometry(mesh_pool, handle)
        },
        cam_handle,
        command_buffer,
      )
    }
  }
  render.record_post_process_pass(
    &self.render,
    self.frame_index,
    self.world.cameras,
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
    &self.world.cameras,
    &self.world.spherical_cameras,
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
  render.process_retired_gpu_resources(&self.render, &self.gctx)
  if world.process_pending_deletions(&self.world) {
    world.purge_unused_resources(&self.world)
    render.purge_unused_gpu_resources(&self.render, &self.gctx)
  }
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
