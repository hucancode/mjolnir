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
CustomRenderProc :: #type proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
)

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

// GPU data structure for shader push constants
// 128 bytes budget
LightPushConstant :: struct {
  scene_camera_idx:       u32,
  light_camera_idx:       u32, // for shadow mapping
  shadow_map_id:          u32,
  light_kind:             LightKind,
  light_color:            [3]f32,
  light_angle:            f32,
  light_position:         [3]f32,
  light_radius:           f32,
  light_direction:        [3]f32,
  light_cast_shadow:      b32,
  gbuffer_position_index: u32,
  gbuffer_normal_index:   u32,
  gbuffer_albedo_index:   u32,
  gbuffer_metallic_index: u32,
  gbuffer_emissive_index: u32,
  gbuffer_depth_index:    u32,
  input_image_index:      u32,
}

// Shadow resource management for persistent caching
ShadowResources :: struct {
  // Point light resources (6 cube faces)
  cube_render_targets: [6]Handle,
  cube_cameras:        [6]Handle,
  shadow_map:          Handle,
  // Spot/Directional light resources
  render_target:       Handle,
  camera:              Handle,
  // Cached across frames
  allocated:           bool,
}

// Unified light structure with embedded GPU data
LightInfo :: struct {
  using gpu_data:         LightPushConstant, // Direct access to all GPU fields
  // CPU management data
  node_handle:            Handle,
  transform_generation:   u64, // For change tracking
  using shadow_resources: ShadowResources, // Persistent shadow data
  dirty:                  bool,
}

Engine :: struct {
  window:                      glfw.WindowHandle,
  swapchain:                   Swapchain,
  scene:                       Scene,
  last_frame_timestamp:        time.Time,
  last_update_timestamp:       time.Time,
  start_timestamp:             time.Time,
  input:                       InputState,
  setup_proc:                  SetupProc,
  update_proc:                 UpdateProc,
  render2d_proc:               Render2DProc,
  key_press_proc:              KeyInputProc,
  mouse_press_proc:            MousePressProc,
  mouse_drag_proc:             MouseDragProc,
  mouse_move_proc:             MouseMoveProc,
  mouse_scroll_proc:           MouseScrollProc,
  custom_render_proc:          CustomRenderProc,
  render_error_count:          u32,
  visibility_culler:           VisibilityCuller,
  shadow:                      RendererShadow,
  depth_prepass:               RendererDepthPrepass,
  gbuffer:                     RendererGBuffer,
  ambient:                     RendererAmbient,
  lighting:                    RendererLighting,
  particle:                    RendererParticle,
  transparent:                 RendererTransparent,
  postprocess:                 RendererPostProcess,
  ui:                          RendererUI,
  command_buffers:             [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  cursor_pos:                  [2]i32,
  // Main render target for primary rendering
  main_render_target:          Handle,
  // Engine-managed shadow maps
  shadow_maps:                 [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  cube_shadow_maps:            [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  // Persistent shadow render targets
  shadow_render_targets:       [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  cube_shadow_render_targets:  [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS][6]Handle,
  // Light management with pre-allocated pools
  lights:                      [256]LightInfo, // Pre-allocated light pool
  active_light_count:          u32, // Number of currently active lights
  // Current frame's active render targets (for custom render procs to use correct visibility data)
  frame_active_render_targets: []RenderTarget,
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
      // Create shadow maps
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

      // Create persistent render targets for spot/directional lights
      render_target: ^RenderTarget
      engine.shadow_render_targets[f][i], render_target = resource.alloc(
        &g_render_targets,
      )
      render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
      // Set depth texture for all frames to the same shadow map for this frame
      for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
        render_target.depth_textures[frame_idx] = engine.shadow_maps[f][i]
      }
      render_target.owns_depth_texture = false

      // Create persistent render targets for point lights (6 cube faces)
      for face in 0 ..< 6 {
        cube_render_target: ^RenderTarget
        engine.cube_shadow_render_targets[f][i][face], cube_render_target =
          resource.alloc(&g_render_targets)
        cube_render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
        // Set depth texture for all frames to the same cube shadow map for this frame
        for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
          cube_render_target.depth_textures[frame_idx] =
            engine.cube_shadow_maps[f][i]
        }
        cube_render_target.owns_depth_texture = false
      }
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
  uniform.view, uniform.projection = geometry.camera_calculate_matrices(
    camera^,
  )
  uniform.viewport_size = [2]f32{f32(viewport_width), f32(viewport_height)}
  uniform.camera_position = camera.position
  uniform.camera_near, uniform.camera_far = geometry.camera_get_near_far(
    camera^,
  )
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

  // Initialize main render target with default camera settings
  main_render_target: ^RenderTarget
  self.main_render_target, main_render_target = resource.alloc(
    &g_render_targets,
  )
  render_target_init(
    main_render_target,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
    .D32_SFLOAT,
    {5, 8, 5}, // Camera slightly above and diagonal to origin
    {0, 0, 0}, // Looking at origin
  ) or_return
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
    &self.lighting,
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
  // Environment resources will be moved to ambient pass
  gbuffer_init(
    &self.gbuffer,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  depth_prepass_init(&self.depth_prepass, self.swapchain.extent) or_return
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
        visible = is_node_visible(&self.visibility_culler, 0, u32(entry_index))
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

// Get main camera from the main render target for the current frame
get_main_camera :: proc(engine: ^Engine) -> ^geometry.Camera {
  main_render_target := resource.get(
    g_render_targets,
    engine.main_render_target,
  )
  if main_render_target == nil {
    return nil
  }
  return resource.get(g_cameras, main_render_target.camera)
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
  // Clean up main render target
  if main_render_target := resource.get(
    g_render_targets,
    self.main_render_target,
  ); main_render_target != nil {
    resource.free(
      &g_render_targets,
      self.main_render_target,
      render_target_deinit,
    )
  }

  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    // Clean up persistent shadow render targets
    for j in 0 ..< MAX_SHADOW_MAPS {
      resource.free(&g_render_targets, self.shadow_render_targets[i][j])
      for face in 0 ..< 6 {
        resource.free(
          &g_render_targets,
          self.cube_shadow_render_targets[i][j][face],
        )
      }
    }
  }
  ui_deinit(&self.ui)
  scene_deinit(&self.scene)
  lighting_deinit(&self.lighting)
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
  if main_camera := get_main_camera(engine); main_camera != nil {
    geometry.camera_update_aspect_ratio(main_camera, new_aspect_ratio)
  }

  // Recreate main render target with new dimensions
  if main_render_target := resource.get(
    g_render_targets,
    engine.main_render_target,
  ); main_render_target != nil {
    // Save current camera state
    old_camera := resource.get(g_cameras, main_render_target.camera)
    old_position :=
      old_camera.position if old_camera != nil else [3]f32{0, 0, 3}
    old_target := [3]f32{0, 0, 0} // Calculate from camera direction if needed

    render_target_deinit(main_render_target)
    render_target_init(
      main_render_target,
      engine.swapchain.extent.width,
      engine.swapchain.extent.height,
      engine.swapchain.format.format,
      .D32_SFLOAT,
      old_position, // Preserve camera position
      old_target, // Preserve camera target
    ) or_return
  }

  // No need to update camera uniform descriptor sets with bindless cameras

  lighting_recreate_images(
    &engine.lighting,
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
  active_render_targets: []RenderTarget = {},
  shadow_pass: bool = false,
) -> (
  ret: RenderInput,
) {
  // Use frame active render targets by default, or provided targets for shadow passes
  targets :=
    active_render_targets if len(active_render_targets) > 0 else self.frame_active_render_targets
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
        // Find the correct camera slot for this camera handle
        camera_slot, slot_found := find_camera_slot(camera_handle, targets)
        if slot_found {
          visible = is_node_visible(&self.visibility_culler, camera_slot, u32(entry_index))
        } else {
          // Fall back to CPU culling if camera slot not found
          world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
          visible = geometry.frustum_test_aabb(frustum, world_aabb)
        }
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
  main_render_target := resource.get(g_render_targets, self.main_render_target)
  if main_render_target == nil {
    log.errorf("Main render target not found")
    return .ERROR_UNKNOWN
  }
  render_target_update_camera_uniform(main_render_target)

  main_camera := get_main_camera(self)
  if main_camera == nil {
    log.errorf("Main camera not found")
    return .ERROR_UNKNOWN
  }
  main_camera_index := main_render_target.camera.index
  camera_uniform := get_camera_uniform(main_camera_index)
  frustum := geometry.make_frustum(
    camera_uniform.projection * camera_uniform.view,
  )
  // log.debug("============ collecting lights ...============ ")
  // Reset active light count for this frame
  self.active_light_count = 0
  shadow_map_count := 0
  cube_shadow_map_count := 0
  // Cleanup shadow camera resources at end of frame
  defer {
    for i in 0 ..< self.active_light_count {
      light_info := &self.lights[i]
      if !light_info.light_cast_shadow do continue

      switch light_info.light_kind {
      case .POINT:
        for camera_handle in light_info.cube_cameras {
          if camera_handle.generation != 0 {
            resource.free(&g_cameras, camera_handle)
          }
        }
      case .SPOT:
        if light_info.camera.generation != 0 {
          resource.free(&g_cameras, light_info.shadow_resources.camera)
        }
      case .DIRECTIONAL:
      // TODO: Add when directional shadows are implemented
      }

      // Clear allocated flag for next frame
      light_info.shadow_resources.allocated = false
    }
  }
  for &entry, entry_index in self.scene.nodes.entries do if entry.active {
    node := &entry.item
    when USE_GPU_CULLING {
      visible := is_node_visible(&self.visibility_culler, 0, u32(entry_index))
      if !visible do continue
    } else {
      // TODO: do CPU culling for light node here
    }
    // Check if we have room for more lights
    if self.active_light_count >= len(self.lights) do continue

    #partial switch &attachment in &node.attachment {
    case PointLightAttachment:
      light_info := &self.lights[self.active_light_count]
      // Fill GPU data directly via embedded struct
      position := node.transform.world_matrix * [4]f32{0, 0, 0, 1}
      light_info.light_kind = .POINT
      light_info.light_color = attachment.color.xyz
      light_info.light_position = position.xyz
      light_info.light_radius = attachment.radius
      light_info.light_cast_shadow = b32(attachment.cast_shadow && cube_shadow_map_count < MAX_SHADOW_MAPS)

      // Set up shadow mapping if needed
      if light_info.light_cast_shadow {
        light_info.shadow_map_id = self.cube_shadow_maps[g_frame_index][cube_shadow_map_count].index
        light_info.shadow_map = self.cube_shadow_maps[g_frame_index][cube_shadow_map_count]
        cube_shadow_map_count += 1

        // Use persistent render targets and create temporary cameras
        light_info.cube_render_targets = self.cube_shadow_render_targets[g_frame_index][cube_shadow_map_count - 1]

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
          // Get persistent render target for this cube face
          render_target := resource.get(g_render_targets, light_info.cube_render_targets[i])

          // Allocate camera for this cube face
          camera: ^geometry.Camera
          light_info.cube_cameras[i], camera = resource.alloc(&g_cameras)
          camera^ = geometry.make_camera_perspective(math.PI * 0.5, 1.0, 0.1, light_info.light_radius)

          // Associate camera with render target BEFORE updating uniform
          render_target.camera = light_info.cube_cameras[i]

          // Set camera position and orientation for this cube face
          target_pos := position.xyz + face_dirs[i]
          geometry.camera_look_at(camera, position.xyz, target_pos, face_ups[i])
          render_target_update_camera_uniform(render_target)
        }

        // Use first cube camera for light_camera_idx
        light_info.light_camera_idx = light_info.cube_cameras[0].index
      } else {
        light_info.light_camera_idx = 0 // No shadow camera for this light
      }

      self.active_light_count += 1

    case DirectionalLightAttachment:
      light_info := &self.lights[self.active_light_count]

      // Fill GPU data directly
      direction := node.transform.world_matrix * [4]f32{0, 0, -1, 0}
      light_info.light_kind = .DIRECTIONAL
      light_info.light_color = attachment.color.xyz
      light_info.light_direction = direction.xyz
      light_info.light_cast_shadow = b32(attachment.cast_shadow)
      light_info.light_camera_idx = 0 // Directional lights don't need a specific camera

      self.active_light_count += 1

    case SpotLightAttachment:
      light_info := &self.lights[self.active_light_count]

      // Fill GPU data directly
      position := node.transform.world_matrix * [4]f32{0, 0, 0, 1}
      direction := node.transform.world_matrix * [4]f32{0, -1, 0, 0}
      light_info.light_kind = .SPOT
      light_info.light_color = attachment.color.xyz
      light_info.light_position = position.xyz
      light_info.light_direction = direction.xyz
      light_info.light_radius = attachment.radius
      light_info.light_angle = attachment.angle
      light_info.light_cast_shadow = b32(attachment.cast_shadow) && shadow_map_count < MAX_SHADOW_MAPS

      // Set up shadow mapping if needed
      if light_info.light_cast_shadow {
        light_info.shadow_map_id = self.shadow_maps[g_frame_index][shadow_map_count].index
        light_info.shadow_map = self.shadow_maps[g_frame_index][shadow_map_count]
        shadow_map_count += 1

        // Use persistent render target and create temporary camera
        light_info.render_target = self.shadow_render_targets[g_frame_index][shadow_map_count - 1]
        render_target := resource.get(g_render_targets, light_info.render_target)

        // Allocate camera for spot light
        camera: ^geometry.Camera
        light_info.camera, camera = resource.alloc(&g_cameras)
        camera^ = geometry.make_camera_perspective(light_info.light_angle * 2.0, 1.0, 0.1, light_info.light_radius)

        // Associate camera with render target BEFORE updating uniform
        render_target.camera = light_info.camera

        // Set camera to look in the direction of the light
        target_pos := position.xyz + direction.xyz
        geometry.camera_look_at(camera, position.xyz, target_pos)
        render_target_update_camera_uniform(render_target)

        light_info.light_camera_idx = light_info.camera.index
      } else {
        light_info.light_camera_idx = 0 // No shadow camera for this light
      }

      self.active_light_count += 1
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
    append(&active_render_targets, main_render_target^)

    // Add shadow map render targets from shadow-casting lights
    for light_info in self.lights[:self.active_light_count] {
      if !light_info.light_cast_shadow do continue

      switch light_info.light_kind {
      case .POINT:
        for target_handle in light_info.cube_render_targets {
          if target := resource.get(g_render_targets, target_handle);
             target != nil {
            append(&active_render_targets, target^)
          }
        }
      case .SPOT:
        if target := resource.get(g_render_targets, light_info.render_target);
           target != nil {
          append(&active_render_targets, target^)
        }
      case .DIRECTIONAL:
      // TODO: Add when directional shadows are implemented
      }
    }

    // Add all other active user render targets from global pool
    for &entry in g_render_targets.entries {
      if !entry.active do continue
      target := &entry.item

      // Skip if already added (main camera or shadow cameras)
      already_added := false
      for existing_target in active_render_targets {
        if existing_target.camera.index == target.camera.index {
          already_added = true
          break
        }
      }

      if !already_added {
        append(&active_render_targets, target^)
      }
    }

    // Store active render targets for custom render procs to use
    self.frame_active_render_targets = active_render_targets[:]

    // Update and perform GPU scene culling
    visibility_culler_update(
      &self.visibility_culler,
      &self.scene,
      active_render_targets[:],
    )
    visibility_culler_execute(&self.visibility_culler, command_buffer)

    // Memory barrier to ensure culling is complete before other operations
    visibility_buffer_barrier := vk.BufferMemoryBarrier {
      sType               = .BUFFER_MEMORY_BARRIER,
      srcAccessMask       = {.SHADER_WRITE},
      dstAccessMask       = {.SHADER_READ, .HOST_READ},
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      buffer              = self.visibility_culler.visibility_buffer[g_frame_index].buffer,
      offset              = 0,
      size                = vk.DeviceSize(
        self.visibility_culler.visibility_buffer[g_frame_index].bytes_count,
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
    // CPU culling mode - no visibility culler operations needed
    // Culling will be done per-object in generate_render_input using CPU frustum tests
    // Still need to provide an empty array for custom render procs
    self.frame_active_render_targets = {}
  }

  compute_particles(&self.particle, command_buffer, main_camera^)

  // Call custom render proc if provided (for user-defined render targets)
  // This happens AFTER visibility culling so portal cameras have fresh visibility data
  if self.custom_render_proc != nil {
    self.custom_render_proc(self, command_buffer)
  }

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
  // Shadow rendering for shadow-casting lights
  current_camera_slot: u32 = 1 // Start from slot 1 (slot 0 is main camera)
  for light_info, i in self.lights[:self.active_light_count] {
    if !light_info.light_cast_shadow do continue
    // log.debugf("Processing shadow caster %d", i)
    switch light_info.light_kind {
    case .POINT:
      // log.debugf("Processing point light %d", i)
      if light_info.shadow_map.generation == 0 {
        log.errorf("Point light %d has invalid shadow map handle", i)
        continue
      }
      for face in 0 ..< 6 {
        camera_uniform := get_camera_uniform(
          light_info.cube_cameras[face].index,
        )
        frustum := geometry.make_frustum(
          camera_uniform.projection * camera_uniform.view,
        )
        target := resource.get(
          g_render_targets,
          light_info.cube_render_targets[face],
        )
        // Create render targets array for this cube face shadow camera
        cube_face_targets := [1]RenderTarget{target^}
        shadow_render_input := generate_render_input(
          self,
          frustum,
          light_info.cube_cameras[face],
          cube_face_targets[:],
          shadow_pass = true,
        )
        shadow_begin(target, command_buffer, u32(face))
        shadow_render(
          &self.shadow,
          shadow_render_input,
          light_info,
          target^,
          command_buffer,
        )
        shadow_end(command_buffer)
        current_camera_slot += 1
      }
    case .DIRECTIONAL:
    // TODO: Implement directional light shadows
    case .SPOT:
      if light_info.shadow_map.generation == 0 {
        log.errorf("Spot light %d has invalid shadow map handle", i)
        continue
      }
      camera_uniform := get_camera_uniform(light_info.camera.index)
      frustum := geometry.make_frustum(
        camera_uniform.projection * camera_uniform.view,
      )
      shadow_target := resource.get(g_render_targets, light_info.render_target)
      // Create render targets array for this spot light shadow camera
      spot_light_targets := [1]RenderTarget{shadow_target^}
      shadow_render_input := generate_render_input(
        self,
        frustum,
        light_info.camera,
        spot_light_targets[:],
        shadow_pass = true,
      )
      shadow_begin(shadow_target, command_buffer)
      shadow_render(
        &self.shadow,
        shadow_render_input,
        light_info,
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
    render_target_final_image(main_render_target),
  )
  // Final image transition is now handled by gbuffer_begin
  // Get depth texture for transitions
  gbuffer_depth := resource.get(
    g_image_2d_buffers,
    render_target_depth_texture(main_render_target),
  )
  // Transition depth texture to DEPTH_STENCIL_ATTACHMENT_OPTIMAL for depth prepass
  transition_image(
    command_buffer,
    gbuffer_depth.image,
    .UNDEFINED,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    {.DEPTH},
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
  )
  // log.debug("============ rendering depth pre-pass... =============")
  // For depth prepass, use frame active render targets for visibility culling
  depth_input := generate_render_input(
    self,
    frustum,
    main_render_target.camera,
  )
  depth_prepass_begin(main_render_target, command_buffer)
  depth_prepass_render(
    &self.depth_prepass,
    &depth_input,
    command_buffer,
    main_render_target.camera.index,
  )
  depth_prepass_end(command_buffer)
  // log.debug("============ rendering G-buffer pass... =============")
  // G-buffer image transitions are now handled by gbuffer_begin/end
  gbuffer_input := depth_input
  gbuffer_begin(main_render_target, command_buffer)
  gbuffer_render(
    &self.gbuffer,
    &gbuffer_input,
    main_render_target,
    command_buffer,
  )
  gbuffer_end(main_render_target, command_buffer)
  // G-buffer to shader read transition is now handled by gbuffer_end
  // Transition depth texture to SHADER_READ_ONLY_OPTIMAL for use in post-processing
  transition_image(
    command_buffer,
    gbuffer_depth.image,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.DEPTH},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
  )
  // log.debug("============ rendering main pass... =============")
  // Prepare RenderTarget and RenderInput for decoupled renderer
  // Ambient pass
  ambient_begin(&self.ambient, main_render_target, command_buffer)
  ambient_render(&self.ambient, main_render_target, command_buffer)
  ambient_end(command_buffer)
  // Per-light additive pass
  lighting_begin(&self.lighting, main_render_target, command_buffer)
  lighting_render(
    &self.lighting,
    self.lights[:self.active_light_count],
    main_render_target,
    command_buffer,
  )
  lighting_end(command_buffer)
  // log.debug("============ rendering particles... =============")
  particle_begin(&self.particle, command_buffer, main_render_target)
  particle_render(
    &self.particle,
    command_buffer,
    main_render_target.camera.index,
  )
  particle_end(command_buffer)

  // Transparent & wireframe pass
  transparent_begin(&self.transparent, main_render_target, command_buffer)
  transparent_render(
    &self.transparent,
    gbuffer_input,
    main_render_target,
    command_buffer,
  )
  transparent_end(&self.transparent, command_buffer)
  // log.debug("============ rendering post processes... =============")
  transition_image_to_shader_read(command_buffer, final_image.image)
  postprocess_begin(&self.postprocess, command_buffer, self.swapchain.extent)
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
    main_render_target,
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
      disabled, visible, total := count_visible_objects(
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
