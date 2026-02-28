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
import rd "render/data"
import rg "render/graph"
import "render/debug_ui"
import occlusion_culling "render/occlusion_culling"
import ui_module "ui"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"
import "world"

// Verify world and GPU handle types have identical memory layout for safe transmutes
#assert(size_of(world.MeshHandle) == size_of(gpu.MeshHandle))
#assert(size_of(world.Image2DHandle) == size_of(gpu.Texture2DHandle))
#assert(size_of(world.ImageCubeHandle) == size_of(gpu.TextureCubeHandle))

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
  nav.init(&self.nav)
  self.camera_controller_enabled = true
  self.start_timestamp = time.now()
  self.last_frame_timestamp = self.start_timestamp
  self.last_update_timestamp = self.start_timestamp
  world.init(&self.world)
  gpu.swapchain_init(&self.swapchain, &self.gctx, self.window) or_return
  // Initialize UI system (logical, before renderer)
  ui_module.init(&self.ui)
  render.init(
    &self.render,
    &self.gctx,
    self.swapchain.extent,
    self.swapchain.format.format,
    get_window_dpi(self.window),
  ) or_return

  // NOTE: Frame graph compilation is deferred until after cameras are registered
  // It will be compiled on first render_and_present() call if use_frame_graph is enabled

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
      {
        .SHADOW,
        .GEOMETRY,
        .LIGHTING,
        .TRANSPARENCY,
        .PARTICLES,
        .POST_PROCESS,
      },
      {3, 4, 3},
      {0, 0, 0},
      math.PI * 0.5,
      0.1,
      100.0,
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
    pixel_data: []u8,
  ) -> (
    handle: world.Image2DHandle,
    ok: bool,
  ) {
    engine_ctx := cast(^Engine)context.user_ptr
    if engine_ctx == nil {
      return {}, false
    }
    out_handle, ret := gpu.create_texture_2d_from_data(
      &engine_ctx.gctx,
      &engine_ctx.render.texture_manager,
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

update_visibility_node_count :: proc(
  render: ^render.Manager,
  world: ^world.World,
) {
  n := min(u32(len(world.nodes.entries)), render.visibility.max_draws)
  for ; n > 0; n -= 1 do if world.nodes.entries[n - 1].active do break
  render.visibility.node_count = n
  render.depth_pyramid.node_count = n
  render.shadow_culling.node_count = n
  render.shadow_sphere_culling.node_count = n
}

sync_staging_to_gpu :: proc(self: ^Engine) -> vk.Result {
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
  for handle, entry in self.world.staging.node_data {
    if entry.op == .Remove {
      node_data := render.Node {
        material_id           = 0xFFFFFFFF,
        mesh_id               = 0xFFFFFFFF,
        attachment_data_index = 0xFFFFFFFF,
      }
      render.upload_node_data(&self.render, handle.index, &node_data)
      append(&stale_handles, handle)
      continue
    }
    defer {
      self.world.staging.node_data[handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_handles, handle)
    }
    node_data := render.Node {
      material_id           = 0xFFFFFFFF,
      mesh_id               = 0xFFFFFFFF,
      attachment_data_index = 0xFFFFFFFF,
    }
    defer render.upload_node_data(&self.render, handle.index, &node_data)
    node := cont.get(self.world.nodes, handle) or_continue
    node_data.world_matrix = node.transform.world_matrix
    // When a staged node is not found (nil), it means the node was despawned.
    // Trigger cleanup in Render module by releasing GPU resources.
    // This eliminates the need for a separate pending removal list in World module.
    #partial switch attachment in node.attachment {
    case world.MeshAttachment:
      if skinning, has_skin := attachment.skinning.?; has_skin {
        node_data.attachment_data_index =
          render.ensure_bone_matrix_range_for_node(
            &self.render,
            handle.index,
            u32(len(skinning.matrices)),
          )
      }
      node_data.material_id = attachment.material.index
      node_data.mesh_id = attachment.handle.index
      if node.visible && node.parent_visible do node_data.flags |= {.VISIBLE}
      if node.culling_enabled do node_data.flags |= {.CULLING_ENABLED}
      if attachment.cast_shadow do node_data.flags |= {.CASTS_SHADOW}
      if material, has_mat := cont.get(
        self.world.materials,
        attachment.material,
      ); has_mat {
        switch material.type {
        case .TRANSPARENT:
          node_data.flags |= {.MATERIAL_TRANSPARENT}
        case .WIREFRAME:
          node_data.flags |= {.MATERIAL_WIREFRAME}
        case .RANDOM_COLOR:
          node_data.flags |= {.MATERIAL_RANDOM_COLOR}
        case .LINE_STRIP:
          node_data.flags |= {.MATERIAL_LINE_STRIP}
        case .PBR, .UNLIT:
        }
      }
    case world.SpriteAttachment:
      node_data.material_id = attachment.material.index
      node_data.mesh_id = attachment.mesh_handle.index
      node_data.attachment_data_index = attachment.sprite_handle.index
      if node.visible && node.parent_visible do node_data.flags |= {.VISIBLE}
      if node.culling_enabled do node_data.flags |= {.CULLING_ENABLED}
      node_data.flags |= {.MATERIAL_SPRITE}
      if material, has_mat := cont.get(
        self.world.materials,
        attachment.material,
      ); has_mat {
        switch material.type {
        case .TRANSPARENT:
          node_data.flags |= {.MATERIAL_TRANSPARENT}
        case .WIREFRAME:
          node_data.flags |= {.MATERIAL_WIREFRAME}
        case .RANDOM_COLOR:
          node_data.flags |= {.MATERIAL_RANDOM_COLOR}
        case .LINE_STRIP:
          node_data.flags |= {.MATERIAL_LINE_STRIP}
        case .PBR, .UNLIT:
        }
      }
    }
  }
  for handle in stale_handles {
    delete_key(&self.world.staging.node_data, handle)
    render.release_bone_matrix_range_for_node(&self.render, handle.index)
  }
  for handle, entry in self.world.staging.mesh_updates {
    new_age := entry.age + 1
    self.world.staging.mesh_updates[handle] = {new_age, entry.op}
    if new_age >= world.FRAMES_IN_FLIGHT {
      append(&stale_meshes, handle)
      continue
    }
    if entry.op == .Update {
      if mesh := cont.get(self.world.meshes, handle); mesh != nil {
        if geom, has_geom := mesh.cpu_geometry.?; has_geom {
          render.sync_mesh_geometry_for_handle(
            &self.gctx,
            &self.render,
            handle.index,
            geom,
          )
        }
      }
    }
  }
  for handle in stale_meshes {
    entry := self.world.staging.mesh_updates[handle]
    if entry.op == .Remove {
      render.clear_mesh(&self.render, handle.index)
    } else if mesh := cont.get(self.world.meshes, handle); mesh != nil {
      if mesh.auto_purge_cpu_geometry {
        world.mesh_release_memory(mesh)
      }
    }
    delete_key(&self.world.staging.mesh_updates, handle)
  }
  for handle, entry in self.world.staging.material_updates {
    if entry.op == .Remove {
      append(&stale_materials, handle)
      continue
    }
    defer {
      self.world.staging.material_updates[handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_materials, handle)
    }
    material := cont.get(self.world.materials, handle) or_continue
    render.upload_material_data(
      &self.render,
      handle.index,
      &render.Material {
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
  for handle in stale_materials {
    delete_key(&self.world.staging.material_updates, handle)
  }
  for handle, entry in self.world.staging.bone_updates {
    if entry.op == .Remove {
      append(&stale_bone_nodes, handle)
      continue
    }
    defer {
      self.world.staging.bone_updates[handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_bone_nodes, handle)
    }
    node := cont.get(self.world.nodes, handle) or_continue
    mesh_attachment, has_mesh := node.attachment.(world.MeshAttachment)
    if !has_mesh do continue
    skinning, has_skinning := mesh_attachment.skinning.?
    if !has_skinning do continue
    bone_count := u32(len(skinning.matrices))
    if bone_count <= 0 do continue
    offset := render.ensure_bone_matrix_range_for_node(
      &self.render,
      handle.index,
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
  for handle in stale_bone_nodes {
    delete_key(&self.world.staging.bone_updates, handle)
  }
  for handle, entry in self.world.staging.sprite_updates {
    if entry.op == .Remove {
      append(&stale_sprites, handle)
      continue
    }
    defer {
      self.world.staging.sprite_updates[handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_sprites, handle)
    }
    sprite := cont.get(self.world.sprites, handle) or_continue
    sprite_anim, has_anim := sprite.animation.?
    render.upload_sprite_data(
      &self.render,
      handle.index,
      &render.Sprite {
        texture_index = sprite.texture.index,
        frame_columns = sprite.frame_columns,
        frame_rows = sprite.frame_rows,
        frame_index = sprite_anim.current_frame if has_anim else 0,
      },
    )
  }
  for handle in stale_sprites {
    delete_key(&self.world.staging.sprite_updates, handle)
  }
  for handle, entry in self.world.staging.emitter_updates {
    if entry.op == .Remove {
      append(&stale_emitters, handle)
      continue
    }
    defer {
      self.world.staging.emitter_updates[handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_emitters, handle)
    }
    emitter := cont.get(self.world.emitters, handle) or_continue
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
  for handle in stale_emitters {
    delete_key(&self.world.staging.emitter_updates, handle)
  }
  for handle, entry in self.world.staging.forcefield_updates {
    if entry.op == .Remove {
      append(&stale_forcefields, handle)
      continue
    }
    defer {
      self.world.staging.forcefield_updates[handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_forcefields, handle)
    }
    forcefield := cont.get(self.world.forcefields, handle) or_continue
    render.upload_forcefield_data(
      &self.render,
      handle.index,
      &render.ForceField {
        tangent_strength = forcefield.tangent_strength,
        strength = forcefield.strength,
        area_of_effect = forcefield.area_of_effect,
        node_index = forcefield.node_handle.index,
      },
    )
  }
  for handle in stale_forcefields {
    delete_key(&self.world.staging.forcefield_updates, handle)
  }
  for node_handle, entry in self.world.staging.light_updates {
    if entry.op == .Remove {
      render.remove_light_entry(&self.render, &self.gctx, node_handle.index)
      append(&stale_lights, node_handle)
      continue
    }
    defer {
      self.world.staging.light_updates[node_handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_lights, node_handle)
    }
    node, ok := cont.get(self.world.nodes, node_handle)
    if !ok {
      render.remove_light_entry(&self.render, &self.gctx, node_handle.index)
      continue
    }
    light_position := node.transform.world_matrix[3].xyz
    light_direction := node.transform.world_matrix[2].xyz
    if linalg.dot(light_direction, light_direction) < 1e-6 {
      light_direction = {0, -1, 0}
    } else {
      light_direction = linalg.normalize(light_direction)
    }
    light_data: render.Light
    has_light := true
    #partial switch attachment in node.attachment {
    case world.PointLightAttachment:
      light_variant := render.PointLight {
        color    = attachment.color,
        position = light_position,
        radius   = attachment.radius,
        shadow   = nil, // Shadow managed by render layer
      }
      light_data = render.Light(light_variant)
    case world.DirectionalLightAttachment:
      light_variant := render.DirectionalLight {
        color     = attachment.color,
        position  = light_position,
        direction = light_direction,
        radius    = attachment.radius,
        shadow    = nil,
      }
      light_data = render.Light(light_variant)
    case world.SpotLightAttachment:
      light_variant := render.SpotLight {
        color       = attachment.color,
        position    = light_position,
        direction   = light_direction,
        radius      = attachment.radius,
        angle_inner = attachment.angle_inner,
        angle_outer = attachment.angle_outer,
        shadow      = nil,
      }
      light_data = render.Light(light_variant)
    case:
      has_light = false
    }
    if has_light {
      // Determine cast_shadow flag from attachment
      cast_shadow := false
      #partial switch att in node.attachment {
      case world.PointLightAttachment:
        cast_shadow = att.cast_shadow
      case world.DirectionalLightAttachment:
        cast_shadow = att.cast_shadow
      case world.SpotLightAttachment:
        cast_shadow = att.cast_shadow
      }
      render.upsert_light_entry(
        &self.render,
        &self.gctx,
        node_handle.index,
        &light_data,
        cast_shadow,
      ) or_return
    } else {
      render.remove_light_entry(&self.render, &self.gctx, node_handle.index)
    }
  }
  for node_handle in stale_lights {
    delete_key(&self.world.staging.light_updates, node_handle)
  }
  for handle, entry in self.world.staging.camera_updates {
    if entry.op == .Remove {
      append(&stale_cameras, handle)
      continue
    }
    defer {
      self.world.staging.camera_updates[handle] = {entry.age + 1, .Update}
      if entry.age + 1 >= world.FRAMES_IN_FLIGHT do append(&stale_cameras, handle)
    }
    world_camera := cont.get(self.world.cameras, handle) or_continue
    is_new_camera := handle.index not_in self.render.per_camera_data
    if is_new_camera {
      self.render.per_camera_data[handle.index] = {}
    }
    // Sync camera configuration
    cam := &self.render.per_camera_data[handle.index]
    cam.enabled_passes =
    transmute(render.PassTypeSet)world_camera.enabled_passes
    cam.enable_culling = world_camera.enable_culling
    // Upload camera transform data to GPU buffer
    view_matrix := world.camera_view_matrix(world_camera)
    projection_matrix := world.camera_projection_matrix(world_camera)
    near, far := world.camera_get_near_far(world_camera)
    render.upload_camera_data(
      &self.render,
      handle.index,
      view_matrix,
      projection_matrix,
      world_camera.position,
      world_camera.extent,
      near,
      far,
      self.frame_index,
    )
    // Initialize GPU resources for new cameras
    if is_new_camera {
      render.camera_init(
        &self.gctx,
        cam,
        &self.render.texture_manager,
        vk.Extent2D{world_camera.extent[0], world_camera.extent[1]},
        self.swapchain.format.format,
        vk.Format.D32_SFLOAT,
        cam.enabled_passes,
        rd.MAX_NODES_IN_SCENE,
      ) or_return
      render.camera_allocate_descriptors(
        &self.gctx,
        cam,
        &self.render.texture_manager,
        &self.render.visibility.depth_descriptor_layout,
        &self.render.depth_pyramid.depth_reduce_descriptor_layout,
        &self.render.node_data_buffer,
        &self.render.mesh_data_buffer,
        &self.render.camera_buffer,
      ) or_return
    }
  }
  for handle in stale_cameras {
    delete_key(&self.world.staging.camera_updates, handle)
  }
  // Collect and stage bone visualization data for debug rendering (compile-time controlled)
  when render.DEBUG_SHOW_BONES {
    palette := render.DEBUG_BONE_PALETTE
    bone_vis := world.collect_bone_visualization_data(
      &self.world,
      palette[:],
      render.DEBUG_BONE_SCALE,
      context.temp_allocator,
    )
    defer delete(bone_vis)
    // Convert to render.BoneInstance format
    bone_instances := make(
      [dynamic]render.BoneInstance,
      len(bone_vis),
      context.temp_allocator,
    )
    for instance, i in bone_vis {
      bone_instances[i] = render.BoneInstance {
        position = instance.position,
        color    = instance.color,
        scale    = instance.scale,
      }
    }
    render.stage_bone_visualization(&self.render, bone_instances[:])
  } else {
    render.clear_debug_visualization(&self.render)
  }
  return .SUCCESS
}

// Sync UI render commands to the renderer (staging list pattern)
sync_ui_to_renderer :: proc(self: ^Engine) {
  // Update font atlas if dirty
  ui_module.update_font_atlas(
    &self.ui,
    &self.gctx,
    &self.render.texture_manager,
  )
  // Compute layout before generating commands
  ui_module.compute_layout_all(&self.ui)
  // Generate render commands from widgets
  ui_module.generate_render_commands(&self.ui)
  // Stage commands to renderer
  render.stage_ui_commands(&self.render, self.ui.staging[:])
}

update :: proc(self: ^Engine) -> bool {
  context.user_ptr = self
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  self.last_update_timestamp = time.now()
  params := gpu.get(&self.render.particles_compute.params_buffer, 0)
  params.delta_time = delta_time
  params.emitter_count = u32(
    min(len(self.world.emitters.entries), world.MAX_EMITTERS),
  )
  params.forcefield_count = u32(
    min(len(self.world.forcefields.entries), world.MAX_FORCE_FIELDS),
  )
  if self.camera_controller_enabled && self.world.active_controller != nil {
    main_camera := get_main_camera(self)
    if main_camera != nil {
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
  world.update_node_animations(&self.world, delta_time)
  world.update_skeletal_animations(&self.world, delta_time)
  world.update_sprite_animations(&self.world, delta_time)
  self.last_update_timestamp = time.now()
  return true
}

shutdown :: proc(self: ^Engine) {
  teardown(self)
  render.shutdown(&self.render, &self.gctx)
  ui_module.shutdown(&self.ui)
  world.shutdown(&self.world)
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
      render_camera := &self.render.per_camera_data[self.world.main_camera.index]
      main_stats := occlusion_culling.stats(
        &self.render.visibility,
        &render_camera.opaque_draw_count[self.frame_index],
        self.world.main_camera.index,
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
    if cam, ok := &engine.render.per_camera_data[u32(cam_index)]; ok {
      render.camera_resize(
        &engine.gctx,
        cam,
        &engine.render.texture_manager,
        vk.Extent2D{world_camera.extent[0], world_camera.extent[1]},
        engine.swapchain.format.format,
        vk.Format.D32_SFLOAT,
        transmute(render.PassTypeSet)world_camera.enabled_passes,
      ) or_return
      render.camera_allocate_descriptors(
        &engine.gctx,
        cam,
        &engine.render.texture_manager,
        &engine.render.visibility.depth_descriptor_layout,
        &engine.render.depth_pyramid.depth_reduce_descriptor_layout,
        &engine.render.node_data_buffer,
        &engine.render.mesh_data_buffer,
        &engine.render.camera_buffer,
      ) or_return
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
  command_buffer := self.render.command_buffers[self.frame_index]
  gpu.begin_record(command_buffer) or_return

  // Always use frame graph
  render_with_frame_graph(self, command_buffer) or_return

  gpu.end_record(command_buffer) or_return

  // Frame graph doesn't support async compute yet
  // Submit only graphics command buffer (compute commands are recorded there too)
  // Pass nil for compute to prevent submitting unrecorded compute buffer
  if self.gctx.has_async_compute {
    // Temporarily disable async compute for frame graph
    old_has_async := self.gctx.has_async_compute
    self.gctx.has_async_compute = false
    gpu.submit_queue_and_present(
      &self.gctx,
      &self.swapchain,
      &command_buffer,
      &command_buffer,  // Use graphics cmd for both
      self.frame_index,
    ) or_return
    self.gctx.has_async_compute = old_has_async
  } else {
    gpu.submit_queue_and_present(
      &self.gctx,
      &self.swapchain,
      &command_buffer,
      &command_buffer,
      self.frame_index,
    ) or_return
  }
  self.frame_index = alg.next(self.frame_index, FRAMES_IN_FLIGHT)
  self.last_render_timestamp = time.now()
  return .SUCCESS
}

// Frame graph rendering path
render_with_frame_graph :: proc(self: ^Engine, command_buffer: vk.CommandBuffer) -> vk.Result {
  // Check if graph needs (re)compilation
  need_compile := false

  if self.render.frame_graph.sorted_passes == nil {
    log.info("Compiling frame graph on first use...")
    need_compile = true
  } else {
    // Check if topology changed (cameras/lights added/removed)
    if len(self.render.frame_graph.camera_handles) != len(self.render.per_camera_data) ||
       len(self.render.frame_graph.light_handles) != len(self.render.per_light_data) {
      log.info("Frame graph topology changed, recompiling...")
      need_compile = true
    }
  }

  if need_compile {
    if render.compile_frame_graph(&self.render, &self.gctx) != .SUCCESS {
      log.error("Frame graph compilation failed!")
      return .ERROR_UNKNOWN
    }
  }

  // Set swapchain context for passes that need it
  self.render.current_swapchain_image = self.swapchain.images[self.swapchain.image_index]
  self.render.current_swapchain_view = self.swapchain.views[self.swapchain.image_index]
  self.render.current_swapchain_extent = self.swapchain.extent

  // Assign light indices and compute shadow matrices before any GPU work.
  // The graph's shadow_culling/shadow_render passes depend on these being set.
  render.prepare_lights_for_frame(&self.render)

  // Execute frame graph
  rg.run_graph(&self.render.frame_graph, self.frame_index, command_buffer)

  // Transition swapchain image to present layout
  present_barrier := vk.ImageMemoryBarrier{
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

  return .SUCCESS
}

// Legacy rendering path (original implementation)
render_with_legacy_path :: proc(self: ^Engine, command_buffer: vk.CommandBuffer) -> vk.Result {
  render.render_shadow_depth(&self.render, self.frame_index) or_return
  for &entry, cam_index in self.world.cameras.entries {
    if !entry.active do continue
    world_cam := &entry.item
    render_cam := &self.render.per_camera_data[u32(cam_index)]
    if world.PassType.GEOMETRY in world_cam.enabled_passes {
      render.record_geometry_pass(
        &self.render,
        self.frame_index,
        u32(cam_index),
        render_cam,
      )
    }
    if world.PassType.LIGHTING in world_cam.enabled_passes {
      render.record_lighting_pass(
        &self.render,
        self.frame_index,
        u32(cam_index),
        render_cam,
      )
    }
    if world.PassType.PARTICLES in world_cam.enabled_passes {
      render.record_particles_pass(
        &self.render,
        self.frame_index,
        u32(cam_index),
        render_cam,
      )
    }
    if world.PassType.TRANSPARENCY in world_cam.enabled_passes {
      render.record_transparency_pass(
        &self.render,
        self.frame_index,
        &self.gctx,
        u32(cam_index),
        render_cam,
      )
    }
  }
  main_render_cam := &self.render.per_camera_data[self.world.main_camera.index]
  // Debug rendering pass (bones, etc.) - renders after transparency
  render.record_debug_pass(
    &self.render,
    self.frame_index,
    self.world.main_camera.index,
    main_render_cam,
  )
  render.record_post_process_pass(
    &self.render,
    self.frame_index,
    main_render_cam,
    self.swapchain.extent,
    self.swapchain.images[self.swapchain.image_index],
    self.swapchain.views[self.swapchain.image_index],
  )
  render.record_ui_pass(
    &self.render,
    self.frame_index,
    &self.gctx,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
  )
  compute_cmd_buffer: vk.CommandBuffer
  if self.gctx.has_async_compute {
    compute_cmd_buffer = self.render.compute_command_buffers[self.frame_index]
    gpu.begin_record(compute_cmd_buffer) or_return
  } else {
    compute_cmd_buffer = command_buffer
  }
  render.record_compute_commands(
    &self.render,
    self.frame_index,
    &self.gctx,
  ) or_return
  if self.gctx.has_async_compute {
    gpu.end_record(compute_cmd_buffer) or_return
  }
  populate_debug_ui(self)
  mu.end(&self.render.debug_ui.ctx)
  if self.debug_ui_enabled {
    debug_ui.begin_pass(
      &self.render.debug_ui,
      command_buffer,
      self.swapchain.views[self.swapchain.image_index],
      self.swapchain.extent,
    )
    debug_ui.render(
      &self.render.debug_ui,
      command_buffer,
      self.render.texture_manager.descriptor_set,
    )
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
  return .SUCCESS
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
    world.begin_frame(&self.world, 0.016, nil)
    mu.begin(&self.render.debug_ui.ctx)
    sync_staging_to_gpu(self)
    update_visibility_node_count(&self.render, &self.world)
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
    should_update := update(engine)
    if !should_update {
      time.sleep(time.Millisecond * 2)
    }
  }
  log.info("Update thread terminating")
}
