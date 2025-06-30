package mjolnir

import "animation"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "geometry"
import "resource"
import glfw "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

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

Handle :: resource.Handle

g_context: runtime.Context
g_frame_index: u32 = 0

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
Render2DProc :: #type proc(engine: ^Engine, ctx: ^mu.Context)
KeyInputProc :: #type proc(engine: ^Engine, key, action, mods: int)
MousePressProc :: #type proc(engine: ^Engine, key, action, mods: int)
MouseDragProc :: #type proc(engine: ^Engine, delta, offset: linalg.Vector2f64)
MouseScrollProc :: #type proc(engine: ^Engine, offset: linalg.Vector2f64)
MouseMoveProc :: #type proc(engine: ^Engine, pos, delta: linalg.Vector2f64)

// Batch key for grouping objects by material features
BatchKey :: struct {
  features:      ShaderFeatureSet,
  material_type: MaterialType,
}

// Batch data containing material and nodes
BatchData :: struct {
  material_handle: Handle,
  nodes:           [dynamic]^Node,
}

BatchingContext :: struct {
  engine:  ^Engine,
  frustum: geometry.Frustum,
  lights:  [dynamic]SingleLightUniform,
  batches: map[BatchKey][dynamic]BatchData,
}


InputState :: struct {
  mouse_pos:         linalg.Vector2f64,
  mouse_drag_origin: linalg.Vector2f32,
  mouse_buttons:     [8]bool,
  mouse_holding:     [8]bool,
  key_holding:       [512]bool,
  keys:              [512]bool,
}

LightKind :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

VisibleLightInfo :: struct {
  index_in_scene:  int,
  kind:            LightKind,
  color:           linalg.Vector3f32,
  radius:          f32,
  angle:           f32,
  has_shadow:      bool,
  position:        linalg.Vector4f32,
  direction:       linalg.Vector4f32,
  view:            linalg.Matrix4f32,
  projection:      linalg.Matrix4f32,
  shadow_map:      ^ImageBuffer,
  cube_shadow_map: ^CubeImageBuffer,
}

Engine :: struct {
  window:                glfw.WindowHandle,
  swapchain:             Swapchain,
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
  main:                  RendererMain,
  shadow:                RendererShadow,
  particle:              RendererParticle,
  postprocess:           RendererPostProcess,
  gbuffer:               RendererGBuffer,
  depth_prepass:         RendererDepthPrepass,
  command_buffers:       [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  visible_lights:        [MAX_FRAMES_IN_FLIGHT][dynamic]VisibleLightInfo,
  node_idx_to_light_idx: [MAX_FRAMES_IN_FLIGHT]map[int]int,
  cursor_pos:            [2]i32,
}

get_window_dpi :: proc(window: glfw.WindowHandle) -> f32 {
  sw, sh := glfw.GetWindowContentScale(window)
  // Use X scale, warn if not equal
  if sw != sh {
    log.warnf("DPI scale x (%v) and y (%v) not the same, using x", sw, sh)
  }
  return sw
}

init :: proc(
  self: ^Engine,
  width: u32,
  height: u32,
  title: string,
) -> vk.Result {
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
  self.window = glfw.CreateWindow(
    c.int(width),
    c.int(height),
    strings.clone_to_cstring(title),
    nil,
    nil,
  )
  if self.window == nil {
    log.errorf("Failed to create GLFW window")
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof("Window created %v\n", self.window)
  vulkan_context_init(self.window) or_return
  factory_init()
  self.start_timestamp = time.now()
  self.last_frame_timestamp = self.start_timestamp
  self.last_update_timestamp = self.start_timestamp
  scene_init(&self.scene)
  swapchain_init(&self.swapchain, self.window) or_return
  vk.AllocateCommandBuffers(
    g_device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = g_command_pool,
      level = .PRIMARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.command_buffers[:]),
  ) or_return
  renderer_main_init(
    &self.main,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
    .D32_SFLOAT,
  ) or_return
  renderer_gbuffer_init(
    &self.gbuffer,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  renderer_depth_prepass_init(
    &self.depth_prepass,
    self.swapchain.extent,
  ) or_return
  renderer_particle_init(&self.particle) or_return
  renderer_shadow_init(&self.shadow, .D32_SFLOAT) or_return
  renderer_postprocess_init(
    &self.postprocess,
    self.swapchain.format.format,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  renderer_ui_init(
    &self.ui,
    self,
    self.swapchain.format.format,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    get_window_dpi(self.window),
  )
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
        mu.input_key_down(&engine.ui.ctx, mu_key)
      case glfw.RELEASE:
        mu.input_key_up(&engine.ui.ctx, mu_key)
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
        mu.input_mouse_down(&engine.ui.ctx, x, y, mu_btn)
      case glfw.RELEASE:
        mu.input_mouse_up(&engine.ui.ctx, x, y, mu_btn)
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
        &engine.ui.ctx,
        engine.cursor_pos.x,
        engine.cursor_pos.y,
      )
      if engine.mouse_move_proc != nil {
        engine.mouse_move_proc(engine, {xpos, ypos}, {0, 0}) // You may want to pass delta
      }
    },
  )

  glfw.SetScrollCallback(
    self.window,
    proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      mu.input_scroll(
        &engine.ui.ctx,
        -i32(math.round(xoffset)),
        -i32(math.round(yoffset)),
      )
      geometry.camera_orbit_zoom(
        &engine.scene.camera,
        -f32(yoffset) * SCROLL_SENSITIVITY,
      )
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
      mu.input_text(&engine.ui.ctx, string(bytes[:size]))
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

time_since_app_start :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.start_timestamp)))
}

update :: proc(self: ^Engine) -> bool {
  glfw.PollEvents()
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  scene_traverse(&self.scene)
  for &entry in self.scene.nodes.entries {
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
    mesh := resource.get(g_meshes, data.handle) or_continue
    mesh_skin, mesh_has_skin := mesh.skinning.?
    if !mesh_has_skin {
      continue
    }
    l, r :=
      skinning.bone_matrix_offset +
      g_frame_index * g_bone_matrix_slab.capacity,
      skinning.bone_matrix_offset +
      g_frame_index * g_bone_matrix_slab.capacity +
      u32(len(mesh_skin.bones))
    bone_matrices := g_bindless_bone_buffer.mapped[l:r]
    sample_clip(mesh, anim_inst.clip_handle, anim_inst.time, bone_matrices)
  }
  update_emitters(self, delta_time)
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
  if self.input.mouse_holding[glfw.MOUSE_BUTTON_1] {
    geometry.camera_orbit_rotate(
      &self.scene.camera,
      f32(delta.x * MOUSE_SENSITIVITY_X),
      f32(delta.y * MOUSE_SENSITIVITY_Y),
    )
  }
  if self.mouse_move_proc != nil {
    self.mouse_move_proc(self, self.input.mouse_pos, delta)
  }
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
  }
  self.last_update_timestamp = time.now()
  return true
}

deinit :: proc(self: ^Engine) {
  vk.DeviceWaitIdle(g_device)
  vk.FreeCommandBuffers(
    g_device,
    g_command_pool,
    len(self.command_buffers),
    raw_data(self.command_buffers[:]),
  )
  renderer_ui_deinit(&self.ui)
  scene_deinit(&self.scene)
  renderer_main_deinit(&self.main)
  renderer_gbuffer_deinit(&self.gbuffer)
  renderer_shadow_deinit(&self.shadow)
  renderer_postprocess_deinit(&self.postprocess)
  renderer_particle_deinit(&self.particle)
  renderer_depth_prepass_deinit(&self.depth_prepass)
  swapchain_deinit(&self.swapchain)
  vulkan_context_deinit()
  glfw.DestroyWindow(self.window)
  glfw.Terminate()
  log.infof("Engine deinitialized")
}

recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  // vk.DeviceWaitIdle(g_device)
  swapchain_recreate(&engine.swapchain, engine.window) or_return
  new_aspect_ratio :=
    f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
  geometry.camera_update_aspect_ratio(&engine.scene.camera, new_aspect_ratio)
  renderer_recreate_images(
    &engine.main,
    engine.swapchain.format.format,
    engine.swapchain.extent,
  ) or_return
  renderer_depth_prepass_recreate_images(
    &engine.depth_prepass,
    engine.swapchain.extent,
  ) or_return
  renderer_gbuffer_recreate_images(
    &engine.gbuffer,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
  ) or_return
  renderer_postprocess_recreate_images(
    &engine.postprocess,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
  ) or_return
  return .SUCCESS
}

update_visible_lights :: proc(self: ^Engine) {
  visible_lights := &self.visible_lights[g_frame_index]
  node_idx_to_light_idx := &self.node_idx_to_light_idx[g_frame_index]
  seen: [MAX_LIGHTS]bool
  // Traverse scene and update/add visible lights
  for entry, i in self.scene.nodes.entries do if entry.active {
    node := entry.item
    light_info: VisibleLightInfo
    #partial switch light in node.attachment {
    case PointLightAttachment:
      position := node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      light_info = {
        index_in_scene = i,
        kind           = .POINT,
        color          = light.color.xyz,
        radius         = light.radius,
        has_shadow     = light.cast_shadow,
        position       = position,
        projection     = linalg.matrix4_perspective(math.PI * 0.5, 1.0, 0.01, light.radius),
        // point light needs 6 view matrices, it will not be calculated here
      }
    case DirectionalLightAttachment:
      ortho_size: f32 = 20.0
      position := node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      direction := node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0}
      light_info = {
        index_in_scene = i,
        kind           = .DIRECTIONAL,
        color          = light.color.xyz,
        has_shadow     = light.cast_shadow,
        position       = position,
        direction      = direction,
        projection     = linalg.matrix_ortho3d(-ortho_size, ortho_size, -ortho_size, ortho_size, 0.1, 999999.0),
        view           = linalg.matrix4_look_at(position.xyz, position.xyz + direction.xyz, linalg.VECTOR3F32_Y_AXIS),
      }
    case SpotLightAttachment:
      position := node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      direction := node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0}
      light_info = {
        index_in_scene = i,
        kind           = .SPOT,
        color          = light.color.xyz,
        radius         = light.radius,
        angle          = light.angle,
        has_shadow     = light.cast_shadow,
        position       = position,
        direction      = direction,
        projection     = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius),
        view           = linalg.matrix4_look_at(position.xyz, position.xyz + direction.xyz, linalg.VECTOR3F32_Y_AXIS),
      }
    case:
      continue
    }
    j, found := node_idx_to_light_idx[i]
    if found {
      visible_lights[j] = light_info
    } else if len(visible_lights) < MAX_LIGHTS {
      j = len(visible_lights)
      append(visible_lights, light_info)
      node_idx_to_light_idx[i] = j
    }
    visible_lights[j].shadow_map = &self.main.frames[g_frame_index].shadow_maps[j]
    visible_lights[j].cube_shadow_map = &self.main.frames[g_frame_index].cube_shadow_maps[j]
    seen[j] = true
  }
  // Remove lights that are no longer present
  for j := 0; j < len(visible_lights); {
    if seen[j] {
      j += 1
      continue
    }
    delete_key(node_idx_to_light_idx, visible_lights[j].index_in_scene)
    unordered_remove(visible_lights, j)
    node_idx_to_light_idx[visible_lights[j].index_in_scene] = j
  }
}

render :: proc(self: ^Engine) -> vk.Result {
  acquire_next_image(&self.swapchain) or_return
  mu.begin(&self.ui.ctx)
  command_buffer := self.command_buffers[g_frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  // dispatch computation early and doing other work while GPU is busy
  compute_particles(&self.particle, command_buffer)
  update_visible_lights(self)
  log.debug("============ rendering shadow pass...============ ")
  renderer_shadow_begin(self, command_buffer)
  renderer_shadow_render(self, command_buffer)
  renderer_shadow_end(self, command_buffer)
  prepare_image_for_render(
    command_buffer,
    self.main.frames[g_frame_index].main_pass_image.image,
  )
  log.debug("============ rendering depth pre-pass... =============")
  renderer_depth_prepass_begin(self, command_buffer)
  renderer_depth_prepass_render(self, command_buffer)
  renderer_depth_prepass_end(self, command_buffer)
  if true {
    log.debug("============ rendering G-buffer pass... =============")
    renderer_gbuffer_begin(self, command_buffer, self.swapchain.extent)
    renderer_gbuffer_render(self, command_buffer)
    renderer_gbuffer_end(self, command_buffer)

    log.debug("============ rendering main pass... =============")
    renderer_main_begin(self, command_buffer)
    renderer_main_render(self, command_buffer)
    renderer_main_end(self, command_buffer)
    log.debug("============ rendering particles... =============")
    renderer_particle_begin(
      self,
      command_buffer,
      self.main.frames[g_frame_index].main_pass_image.view,
      self.depth_prepass.depth_buffer.view,
    )
    renderer_particle_render(self, command_buffer)
    renderer_particle_end(self, command_buffer)
  }
  log.debug("============ rendering post processes... =============")
  prepare_image_for_shader_read(
    command_buffer,
    self.main.frames[g_frame_index].main_pass_image.image,
  )
  renderer_postprocess_begin(
    &self.postprocess,
    command_buffer,
    self.main.frames[g_frame_index].main_pass_image.view,
    self.depth_prepass.depth_buffer.view,
    self.gbuffer.normal_buffer.view,
    self.swapchain.extent,
  )
  prepare_image_for_render(
    command_buffer,
    self.swapchain.images[self.swapchain.image_index],
  )
  renderer_postprocess_render(
    &self.postprocess,
    command_buffer,
    self.swapchain.extent,
    self.swapchain.views[self.swapchain.image_index],
  )
  renderer_postprocess_end(&self.postprocess, command_buffer)
  if mu.window(&self.ui.ctx, "Engine", {40, 40, 300, 150}, {.NO_CLOSE}) {
    mu.label(
      &self.ui.ctx,
      fmt.tprintf(
        "Objects %d",
        len(self.scene.nodes.entries) - len(self.scene.nodes.free_indices),
      ),
    )
    mu.label(
      &self.ui.ctx,
      fmt.tprintf(
        "Textures %d",
        len(g_image_buffers.entries) - len(g_image_buffers.free_indices),
      ),
    )
    mu.label(
      &self.ui.ctx,
      fmt.tprintf(
        "Materials %d",
        len(g_materials.entries) - len(g_materials.free_indices),
      ),
    )
    mu.label(
      &self.ui.ctx,
      fmt.tprintf(
        "Meshes %d",
        len(g_meshes.entries) - len(g_meshes.free_indices),
      ),
    )
  }
  if self.render2d_proc != nil {
    self.render2d_proc(self, &self.ui.ctx)
  }
  mu.end(&self.ui.ctx)
  log.debug("============ rendering UI... =============")
  renderer_ui_begin(
    &self.ui,
    command_buffer,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
  )
  renderer_ui_render(&self.ui, command_buffer)
  renderer_ui_end(&self.ui, command_buffer)
  log.debug("============ preparing image for present... =============")
  prepare_image_for_present(
    command_buffer,
    self.swapchain.images[self.swapchain.image_index],
  )
  vk.EndCommandBuffer(command_buffer) or_return
  submit_queue_and_present(&self.swapchain, &command_buffer) or_return
  g_frame_index = (g_frame_index + 1) % MAX_FRAMES_IN_FLIGHT
  return .SUCCESS
}

run :: proc(self: ^Engine, width: u32, height: u32, title: string) {
  if init(self, width, height, title) != .SUCCESS {
    return
  }
  defer deinit(self)
  frame := 0
  // for !glfw.WindowShouldClose(self.window) && frame < 3 {
  for !glfw.WindowShouldClose(self.window) {
    update(self)
    if time.duration_milliseconds(time.since(self.last_frame_timestamp)) <
       FRAME_TIME_MILIS {
      continue
    }
    res := render(self)
    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
      recreate_swapchain(self) or_continue

    }
    if res != .SUCCESS {
      log.errorf("Error during rendering", res)
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
