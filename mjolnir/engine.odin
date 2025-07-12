package mjolnir

import "animation"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "core:slice"
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
SHADOW_MAP_SIZE :: 512
MAX_SHADOW_MAPS :: 10
MAX_TEXTURES :: 90
MAX_CUBE_TEXTURES :: 20
USE_GPU_CULLING :: true // Set to false to use CPU culling instead

Handle :: resource.Handle

g_context: runtime.Context
g_frame_index: u32 = 0

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
Render2DProc :: #type proc(engine: ^Engine, ctx: ^mu.Context)
KeyInputProc :: #type proc(engine: ^Engine, key, action, mods: int)
MousePressProc :: #type proc(engine: ^Engine, key, action, mods: int)
MouseDragProc :: #type proc(engine: ^Engine, delta, offset: [2]f64)
MouseScrollProc :: #type proc(engine: ^Engine, offset: [2]f64)
MouseMoveProc :: #type proc(engine: ^Engine, pos, delta: [2]f64)

PointLightData :: struct {
  views:          [6]matrix[4, 4]f32,
  proj:           matrix[4, 4]f32,
  world:          matrix[4, 4]f32,
  color:          [4]f32,
  position:       [4]f32,
  radius:         f32,
  shadow_map:     Handle,
  render_targets: [6]Handle,
}

SpotLightData :: struct {
  view:          matrix[4, 4]f32,
  proj:          matrix[4, 4]f32,
  world:         matrix[4, 4]f32,
  color:         [4]f32,
  position:      [4]f32,
  direction:     [4]f32,
  radius:        f32,
  angle:         f32,
  shadow_map:    Handle,
  render_target: Handle,
}

DirectionalLightData :: struct {
  view:      matrix[4, 4]f32,
  proj:      matrix[4, 4]f32,
  world:     matrix[4, 4]f32,
  color:     [4]f32,
  direction: [4]f32,
}

LightData :: union {
  PointLightData,
  SpotLightData,
  DirectionalLightData,
}

CameraUniform :: struct {
  view:            matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  viewport_size:   [2]f32,
  camera_near:     f32,
  camera_far:      f32,
  camera_position: [3]f32,
  padding:         [9]f32, // Align to 192-byte
}

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

// RenderInput groups render batches and other per-frame data for the renderer.
RenderInput :: struct {
  batches: map[BatchKey][dynamic]BatchData,
}

InputState :: struct {
  mouse_pos:         [2]f64,
  mouse_drag_origin: [2]f32,
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

Engine :: struct {
  window:                glfw.WindowHandle,
  swapchain:             Swapchain,
  scene:                 Scene,
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
  visibility_culler:     VisibilityCuller,
  shadow:                RendererShadow,
  depth_prepass:         RendererDepthPrepass,
  gbuffer:               RendererGBuffer,
  ambient:               RendererAmbient,
  main:                  RendererLighting,
  particle:              RendererParticle,
  transparent:           RendererTransparent,
  postprocess:           RendererPostProcess,
  ui:                    RendererUI,
  command_buffers:       [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  cursor_pos:            [2]i32,
  // Main render target for primary rendering
  main_render_target:    [MAX_FRAMES_IN_FLIGHT]RenderTarget,
  // Engine-managed shadow maps
  shadow_maps:           [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  cube_shadow_maps:      [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
}

get_window_dpi :: proc(window: glfw.WindowHandle) -> f32 {
  sw, sh := glfw.GetWindowContentScale(window)
  // Use X scale, warn if not equal
  if sw != sh {
    log.warnf("DPI scale x (%v) and y (%v) not the same, using x", sw, sh)
  }
  return sw
}

// Initialize engine shadow map pools
engine_init_shadow_maps :: proc(engine: ^Engine) -> vk.Result {
  for f in 0 ..< MAX_FRAMES_IN_FLIGHT {
    for i in 0 ..< MAX_SHADOW_MAPS {
      engine.shadow_maps[f][i], _, _ = create_empty_texture_2d(
        SHADOW_MAP_SIZE,
        SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      )
      engine.cube_shadow_maps[f][i], _, _ = create_empty_texture_cube(
        SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      )
    }
    log.debugf("Created new 2D shadow maps %v", engine.shadow_maps[f])
    log.debugf("Created new cube shadow maps %v", engine.cube_shadow_maps[f])
  }
  return .SUCCESS
}

// Helper to update camera uniform from camera data
camera_uniform_update :: proc(
  uniform: ^CameraUniform,
  camera: ^geometry.Camera,
  viewport_width, viewport_height: u32,
) {
  uniform.view, uniform.projection = geometry.camera_calculate_matrices(camera^)
  uniform.viewport_size = [2]f32{f32(viewport_width), f32(viewport_height)}
  uniform.camera_position = camera.position
  uniform.camera_near, uniform.camera_far = geometry.camera_get_near_far(camera^)
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

  // Initialize engine shadow map pools
  engine_init_shadow_maps(self) or_return

  // Initialize main render targets for each frame
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    render_target_init(
      &self.main_render_target[i],
      self.scene.main_camera,
      self.swapchain.extent.width,
      self.swapchain.extent.height,
      self.swapchain.format.format,
      .D32_SFLOAT,
    ) or_return
  }
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
  lighting_init(
    &self.main,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
    vk.Format.D32_SFLOAT,
  ) or_return
  ambient_init(
    &self.ambient,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
  ) or_return
  // Initialize ambient renderer fields to match main renderer
  self.ambient.environment_index = self.main.environment_map.index
  self.ambient.brdf_lut_index = self.main.brdf_lut.index
  self.ambient.environment_max_lod = self.main.environment_max_lod
  self.ambient.ibl_intensity = self.main.ibl_intensity
  gbuffer_init(
    &self.gbuffer,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  depth_prepass_init(
    &self.depth_prepass,
    self.swapchain.extent,
  ) or_return
  particle_init(&self.particle) or_return
  when USE_GPU_CULLING {
    visibility_culler_init(&self.visibility_culler) or_return
  }
  transparent_init(
    &self.transparent,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  log.debugf("initializing shadow pipeline")
  shadow_init(&self.shadow, .D32_SFLOAT) or_return
  log.debugf("initializing post process pipeline")
  postprocess_init(
    &self.postprocess,
    self.swapchain.format.format,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  ui_init(
    &self.ui,
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
        &engine.ui.ctx,
        -i32(math.round(xoffset)),
        -i32(math.round(yoffset)),
      )
      // Camera control moved to camera controllers
      // if main_camera := resource.get(g_cameras, engine.scene.main_camera);
      //    main_camera != nil {
      //   geometry.camera_orbit_zoom(
      //     main_camera,
      //     -f32(yoffset) * SCROLL_SENSITIVITY,
      //   )
      // }
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

update_emitters :: proc(self: ^Engine, delta_time: f32) {
  params := data_buffer_get(&self.particle.params_buffer)
  params.delta_time = delta_time

  emitters_ptr := data_buffer_get(&self.particle.emitter_buffer)
  emitters := slice.from_ptr(emitters_ptr, MAX_EMITTERS)
  emitter_idx: int = 0

  for &entry, entry_index in self.scene.nodes.entries do if entry.active {
    e, is_emitter := &entry.item.attachment.(EmitterAttachment)
    if !is_emitter do continue
    if !e.enabled do continue
    if emitter_idx >= MAX_EMITTERS do break

    // Check visibility for culling
    visible := true
    culling_enabled := entry.item.culling_enabled
    when USE_GPU_CULLING {
      if culling_enabled {
        visible = multi_camera_is_node_visible(&self.visibility_culler, 0, u32(entry_index))
      }
    }
    emitters[emitter_idx].transform = entry.item.transform.world_matrix
    emitters[emitter_idx].initial_velocity = e.initial_velocity
    emitters[emitter_idx].color_start = e.color_start
    emitters[emitter_idx].color_end = e.color_end
    emitters[emitter_idx].emission_rate = e.emission_rate
    emitters[emitter_idx].particle_lifetime = e.particle_lifetime
    emitters[emitter_idx].position_spread = e.position_spread
    emitters[emitter_idx].velocity_spread = e.velocity_spread
    emitters[emitter_idx].size_start = e.size_start
    emitters[emitter_idx].size_end = e.size_end
    emitters[emitter_idx].weight = e.weight
    emitters[emitter_idx].weight_spread = e.weight_spread
    emitters[emitter_idx].texture_index = e.texture_handle.index
    emitters[emitter_idx].visible = b32(!culling_enabled || visible)
    emitters[emitter_idx].aabb_min = {e.bounding_box.min.x, e.bounding_box.min.y, e.bounding_box.min.z, 0.0}
    emitters[emitter_idx].aabb_max = {e.bounding_box.max.x, e.bounding_box.max.y, e.bounding_box.max.z, 0.0}
    emitter_idx += 1
  }
  params.emitter_count = u32(emitter_idx)
}

update_force_fields :: proc(self: ^Engine) {
  params := data_buffer_get(&self.particle.params_buffer)
  params.forcefield_count = 0
  forcefields := slice.from_ptr(
    self.particle.force_field_buffer.mapped,
    MAX_FORCE_FIELDS,
  )
  for &entry in self.scene.nodes.entries do if entry.active {
    ff, is_ff := &entry.item.attachment.(ForceFieldAttachment)
    if !is_ff do continue
    ff.position = entry.item.transform.world_matrix * [4]f32{0, 0, 0, 1}
    forcefields[params.forcefield_count] = ff
    params.forcefield_count += 1
  }
  for i in params.forcefield_count ..< MAX_FORCE_FIELDS {
    forcefields[i] = {}
  }
}

update :: proc(self: ^Engine) -> bool {
  glfw.PollEvents()
  delta_time := get_delta_time(self)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  scene_traverse(&self.scene)
  for &entry in self.scene.nodes.entries {
    if !entry.active do continue
    data, is_mesh := &entry.item.attachment.(MeshAttachment)
    if !is_mesh do continue
    skinning, has_skin := &data.skinning.?
    if !has_skin do continue
    anim_inst, has_animation := &skinning.animation.?
    if !has_animation do continue
    animation.instance_update(anim_inst, delta_time)
    mesh := resource.get(g_meshes, data.handle) or_continue
    mesh_skin, mesh_has_skin := mesh.skinning.?
    if !mesh_has_skin do continue
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
  update_force_fields(self)
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
  // Camera control moved to camera controllers
  // if self.input.mouse_holding[glfw.MOUSE_BUTTON_1] {
  //   if main_camera := resource.get(g_cameras, self.scene.main_camera);
  //      main_camera != nil {
  //     geometry.camera_orbit_rotate(
  //       main_camera,
  //       f32(delta.x * MOUSE_SENSITIVITY_X),
  //       f32(delta.y * MOUSE_SENSITIVITY_Y),
  //     )
  //   }
  // }
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
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    render_target_deinit(&self.main_render_target[i])
  }
  ui_deinit(&self.ui)
  scene_deinit(&self.scene)
  lighting_deinit(&self.main)
  ambient_deinit(&self.ambient)
  gbuffer_deinit(&self.gbuffer)
  shadow_deinit(&self.shadow)
  postprocess_deinit(&self.postprocess)
  particle_deinit(&self.particle)
  when USE_GPU_CULLING {
    visibility_culler_deinit(&self.visibility_culler)
  }
  transparent_deinit(&self.transparent)
  depth_prepass_deinit(&self.depth_prepass)
  factory_deinit()
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
  if main_camera := resource.get(g_cameras, engine.scene.main_camera);
     main_camera != nil {
    geometry.camera_update_aspect_ratio(main_camera, new_aspect_ratio)
  }

  // Recreate main render targets with new dimensions
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    render_target_deinit(&engine.main_render_target[i])
    render_target_init(
      &engine.main_render_target[i],
      engine.scene.main_camera,
      engine.swapchain.extent.width,
      engine.swapchain.extent.height,
      engine.swapchain.format.format,
      .D32_SFLOAT,
    ) or_return
  }

  // No need to update camera uniform descriptor sets with bindless cameras

  lighting_recreate_images(
    &engine.main,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
    vk.Format.D32_SFLOAT,
  ) or_return
  // renderer_ambient_recreate_images does not exist - skip
  postprocess_recreate_images(
    &engine.postprocess,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
  ) or_return
  ui_recreate_images(
    &engine.ui,
    engine.swapchain.format.format,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    get_window_dpi(engine.window),
  ) or_return
  return .SUCCESS
}

// Generate render input for a given frustum (camera or light)
generate_render_input :: proc(
  self: ^Engine,
  frustum: geometry.Frustum,
  camera_handle: resource.Handle,
  shadow_pass: bool = false,
) -> (
  ret: RenderInput,
) {
  ret.batches = make(
    map[BatchKey][dynamic]BatchData,
    allocator = context.temp_allocator,
  )
  visible_count: u32 = 0
  total_count: u32 = 0
  for &entry, entry_index in self.scene.nodes.entries do if entry.active {
    node := &entry.item
    handle := Handle{entry.generation, u32(entry_index)}
    #partial switch data in node.attachment {
    case MeshAttachment:
      // Skip nodes that don't cast shadows when rendering shadow pass
      if shadow_pass && !data.cast_shadow do continue
      mesh := resource.get(g_meshes, data.handle)
      if mesh == nil do continue
      material := resource.get(g_materials, data.material)
      if material == nil do continue
      total_count += 1
      // Use GPU culling results if available, otherwise fall back to CPU culling
      visible := true
      when USE_GPU_CULLING {
        // For multi-camera culling, we need to check against slot 0 (main camera) for now
        // Shadow rendering will use appropriate camera slots
        visible = multi_camera_is_node_visible(&self.visibility_culler, 0, u32(entry_index))
      } else {
        world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
        visible = geometry.frustum_test_aabb(frustum, world_aabb)
      }
      if !visible do continue
      visible_count += 1
      batch_key := BatchKey {
        features      = material.features,
        material_type = material.type,
      }
      batch_group, group_found := &ret.batches[batch_key]
      if !group_found {
        ret.batches[batch_key] = make([dynamic]BatchData, allocator = context.temp_allocator)
        batch_group = &ret.batches[batch_key]
      }
      batch_data: ^BatchData
      for &batch in batch_group {
        if batch.material_handle == data.material {
          batch_data = &batch
          break
        }
      }
      if batch_data == nil {
        new_batch := BatchData {
          material_handle = data.material,
          nodes           = make([dynamic]^Node, allocator = context.temp_allocator),
        }
        append(batch_group, new_batch)
        batch_data = &batch_group[len(batch_group) - 1]
      }
      append(&batch_data.nodes, node)
    }
  }
  return
}

// Generate render input for a specific camera slot (for shadow rendering)
generate_render_input_camera_slot :: proc(
  self: ^Engine,
  frustum: geometry.Frustum,
  camera_slot: u32,
  shadow_pass: bool = false,
) -> (
  ret: RenderInput,
) {
  ret.batches = make(
    map[BatchKey][dynamic]BatchData,
    allocator = context.temp_allocator,
  )
  visible_count: u32 = 0
  total_count: u32 = 0
  for &entry, entry_index in self.scene.nodes.entries do if entry.active {
    node := &entry.item
    handle := Handle{entry.generation, u32(entry_index)}
    #partial switch data in node.attachment {
    case MeshAttachment:
      // Skip nodes that don't cast shadows when rendering shadow pass
      if shadow_pass && !data.cast_shadow do continue
      mesh := resource.get(g_meshes, data.handle)
      if mesh == nil do continue
      material := resource.get(g_materials, data.material)
      if material == nil do continue
      total_count += 1
      // Use GPU culling results if available, otherwise fall back to CPU culling
      visible := true
      when USE_GPU_CULLING {
        visible = multi_camera_is_node_visible(&self.visibility_culler, camera_slot, u32(entry_index))
      } else {
        world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
        visible = geometry.frustum_test_aabb(frustum, world_aabb)
      }
      if !visible do continue
      visible_count += 1
      batch_key := BatchKey {
        features      = material.features,
        material_type = material.type,
      }
      batch_group, group_found := &ret.batches[batch_key]
      if !group_found {
        ret.batches[batch_key] = make([dynamic]BatchData, allocator = context.temp_allocator)
        batch_group = &ret.batches[batch_key]
      }
      batch_data: ^BatchData
      for &batch in batch_group {
        if batch.material_handle == data.material {
          batch_data = &batch
          break
        }
      }
      if batch_data == nil {
        new_batch := BatchData {
          material_handle = data.material,
          nodes           = make([dynamic]^Node, allocator = context.temp_allocator),
        }
        append(batch_group, new_batch)
        batch_data = &batch_group[len(batch_group) - 1]
      }
      append(&batch_data.nodes, node)
    }
  }
  return
}


render :: proc(self: ^Engine) -> vk.Result {
  // log.debug("============ acquiring image...============ ")
  acquire_next_image(&self.swapchain) or_return
  mu.begin(&self.ui.ctx)
  command_buffer := self.command_buffers[g_frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  // log.debug("============ setup main camera...============ ")
  // Update camera uniform for main render target
  render_target_update_camera_uniform(&self.main_render_target[g_frame_index])

  main_camera := resource.get(g_cameras, self.scene.main_camera)
  if main_camera == nil {
    log.errorf("Main camera not found with handle: %v", self.scene.main_camera)
    return .ERROR_UNKNOWN
  }
  main_camera_index := self.main_render_target[g_frame_index].camera.index
  camera_uniform := get_camera_uniform(main_camera_index)
  frustum := geometry.make_frustum(
    camera_uniform.projection * camera_uniform.view,
  )
  // log.debug("============ collecting lights ...============ ")
  lights := make([dynamic]LightData, 0)
  defer delete(lights)
  shadow_casters := make([dynamic]LightData, 0)
  shadow_map_count := 0
  cube_shadow_map_count := 0
  defer delete(shadow_casters)
  defer {
    // TODO: allocate and deallocate per-frame is sub optimal
    // but we follow this approach for now, generational array allocation is pretty fast
    // deallocate all render target used by shadow casters
    for caster in shadow_casters {
      switch light in caster {
      case SpotLightData:
        ptr := resource.get(g_render_targets, light.render_target)
        resource.free(&g_render_targets, light.render_target)
        resource.free(&g_cameras, ptr.camera)
      case PointLightData:
        for target in light.render_targets {
          ptr := resource.get(g_render_targets, target)
          resource.free(&g_render_targets, target)
          resource.free(&g_cameras, ptr.camera)
        }
      case DirectionalLightData:
      }
    }
  }
  for &entry, entry_index in self.scene.nodes.entries do if entry.active {
    node := &entry.item
    when USE_GPU_CULLING {
      visible := multi_camera_is_node_visible(&self.visibility_culler, 0, u32(entry_index))
      if !visible do continue
    }
    #partial switch &light in &node.attachment {
    case PointLightAttachment:
      data: PointLightData
      position := node.transform.world_matrix * [4]f32{0, 0, 0, 1}
      data.world = node.transform.world_matrix
      data.color = light.color
      data.position = position
      data.radius = light.radius
      if light.cast_shadow {
        data.shadow_map = self.cube_shadow_maps[g_frame_index][cube_shadow_map_count]
        cube_shadow_map_count += 1
        // Generate view matrices for each cube face using Vulkan standard layout
        // Vulkan cube map layers: [+X, -X, +Y, -Y, +Z, -Z] (Right, Left, Top, Bottom, Front, Back)
        // With proper up vectors according to Vulkan coordinate system (Y-up, right-handed)
        @(static) face_dirs := [6][3]f32 {
          {1, 0, 0}, // +X (Right)
          {-1, 0, 0}, // -X (Left)
          {0, 1, 0}, // +Y (Top)
          {0, -1, 0}, // -Y (Bottom)
          {0, 0, 1}, // +Z (Front)
          {0, 0, -1}, // -Z (Back)
        }
        @(static) face_ups := [6][3]f32 {
          {0, -1, 0}, // +X: Up is -Y
          {0, -1, 0}, // -X: Up is -Y
          {0, 0, 1}, // +Y: Up is +Z
          {0, 0, -1}, // -Y: Up is -Z
          {0, -1, 0}, // +Z: Up is -Y
          {0, -1, 0}, // -Z: Up is -Y
        }
        for i in 0 ..< 6 {
          // Allocate render target for this cube face
          render_target: ^RenderTarget
          data.render_targets[i], render_target = resource.alloc(&g_render_targets)
          render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
          render_target.depth_texture = data.shadow_map
          render_target.owns_depth_texture = false // Engine owns the shadow map
          // Allocate camera for this cube face
          camera: ^geometry.Camera
          render_target.camera, camera = resource.alloc(&g_cameras)
          camera^ = geometry.make_camera_perspective(math.PI * 0.5,  1.0,  0.1,  light.radius )// 90 degrees FOV for cube faces// Square aspect ratio// near// far based on light radius
          // Set camera position and orientation for this cube face
          target_pos := position.xyz + face_dirs[i]
          geometry.camera_look_at(camera, position.xyz, target_pos, face_ups[i])
          render_target_update_camera_uniform(render_target)
          // Update camera in bindless buffer
          camera_uniform := get_camera_uniform(render_target.camera.index)
          data.views[i] = camera_uniform.view
          if i == 0 {
            data.proj = camera_uniform.projection // Only set once since all faces use same projection
          }
        }
      }
      append(&lights, data)
      if light.cast_shadow && cube_shadow_map_count <= MAX_SHADOW_MAPS {
        append(&shadow_casters, data)
      }
    case DirectionalLightAttachment:
      data: DirectionalLightData
      ortho_size: f32 = 20.0
      data.direction = node.transform.world_matrix * [4]f32{0, 0, -1, 0}
      data.proj = linalg.matrix_ortho3d(-ortho_size, ortho_size, -ortho_size, ortho_size, 0.1, 9999.0)
      data.view = linalg.matrix4_look_at([3]f32{}, data.direction.xyz, linalg.VECTOR3F32_Y_AXIS)
      data.world = node.transform.world_matrix
      data.color = light.color
      if light.cast_shadow {
        // TODO: handle directional light shadow, skip for now
      }
      append(&lights, data)
      if light.cast_shadow && shadow_map_count <= MAX_SHADOW_MAPS {
        append(&shadow_casters, data)
      }
    case SpotLightAttachment:
      data: SpotLightData
      data.position = node.transform.world_matrix * [4]f32{0, 0, 0, 1}
      data.direction = node.transform.world_matrix * [4]f32{0, -1, 0, 0} // Point downward (-Y), toward illuminated objects
      data.world = node.transform.world_matrix
      data.radius = light.radius
      data.angle = light.angle
      data.color = light.color
      if light.cast_shadow && shadow_map_count < MAX_SHADOW_MAPS {
        data.shadow_map = self.shadow_maps[g_frame_index][shadow_map_count]
        shadow_map_count += 1

        render_target: ^RenderTarget
        data.render_target, render_target = resource.alloc(&g_render_targets)
        render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
        render_target.depth_texture = data.shadow_map
        render_target.owns_depth_texture = false

        camera: ^geometry.Camera
        render_target.camera, camera = resource.alloc(&g_cameras)
        camera^ = geometry.make_camera_perspective(data.angle * 2.0,  1.0,  0.1,  data.radius )// Simple FOV calculation// Square aspect ratio// near// far
        // Set camera to look in the direction of the light
        target_pos := data.position.xyz + data.direction.xyz
        geometry.camera_look_at(camera, data.position.xyz, target_pos)
        render_target_update_camera_uniform(render_target)
        camera_uniform := get_camera_uniform(render_target.camera.index)
        data.view = camera_uniform.view
        data.proj = camera_uniform.projection
        append(&shadow_casters, data)
      }
      append(&lights, data)
    }
  }
  // log.debug("============ run visibility culling...============ ")
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  when USE_GPU_CULLING {
    // Collect all active render targets for multi-camera culling
    active_render_targets := make(
      [dynamic]RenderTarget,
      0,
      context.temp_allocator,
    )
    append(&active_render_targets, self.main_render_target[g_frame_index])

    // Add shadow map render targets from shadow casters
    for caster in shadow_casters {
      #partial switch light in caster {
      case PointLightData:
        for target_handle in light.render_targets {
          if target := resource.get(g_render_targets, target_handle);
             target != nil {
            append(&active_render_targets, target^)
          }
        }
      case SpotLightData:
        if target := resource.get(g_render_targets, light.render_target);
           target != nil {
          append(&active_render_targets, target^)
        }
      }
    }

    // Update and perform multi-camera GPU scene culling
    visibility_culler_update_multi_camera(
      &self.visibility_culler,
      &self.scene,
      active_render_targets[:],
    )
    visibility_culler_execute_multi_camera(
      &self.visibility_culler,
      command_buffer,
    )

    // Memory barrier to ensure culling is complete before other operations
    visibility_buffer_barrier := vk.BufferMemoryBarrier {
      sType               = .BUFFER_MEMORY_BARRIER,
      srcAccessMask       = {.SHADER_WRITE},
      dstAccessMask       = {.SHADER_READ, .HOST_READ},
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      buffer              = self.visibility_culler.multi_visibility_buffer[g_frame_index].buffer,
      offset              = 0,
      size                = vk.DeviceSize(
        self.visibility_culler.multi_visibility_buffer[g_frame_index].bytes_count,
      ),
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.COMPUTE_SHADER},
      {.VERTEX_SHADER, .FRAGMENT_SHADER, .HOST},
      {},
      0,
      nil,
      1,
      &visibility_buffer_barrier,
      0,
      nil,
    )
    // End command buffer and submit immediately to ensure GPU work completes
    vk.EndCommandBuffer(command_buffer) or_return
    submit_info := vk.SubmitInfo {
      sType              = .SUBMIT_INFO,
      commandBufferCount = 1,
      pCommandBuffers    = &command_buffer,
    }
    vk.QueueSubmit(g_graphics_queue, 1, &submit_info, 0) or_return
    vk.QueueWaitIdle(g_graphics_queue) or_return
    // Begin command buffer again for the rest of the rendering
    vk.BeginCommandBuffer(
      command_buffer,
      &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
    ) or_return
  } else {
    // Legacy single-camera culling for main camera
    visibility_culler_update(&self.visibility_culler, &self.scene)
    visibility_culler_execute_with_frustum(
      &self.visibility_culler,
      command_buffer,
      0,
      frustum,
    )
  }

  compute_particles(&self.particle, command_buffer, main_camera^)
  // log.debug("============ rendering shadow pass...============ ")
  // Transition all shadow maps to depth attachment optimal
  shadow_2d_images: [MAX_SHADOW_MAPS]vk.Image
  for i in 0 ..< shadow_map_count {
    b, ok := resource.get(
      g_image_2d_buffers,
      self.shadow_maps[g_frame_index][i],
    )
    if !ok {
      continue
    }
    shadow_2d_images[i] = b.image
  }
  // log.debugf("Transitioning %d 2d shadow maps to attachment", shadow_map_count)
  if shadow_map_count > 0 {
    transition_images(
      command_buffer,
      shadow_2d_images[:shadow_map_count],
      .UNDEFINED,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      {.DEPTH},
      1,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    )
  }
  shadow_cube_images: [MAX_SHADOW_MAPS]vk.Image
  for i in 0 ..< cube_shadow_map_count {
    b, ok := resource.get(
      g_image_cube_buffers,
      self.cube_shadow_maps[g_frame_index][i],
    )
    if !ok {
      continue
    }
    shadow_cube_images[i] = b.image
  }
  // log.debugf("Transitioning %d cube shadow maps to attachment", cube_shadow_map_count)
  if cube_shadow_map_count > 0 {
    transition_images(
      command_buffer,
      shadow_cube_images[:cube_shadow_map_count],
      .UNDEFINED,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      {.DEPTH},
      6,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    )
  }
  // log.debugf("============ shadow casters (%d)...============ ", len(shadow_casters))
  current_camera_slot: u32 = 1 // Start from slot 1 (slot 0 is main camera)
  for node, i in shadow_casters {
    // log.debugf("Processing shadow caster %d", i)
    #partial switch light in node {
    case PointLightData:
      // log.debugf("Processing point light %d", i)
      if light.shadow_map.generation == 0 {
        log.errorf("Point light %d has invalid shadow map handle", i)
        continue
      }
      cube_shadow := resource.get(g_image_cube_buffers, light.shadow_map)
      for face in 0 ..< 6 {
        frustum := geometry.make_frustum(light.proj * light.views[face])
        shadow_render_input: RenderInput
        when USE_GPU_CULLING {
          shadow_render_input = generate_render_input_camera_slot(
            self,
            frustum,
            current_camera_slot,
            shadow_pass = true,
          )
        } else {
          shadow_render_input = generate_render_input(
            self,
            frustum,
            self.scene.main_camera,
            shadow_pass = true,
          )
        }
        target := resource.get(g_render_targets, light.render_targets[face])
        shadow_begin(target^, command_buffer, u32(face))
        shadow_render(
          &self.shadow,
          shadow_render_input,
          node,
          target^,
          command_buffer,
        )
        shadow_end(command_buffer)
        current_camera_slot += 1
      }
    case DirectionalLightData:
    case SpotLightData:
      if light.shadow_map.generation == 0 {
        log.errorf("Spot light %d has invalid shadow map handle", i)
        continue
      }
      frustum := geometry.make_frustum(light.proj * light.view)

      shadow_render_input: RenderInput
      when USE_GPU_CULLING {
        shadow_render_input = generate_render_input_camera_slot(
          self,
          frustum,
          current_camera_slot,
          shadow_pass = true,
        )
      } else {
        shadow_render_input = generate_render_input(
          self,
          frustum,
          self.scene.main_camera,
          shadow_pass = true,
        )
      }

      shadow_map_texture := resource.get(g_image_2d_buffers, light.shadow_map)
      shadow_target := resource.get(g_render_targets, light.render_target)
      shadow_begin(shadow_target^, command_buffer)
      shadow_render(
        &self.shadow,
        shadow_render_input,
        node,
        shadow_target^,
        command_buffer,
      )
      shadow_end(command_buffer)
      current_camera_slot += 1
    }
  }
  // Transition all shadow maps to shader read only optimal
  // log.debugf("Transitioning %d 2D shadow maps to shader read", shadow_map_count)
  transition_images(
    command_buffer,
    shadow_2d_images[:shadow_map_count],
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.DEPTH},
    1,
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.SHADER_READ},
  )
  // log.debugf("Transitioning %d cube shadow maps to shader read", cube_shadow_map_count)
  transition_images(
    command_buffer,
    shadow_cube_images[:cube_shadow_map_count],
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.DEPTH},
    6,
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.SHADER_READ},
  )
  final_image := resource.get(
    g_image_2d_buffers,
    self.main_render_target[g_frame_index].final_image,
  )
  transition_image(
    command_buffer,
    final_image.image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {.COLOR},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {},
    {.COLOR_ATTACHMENT_WRITE},
  )
  // log.debug("============ rendering depth pre-pass... =============")
  depth_input := generate_render_input(self, frustum, self.scene.main_camera)
  depth_prepass_begin(&self.main_render_target[g_frame_index], command_buffer)
  depth_prepass_render(
    &self.depth_prepass,
    &depth_input,
    command_buffer,
    self.main_render_target[g_frame_index].camera.index,
  )
  depth_prepass_end(command_buffer)
  // log.debug("============ rendering G-buffer pass... =============")
  // Transition G-buffer images to COLOR_ATTACHMENT_OPTIMAL
  render_target := &self.main_render_target
  gbuffer_position := resource.get(
    g_image_2d_buffers,
    render_target[g_frame_index].position_texture,
  )
  gbuffer_normal := resource.get(
    g_image_2d_buffers,
    render_target[g_frame_index].normal_texture,
  )
  gbuffer_albedo := resource.get(
    g_image_2d_buffers,
    render_target[g_frame_index].albedo_texture,
  )
  gbuffer_metallic := resource.get(
    g_image_2d_buffers,
    render_target[g_frame_index].metallic_roughness_texture,
  )
  gbuffer_emissive := resource.get(
    g_image_2d_buffers,
    render_target[g_frame_index].emissive_texture,
  )
  gbuffer_images := [?]vk.Image {
    gbuffer_position.image,
    gbuffer_normal.image,
    gbuffer_albedo.image,
    gbuffer_metallic.image,
    gbuffer_emissive.image,
  }
  // Batch transition all G-buffer images to COLOR_ATTACHMENT_OPTIMAL in a single API call
  transition_images(
    command_buffer,
    gbuffer_images[:],
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {.COLOR},
    1,
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR_ATTACHMENT_WRITE},
  )
  gbuffer_input := depth_input
  gbuffer_begin(
    &self.main_render_target[g_frame_index],
    command_buffer,
  )
  gbuffer_render(
    &self.gbuffer,
    &gbuffer_input,
    &self.main_render_target[g_frame_index],
    command_buffer,
  )
  gbuffer_end(&self.main_render_target[g_frame_index], command_buffer)
  // Transition G-buffer images to SHADER_READ_ONLY_OPTIMAL
  // Batch transition all G-buffer images to SHADER_READ_ONLY_OPTIMAL in a single API call
  transition_images(
    command_buffer,
    gbuffer_images[:],
    .COLOR_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.COLOR},
    1,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {.SHADER_READ},
  )
  // log.debug("============ rendering main pass... =============")
  // Prepare RenderTarget and RenderInput for decoupled renderer
  // Ambient pass
  ambient_begin(
    &self.ambient,
    self.main_render_target[g_frame_index],
    command_buffer,
  )
  ambient_render(
    &self.ambient,
    &self.main_render_target[g_frame_index],
    command_buffer,
  )
  ambient_end(command_buffer)
  // Per-light additive pass
  lighting_begin(
    &self.main,
    self.main_render_target[g_frame_index],
    command_buffer,
  )
  lighting_render(
    &self.main,
    lights,
    &self.main_render_target[g_frame_index],
    command_buffer,
  )
  lighting_end(command_buffer)
  // log.debug("============ rendering particles... =============")
  particle_begin(
    &self.particle,
    command_buffer,
    self.main_render_target[g_frame_index],
  )
  particle_render(
    &self.particle,
    command_buffer,
    self.main_render_target[g_frame_index].camera.index,
  )
  particle_end(command_buffer)

  // Transparent & wireframe pass
  transparent_begin(
    &self.transparent,
    self.main_render_target[g_frame_index],
    command_buffer,
  )
  transparent_render(
    &self.transparent,
    gbuffer_input,
    self.main_render_target[g_frame_index],
    command_buffer,
  )
  transparent_end(&self.transparent, command_buffer)
  // log.debug("============ rendering post processes... =============")
  transition_image_to_shader_read(command_buffer, final_image.image)
  postprocess_begin(
    &self.postprocess,
    command_buffer,
    self.swapchain.extent,
  )
  transition_image(
    command_buffer,
    self.swapchain.images[self.swapchain.image_index],
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {.COLOR},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {},
    {.COLOR_ATTACHMENT_WRITE},
  )
  postprocess_render(
    &self.postprocess,
    command_buffer,
    self.swapchain.extent,
    self.swapchain.views[self.swapchain.image_index],
    &self.main_render_target[g_frame_index],
  )
  postprocess_end(&self.postprocess, command_buffer)
  if mu.window(&self.ui.ctx, "Engine", {40, 40, 300, 200}, {.NO_CLOSE}) {
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
        len(g_image_2d_buffers.entries) - len(g_image_2d_buffers.free_indices),
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

    // Show visibility statistics for main camera
    when USE_GPU_CULLING {
      disabled, visible, total := multi_camera_count_visible_objects(
        &self.visibility_culler,
        0,
      )
      mu.label(
        &self.ui.ctx,
        fmt.tprintf("Main Cam: %d/%d visible", visible, total),
      )
      if disabled > 0 {
        mu.label(&self.ui.ctx, fmt.tprintf("Culling disabled: %d", disabled))
      }
    }
  }
  if self.render2d_proc != nil {
    self.render2d_proc(self, &self.ui.ctx)
  }
  mu.end(&self.ui.ctx)
  // log.debug("============ rendering UI... =============")
  ui_begin(
    &self.ui,
    command_buffer,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
  )
  ui_render(&self.ui, command_buffer)
  ui_end(&self.ui, command_buffer)
  // log.debug("============ preparing image for present... =============")
  transition_image_to_present(
    command_buffer,
    self.swapchain.images[self.swapchain.image_index],
  )
  vk.EndCommandBuffer(command_buffer) or_return
  // log.debug("============ submit queue... =============")
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
  for !glfw.WindowShouldClose(self.window) {
    // DEBUG: engine is not stable, only render 1 or some few frames first
    // if frame > 0 do break
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
