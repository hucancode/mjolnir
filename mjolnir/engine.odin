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
import "geometry"
import "gpu"
import nav "navigation"
import "render"
import render_camera "render/camera"
import "render/debug_draw"
import "render/debug_ui"
import "render/particles"
import "render/ui"
import "render/visibility"
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
    self.swapchain.extent,
    self.swapchain.format.format,
    get_window_dpi(self.window),
  ) or_return

  main_world_handle, main_world_camera, ok_main_camera := cont.alloc(
    &self.world.cameras,
    world.CameraHandle,
  )
  if !ok_main_camera do return .ERROR_INITIALIZATION_FAILED
  if main_world_handle.index != self.render.main_camera.index ||
     main_world_handle.generation != self.render.main_camera.generation {
    return .ERROR_INITIALIZATION_FAILED
  }
  world.camera_init(
    main_world_camera,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    {
      .SHADOW,
      .GEOMETRY,
      .LIGHTING,
      .TRANSPARENCY,
      .PARTICLES,
      .DEBUG_DRAW,
      .POST_PROCESS,
    },
    {3, 4, 3},
    {0, 0, 0},
    math.PI * 0.5,
    0.1,
    100.0,
  ) or_return
  world.stage_camera_data(&self.world.staging, main_world_handle)

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
      geom,
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
    mesh_handle: world.MeshHandle,
    transform: matrix[4, 4]f32,
    duration_seconds: f64,
    color: [4]f32,
    bypass_depth: bool,
  ) {
    engine := cast(^Engine)context.user_ptr
    if engine == nil do return
    debug_draw.spawn_mesh_temporary(
      &engine.render.debug_draw,
      transmute(render.MeshHandle)mesh_handle,
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

load_gltf :: proc(
  engine: ^Engine,
  path: string,
) -> (
  nodes: [dynamic]world.NodeHandle,
  ok: bool,
) #optional_ok {
  create_texture_from_data_adapter := proc(
    world_ptr: ^world.World,
    pixel_data: []u8,
  ) -> (
    handle: world.Image2DHandle,
    ok: bool,
  ) {
    _ = world_ptr
    engine_ctx := cast(^Engine)context.user_ptr
    if engine_ctx == nil {
      return {}, false
    }
    out_handle, ret := render.create_texture_from_data(
      &engine_ctx.gctx,
      &engine_ctx.render,
      pixel_data,
    )
    if ret != .SUCCESS {
      return {}, false
    }
    return transmute(world.Image2DHandle)out_handle, true
  }
  old_user_ptr := context.user_ptr
  context.user_ptr = engine
  defer context.user_ptr = old_user_ptr
  handles, result := world.load_gltf(
    &engine.world,
    create_texture_from_data_adapter,
    path,
  )
  return handles, result == .success
}

@(private = "file")
get_main_camera :: proc(self: ^Engine) -> ^world.Camera {
  return cont.get(
    self.world.cameras,
    transmute(world.CameraHandle)self.render.main_camera,
  )
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
  render.shadow.node_count = n
}

sync_staging_to_gpu :: proc(self: ^Engine) {
  sync.mutex_lock(&self.world.staging.mutex)
  defer sync.mutex_unlock(&self.world.staging.mutex)
  stale_handles := make([dynamic]world.NodeHandle, context.temp_allocator)
  stale_meshes := make([dynamic]world.MeshHandle, context.temp_allocator)
  stale_materials := make(
    [dynamic]world.MaterialHandle,
    context.temp_allocator,
  )
  stale_bone_nodes := make([dynamic]world.NodeHandle, context.temp_allocator)
  stale_sprites := make([dynamic]world.SpriteHandle, context.temp_allocator)
  stale_emitters := make([dynamic]world.EmitterHandle, context.temp_allocator)
  stale_forcefields := make(
    [dynamic]world.ForceFieldHandle,
    context.temp_allocator,
  )
  stale_lights := make([dynamic]world.NodeHandle, context.temp_allocator)
  stale_cameras := make([dynamic]world.CameraHandle, context.temp_allocator)
  for handle, n in self.world.staging.transforms {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if node := cont.get(self.world.nodes, handle); node != nil {
        render.upload_node_transform(
          &self.render,
          transmute(render.NodeHandle)handle,
          &node.transform.world_matrix,
        )
      } else {
        zero_matrix: matrix[4, 4]f32
        render.upload_node_transform(
          &self.render,
          transmute(render.NodeHandle)handle,
          &zero_matrix,
        )
      }
      next_n += 1
      self.world.staging.transforms[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_handles, handle)
    }
  }
  for handle in stale_handles {
    delete_key(&self.world.staging.transforms, handle)
  }
  clear(&stale_handles)
  for handle, n in self.world.staging.node_data {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      node_data := render.Node {
        material_id           = 0xFFFFFFFF,
        mesh_id               = 0xFFFFFFFF,
        attachment_data_index = 0xFFFFFFFF,
      }
      node := cont.get(self.world.nodes, handle)
      if node == nil {
        render.release_bone_matrix_range_for_node(
          &self.render,
          transmute(render.NodeHandle)handle,
        )
      } else if mesh_attachment, has_mesh := node.attachment.(world.MeshAttachment);
         has_mesh {
        if _, has_skin := mesh_attachment.skinning.?; has_skin {
          if bone_offset, has_offset :=
               self.render.bone_matrix_offsets[transmute(render.NodeHandle)handle];
             has_offset {
            node_data.attachment_data_index = bone_offset
          } else if skinning, has_skinning := mesh_attachment.skinning.?;
             has_skinning && len(skinning.matrices) > 0 {
            bone_offset := render.ensure_bone_matrix_range_for_node(
              &self.render,
              transmute(render.NodeHandle)handle,
              u32(len(skinning.matrices)),
            )
            node_data.attachment_data_index = bone_offset
          } else {
            render.release_bone_matrix_range_for_node(
              &self.render,
              transmute(render.NodeHandle)handle,
            )
            node_data.attachment_data_index = 0xFFFFFFFF
          }
        } else {
          render.release_bone_matrix_range_for_node(
            &self.render,
            transmute(render.NodeHandle)handle,
          )
          node_data.attachment_data_index = 0xFFFFFFFF
        }
        node_data.material_id = mesh_attachment.material.index
        node_data.mesh_id = mesh_attachment.handle.index
        if node.visible && node.parent_visible do node_data.flags |= {.VISIBLE}
        if node.culling_enabled do node_data.flags |= {.CULLING_ENABLED}
        if mesh_attachment.cast_shadow do node_data.flags |= {.CASTS_SHADOW}
        if material, has_mat := cont.get(
          self.world.materials,
          mesh_attachment.material,
        ); has_mat {
          switch material.type {
          case .TRANSPARENT:
            node_data.flags |= {.MATERIAL_TRANSPARENT}
          case .WIREFRAME:
            node_data.flags |= {.MATERIAL_WIREFRAME}
          case .PBR, .UNLIT:
          }
        }
      } else if _, has_sprite := node.attachment.(world.SpriteAttachment);
         has_sprite {
        render.release_bone_matrix_range_for_node(
          &self.render,
          transmute(render.NodeHandle)handle,
        )
        sprite_attachment, _ := node.attachment.(world.SpriteAttachment)
        node_data.material_id = sprite_attachment.material.index
        node_data.mesh_id = sprite_attachment.mesh_handle.index
        node_data.attachment_data_index = sprite_attachment.sprite_handle.index
        if node.visible && node.parent_visible do node_data.flags |= {.VISIBLE}
        if node.culling_enabled do node_data.flags |= {.CULLING_ENABLED}
        node_data.flags |= {.MATERIAL_SPRITE}
        if material, has_mat := cont.get(
          self.world.materials,
          sprite_attachment.material,
        ); has_mat {
          switch material.type {
          case .TRANSPARENT:
            node_data.flags |= {.MATERIAL_TRANSPARENT}
          case .WIREFRAME:
            node_data.flags |= {.MATERIAL_WIREFRAME}
          case .PBR, .UNLIT:
          }
        }
      } else {
        render.release_bone_matrix_range_for_node(
          &self.render,
          transmute(render.NodeHandle)handle,
        )
      }
      render.upload_node_data(
        &self.render,
        transmute(render.NodeHandle)handle,
        &node_data,
      )
      next_n += 1
      self.world.staging.node_data[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_handles, handle)
    }
  }
  for handle in stale_handles {
    delete_key(&self.world.staging.node_data, handle)
  }
  for handle, n in self.world.staging.mesh_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if mesh := cont.get(self.world.meshes, handle); mesh != nil {
        if geom, has_geom := mesh.cpu_geometry.?; has_geom {
          render.sync_mesh_geometry_for_handle(
            &self.gctx,
            &self.render,
            transmute(render.MeshHandle)handle,
            geom,
          )
        }
      } else {
        render.clear_mesh(&self.render, transmute(render.MeshHandle)handle)
      }
      next_n += 1
      self.world.staging.mesh_updates[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_meshes, handle)
    }
  }
  for handle in stale_meshes {
    delete_key(&self.world.staging.mesh_updates, handle)
  }
  for handle, n in self.world.staging.material_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if material := cont.get(self.world.materials, handle); material != nil {
        render.upload_material_data(
          &self.render,
          handle.index,
          &render.Material {
            // type = transmute(render.MaterialType)material.type,
            albedo_index = material.albedo.index,
            metallic_roughness_index = material.metallic_roughness.index,
            normal_index = material.normal.index,
            emissive_index = material.emissive.index,
            features = transmute(render.ShaderFeatureSet)material.features,
            metallic_value = material.metallic_value,
            roughness_value = material.roughness_value,
            emissive_value = material.emissive_value,
            base_color_factor = material.base_color_factor,
          },
        )
      }
      next_n += 1
      self.world.staging.material_updates[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_materials, handle)
    }
  }
  for handle in stale_materials {
    delete_key(&self.world.staging.material_updates, handle)
  }
  for handle, n in self.world.staging.bone_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if node := cont.get(self.world.nodes, handle); node != nil {
        if mesh_attachment, has_mesh := node.attachment.(world.MeshAttachment);
           has_mesh {
          if skinning, has_skinning := mesh_attachment.skinning.?;
             has_skinning {
            bone_count := u32(len(skinning.matrices))
            if bone_count > 0 {
              offset := render.ensure_bone_matrix_range_for_node(
                &self.render,
                transmute(render.NodeHandle)handle,
                bone_count,
              )
              if offset != 0xFFFFFFFF {
                render.upload_bone_matrices(
                  &self.render,
                  self.frame_index,
                  offset,
                  skinning.matrices[:],
                )
              }
            }
          }
        }
      }
      next_n += 1
      self.world.staging.bone_updates[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_bone_nodes, handle)
    }
  }
  for handle in stale_bone_nodes {
    delete_key(&self.world.staging.bone_updates, handle)
  }
  for handle, n in self.world.staging.sprite_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if sprite := cont.get(self.world.sprites, handle); sprite != nil {
        render.upload_sprite_data(
          &self.render,
          handle.index,
          &render.Sprite {
            texture_index = sprite.texture_index,
            frame_columns = sprite.frame_columns,
            frame_rows = sprite.frame_rows,
            frame_index = sprite.frame_index,
          },
        )
      }
      next_n += 1
      self.world.staging.sprite_updates[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_sprites, handle)
    }
  }
  for handle in stale_sprites {
    delete_key(&self.world.staging.sprite_updates, handle)
  }
  for handle, n in self.world.staging.emitter_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if emitter := cont.get(self.world.emitters, handle); emitter != nil {
        render.upload_emitter_data(
          &self.render,
          handle.index,
          &render.Emitter {
            initial_velocity = emitter.initial_velocity,
            size_start = emitter.size_start,
            color_start = emitter.color_start,
            color_end = emitter.color_end,
            aabb_min = emitter.aabb_min,
            emission_rate = emitter.emission_rate,
            aabb_max = emitter.aabb_max,
            particle_lifetime = emitter.particle_lifetime,
            position_spread = emitter.position_spread,
            velocity_spread = emitter.velocity_spread,
            size_end = emitter.size_end,
            weight = emitter.weight,
            weight_spread = emitter.weight_spread,
            texture_index = emitter.texture_handle.index,
            node_index = emitter.node_handle.index,
          },
        )
      }
      next_n += 1
      self.world.staging.emitter_updates[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_emitters, handle)
    }
  }
  for handle in stale_emitters {
    delete_key(&self.world.staging.emitter_updates, handle)
  }
  for handle, n in self.world.staging.forcefield_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if forcefield := cont.get(self.world.forcefields, handle);
         forcefield != nil {
        render.upload_forcefield_data(
          &self.render,
          transmute(render.ForceFieldHandle)handle,
          &render.ForceField {
            tangent_strength = forcefield.tangent_strength,
            strength = forcefield.strength,
            area_of_effect = forcefield.area_of_effect,
            node_index = forcefield.node_handle.index,
          },
        )
      }
      next_n += 1
      self.world.staging.forcefield_updates[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_forcefields, handle)
    }
  }
  for handle in stale_forcefields {
    delete_key(&self.world.staging.forcefield_updates, handle)
  }
  for node_handle, n in self.world.staging.light_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      light_slot, in_active := slice.linear_search(
        self.world.active_light_nodes[:],
        node_handle,
      )
      if in_active {
        node := cont.get(self.world.nodes, node_handle)
        if node != nil {
          light_position := node.transform.world_matrix[3].xyz
          light_direction := node.transform.world_matrix[2].xyz
          if linalg.dot(light_direction, light_direction) < 1e-6 {
            light_direction = {0, -1, 0}
          } else {
            light_direction = linalg.normalize(light_direction)
          }
          render_handle := render.LightHandle {
            index      = u32(light_slot),
            generation = 1,
          }
          light_data: render.Light
          #partial switch attachment in node.attachment {
          case world.PointLightAttachment:
            light_data = render.Light {
              color        = attachment.color,
              position     = {light_position.x, light_position.y, light_position.z, 1.0},
              direction    = {light_direction.x, light_direction.y, light_direction.z, 0.0},
              radius       = attachment.radius,
              angle_inner  = 0.0,
              angle_outer  = 0.0,
              type         = .POINT,
              cast_shadow  = b32(attachment.cast_shadow),
              shadow_index = 0xFFFFFFFF,
            }
          case world.DirectionalLightAttachment:
            light_data = render.Light {
              color        = attachment.color,
              position     = {light_position.x, light_position.y, light_position.z, 1.0},
              direction    = {light_direction.x, light_direction.y, light_direction.z, 0.0},
              radius       = attachment.radius,
              angle_inner  = 0.0,
              angle_outer  = 0.0,
              type         = .DIRECTIONAL,
              cast_shadow  = b32(attachment.cast_shadow),
              shadow_index = 0xFFFFFFFF,
            }
          case world.SpotLightAttachment:
            light_data = render.Light {
              color        = attachment.color,
              position     = {light_position.x, light_position.y, light_position.z, 1.0},
              direction    = {light_direction.x, light_direction.y, light_direction.z, 0.0},
              radius       = attachment.radius,
              angle_inner  = attachment.angle_inner,
              angle_outer  = attachment.angle_outer,
              type         = .SPOT,
              cast_shadow  = b32(attachment.cast_shadow),
              shadow_index = 0xFFFFFFFF,
            }
          case:
            light_data = {}
          }
          render.upload_light_data(&self.render, render_handle.index, &light_data)
        }
      }
      next_n += 1
      self.world.staging.light_updates[node_handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_lights, node_handle)
    }
  }
  for node_handle in stale_lights {
    delete_key(&self.world.staging.light_updates, node_handle)
  }
  for handle, n in self.world.staging.camera_updates {
    next_n := n
    if n < world.FRAMES_IN_FLIGHT {
      if camera := cont.get(self.world.cameras, handle); camera != nil {
        render.sync_camera_from_world(
          &self.render,
          transmute(render.CameraHandle)handle,
          transmute(^render_camera.Camera)camera,
        )
      }
      next_n += 1
      self.world.staging.camera_updates[handle] = next_n
    }
    if next_n >= world.FRAMES_IN_FLIGHT {
      append(&stale_cameras, handle)
    }
  }
  for handle in stale_cameras {
    delete_key(&self.world.staging.camera_updates, handle)
  }
}

update :: proc(self: ^Engine) -> bool {
  context.user_ptr = self
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  self.last_update_timestamp = time.now()
  params := gpu.get(&self.render.particles.params_buffer, 0)
  params.delta_time = delta_time
  params.emitter_count = u32(
    min(len(self.world.emitters.entries), world.MAX_EMITTERS),
  )
  params.forcefield_count = u32(
    min(len(self.world.forcefields.entries), world.MAX_FORCE_FIELDS),
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
      world.stage_camera_data(
        &self.world.staging,
        transmute(world.CameraHandle)self.render.main_camera,
      )
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
      fmt.tprintf("Textures %d", cont.count(self.render.texture_manager.images_2d)),
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
build_active_render_light_handles :: proc(
  engine: ^Engine,
  allocator := context.temp_allocator,
) -> [dynamic]render.LightHandle {
  active_render_lights := make(
    [dynamic]render.LightHandle,
    len(engine.world.active_light_nodes),
    allocator,
  )
  clear(&active_render_lights)
  for _, light_idx in engine.world.active_light_nodes {
    append(
      &active_render_lights,
      render.LightHandle {
        index      = u32(light_idx),
        generation = 1,
      },
    )
  }
  return active_render_lights
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
    world.camera_update_aspect_ratio(main_camera, new_aspect_ratio)
    world.stage_camera_data(
      &engine.world.staging,
      transmute(world.CameraHandle)engine.render.main_camera,
    )
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
      &engine.render.texture_manager,
      engine.swapchain.extent.width,
      engine.swapchain.extent.height,
      engine.swapchain.format.format,
      vk.Format.D32_SFLOAT,
      transmute(render_camera.PassTypeSet)main_camera.enabled_passes,
      main_camera.enable_depth_pyramid,
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
  active_render_lights := build_active_render_light_handles(self)
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
  if self.pre_render_proc != nil {
    self.pre_render_proc(self)
  }
  render.render_shadow_depth(
    &self.render,
    self.frame_index,
    command_buffer,
    active_render_lights[:],
  ) or_return
  render.render_camera_depth(
    &self.render,
    self.frame_index,
    &self.gctx,
    command_buffer,
  ) or_return
  for &entry, cam_index in self.world.cameras.entries {
    if !entry.active do continue
    cam_handle := render.CameraHandle {
      index      = u32(cam_index),
      generation = entry.generation,
    }
    cam := &entry.item
    if world.PassType.GEOMETRY in cam.enabled_passes {
      render.record_geometry_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        cam_handle,
        command_buffer,
      )
    }
    if world.PassType.LIGHTING in cam.enabled_passes {
      render.record_lighting_pass(
        &self.render,
        self.frame_index,
        active_render_lights[:],
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if world.PassType.PARTICLES in cam.enabled_passes {
      render.record_particles_pass(
        &self.render,
        self.frame_index,
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if world.PassType.TRANSPARENCY in cam.enabled_passes {
      render.record_transparency_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        cam_handle,
        self.swapchain.format.format,
        command_buffer,
      )
    }
    if world.PassType.DEBUG_DRAW in cam.enabled_passes {
      render.record_debug_draw_pass(
        &self.render,
        self.frame_index,
        &self.render,
        proc(ctx: rawptr, handle: render.MeshHandle) {
          render_mgr := cast(^render.Manager)ctx
          render.free_mesh_geometry(render_mgr, handle)
        },
        cam_handle,
        command_buffer,
      )
    }
  }
  render.record_post_process_pass(
    &self.render,
    self.frame_index,
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
    compute_cmd_buffer,
  ) or_return
  if self.gctx.has_async_compute {
    gpu.end_record(compute_cmd_buffer) or_return
  }
  populate_debug_ui(self)
  if self.post_render_proc != nil {
    self.post_render_proc(self)
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
  world.process_pending_deletions(&self.world)
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
