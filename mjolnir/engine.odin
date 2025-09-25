package mjolnir

import "animation"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "geometry"
import "gpu"
import "resources"
import "navigation/recast"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2
RENDER_FPS :: 60.0
FRAME_TIME :: 1.0 / RENDER_FPS
FRAME_TIME_MILIS :: FRAME_TIME * 1_000.0
UPDATE_FPS :: 30.0
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
USE_PARALLEL_UPDATE :: true // Set to false to disable threading for debugging

Handle :: resources.Handle

g_context: runtime.Context

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

UpdateThreadData :: struct {
  engine: ^Engine,
}

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
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
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
  gpu_context:                 gpu.GPUContext,
  resource_manager:            resources.Manager,
  frame_index:                 u32,
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
  gbuffer:                     RendererGBuffer,
  ambient:                     RendererAmbient,
  lighting:                    RendererLighting,
  particle:                    RendererParticle,
  transparent:                 RendererTransparent,
  postprocess:                 RendererPostProcess,
  ui:                          RendererUI,
  navmesh:                     RendererNavMesh,
  command_buffers:             [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  gbuffer_command_buffers:     [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  shadow_pass_command_buffers:   [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  lighting_command_buffers:      [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  transparency_command_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  postprocess_command_buffers:   [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  cursor_pos:                  [2]i32,
  // Main render target for primary rendering
  main_render_target:          Handle,
  // Engine-managed shadow maps
  shadow_maps:                 [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  cube_shadow_maps:            [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  // Persistent shadow render targets
  shadow_render_targets:       [MAX_SHADOW_MAPS]Handle,
  cube_shadow_render_targets:  [MAX_SHADOW_MAPS][6]Handle,
  // Light management with pre-allocated pools
  lights:                      [256]LightInfo, // Pre-allocated light pool
  active_light_count:          u32, // Number of currently active lights
  // Current frame's active render targets (for custom render procs to use correct visibility data)
  frame_active_render_targets: [dynamic]Handle,
  // Deferred cleanup for thread safety
  pending_node_deletions:      [dynamic]Handle,
  // Frame synchronization for parallel update/render
  frame_fence:                 vk.Fence,
  update_thread:               Maybe(^thread.Thread),
  update_active:               bool,
  last_render_timestamp:       time.Time,
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
@(private = "file")
engine_init_shadow_maps :: proc(engine: ^Engine) -> vk.Result {
  for f in 0 ..< MAX_FRAMES_IN_FLIGHT {
    for i in 0 ..< MAX_SHADOW_MAPS {
      // Create shadow maps
      engine.shadow_maps[f][i], _, _ = resources.create_texture(
        &engine.gpu_context,
        &engine.resource_manager,
        SHADOW_MAP_SIZE,
        SHADOW_MAP_SIZE,
        vk.Format.D32_SFLOAT,
        vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      )
      engine.cube_shadow_maps[f][i], _, _ = resources.create_cube_texture(
        &engine.gpu_context,
        &engine.resource_manager,
        SHADOW_MAP_SIZE,
        vk.Format.D32_SFLOAT,
        vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      )
    }
    log.debugf("Created new 2D shadow maps %v", engine.shadow_maps[f])
    log.debugf("Created new cube shadow maps %v", engine.cube_shadow_maps[f])
  }

  for i in 0 ..< MAX_SHADOW_MAPS {
    // Create persistent render targets for spot/directional lights
    render_target: ^resources.RenderTarget
    engine.shadow_render_targets[i], render_target = resources.alloc(
      &engine.resource_manager.render_targets,
    )
    render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
    // Set depth texture for all frames to the appropriate shadow map
    for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
      render_target.depth_textures[frame_idx] =
        engine.shadow_maps[frame_idx][i]
    }
    render_target.features = {.DEPTH_TEXTURE}
    // Create persistent render targets for point lights (6 cube faces)
    for face in 0 ..< 6 {
      cube_render_target: ^resources.RenderTarget
      engine.cube_shadow_render_targets[i][face], cube_render_target =
        resources.alloc(&engine.resource_manager.render_targets)
      cube_render_target.extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
      // Set depth texture for all frames to the appropriate cube shadow map
      for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
        cube_render_target.depth_textures[frame_idx] =
          engine.cube_shadow_maps[frame_idx][i]
      }
      cube_render_target.features = {.DEPTH_TEXTURE}
    }
  }
  return .SUCCESS
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
  gpu.gpu_context_init(&self.gpu_context, self.window) or_return
  resources.init(&self.resource_manager, &self.gpu_context) or_return
  self.start_timestamp = time.now()
  self.last_frame_timestamp = self.start_timestamp
  self.last_update_timestamp = self.start_timestamp
  scene_init(&self.scene)
  swapchain_init(&self.swapchain, &self.gpu_context, self.window) or_return

  // Initialize frame active render targets
  self.frame_active_render_targets = make([dynamic]Handle, 0)

  // Initialize deferred cleanup
  self.pending_node_deletions = make([dynamic]Handle, 0)

  // Create fence for frame synchronization
  vk.CreateFence(
    self.gpu_context.device,
    &vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO},
    nil,
    &self.frame_fence,
  ) or_return

  // Initialize engine shadow map pools
  engine_init_shadow_maps(self) or_return

  // Initialize main render target with default camera settings
  main_render_target: ^resources.RenderTarget
  self.main_render_target, main_render_target = resources.alloc(
    &self.resource_manager.render_targets,
  )
  resources.render_target_init(
    main_render_target,
    &self.gpu_context,
    &self.resource_manager,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
    .D32_SFLOAT,
    {
      .FINAL_IMAGE,
      .POSITION_TEXTURE,
      .NORMAL_TEXTURE,
      .ALBEDO_TEXTURE,
      .METALLIC_ROUGHNESS,
      .EMISSIVE_TEXTURE,
      .DEPTH_TEXTURE,
    },
    {5, 8, 5}, // Camera slightly above and diagonal to origin
    {0, 0, 0}, // Looking at origin
  ) or_return
  vk.AllocateCommandBuffers(
    self.gpu_context.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = self.gpu_context.command_pool,
      level = .PRIMARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.command_buffers[:]),
  ) or_return

  vk.AllocateCommandBuffers(
    self.gpu_context.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = self.gpu_context.command_pool,
      level = .SECONDARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.gbuffer_command_buffers[:]),
  ) or_return
  vk.AllocateCommandBuffers(
    self.gpu_context.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = self.gpu_context.command_pool,
      level = .SECONDARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.shadow_pass_command_buffers[:]),
  ) or_return
  vk.AllocateCommandBuffers(
    self.gpu_context.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = self.gpu_context.command_pool,
      level = .SECONDARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.lighting_command_buffers[:]),
  ) or_return
  vk.AllocateCommandBuffers(
    self.gpu_context.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = self.gpu_context.command_pool,
      level = .SECONDARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.transparency_command_buffers[:]),
  ) or_return
  vk.AllocateCommandBuffers(
    self.gpu_context.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = self.gpu_context.command_pool,
      level = .SECONDARY,
      commandBufferCount = MAX_FRAMES_IN_FLIGHT,
    },
    raw_data(self.postprocess_command_buffers[:]),
  ) or_return
  lighting_init(
    &self.lighting,
    &self.gpu_context,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
    vk.Format.D32_SFLOAT,
    &self.resource_manager,
  ) or_return
  ambient_init(
    &self.ambient,
    &self.gpu_context,
    &self.resource_manager,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
  ) or_return
  // Environment resources will be moved to ambient pass
  gbuffer_init(
    &self.gbuffer,
    &self.gpu_context,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    &self.resource_manager,
  ) or_return
  depth_prepass_init(
    &self.gbuffer,
    &self.gpu_context,
    self.swapchain.extent,
    &self.resource_manager,
  ) or_return
  particle_init(&self.particle, &self.gpu_context, &self.resource_manager) or_return
  visibility_culler_init(
    &self.visibility_culler,
    &self.gpu_context,
    &self.resource_manager,
  ) or_return
  transparent_init(
    &self.transparent,
    &self.gpu_context,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    &self.resource_manager,
  ) or_return
  log.debugf("initializing shadow pipeline")
  shadow_init(
    &self.shadow,
    &self.gpu_context,
    &self.resource_manager,
  ) or_return
  log.debugf("initializing post process pipeline")
  postprocess_init(
    &self.postprocess,
    &self.gpu_context,
    self.swapchain.format.format,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    &self.resource_manager,
  ) or_return
  log.debugf("initializing navigation mesh renderer")
  navmesh_init(&self.navmesh, &self.gpu_context, &self.resource_manager) or_return
  ui_init(
    &self.ui,
    &self.gpu_context,
    self.swapchain.format.format,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    get_window_dpi(self.window),
    &self.resource_manager,
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

time_since_start :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.start_timestamp)))
}

@(private = "file")
update_emitters :: proc(self: ^Engine, delta_time: f32) {
  params := gpu.data_buffer_get(&self.particle.params_buffer)
  params.delta_time = delta_time
  emitters_ptr := gpu.data_buffer_get(&self.resource_manager.emitter_buffer)
  emitters := slice.from_ptr(emitters_ptr, MAX_EMITTERS)

  scene_emitters_sync(&self.scene, &self.resource_manager, emitters, params)
}

get_main_camera :: proc(engine: ^Engine) -> ^geometry.Camera {
  target, ok := resources.get_render_target(&engine.resource_manager, engine.main_render_target)
  if !ok {
    return nil
  }
  camera_ptr, camera_found := resources.get_camera(&engine.resource_manager, target.camera)
  if !camera_found {
    return nil
  }
  return camera_ptr
}

@(private = "file")
update_force_fields :: proc(self: ^Engine) {
  params := gpu.data_buffer_get(&self.particle.params_buffer)
  params.forcefield_count = 0
  forcefields := slice.from_ptr(
    self.particle.force_field_buffer.mapped,
    MAX_FORCE_FIELDS,
  )
  for &entry in self.scene.nodes.entries do if entry.active {
    ff, is_ff := &entry.item.attachment.(ForceFieldAttachment)
    if !is_ff do continue
    forcefields[params.forcefield_count].position = get_world_matrix(&entry.item) * [4]f32{0, 0, 0, 1}
    forcefields[params.forcefield_count].tangent_strength = ff.tangent_strength
    forcefields[params.forcefield_count].strength = ff.strength
    forcefields[params.forcefield_count].area_of_effect = ff.area_of_effect
    forcefields[params.forcefield_count].fade = ff.fade
    params.forcefield_count += 1
  }
}

// Main thread input handling - only GLFW and input operations
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
  scene_traverse(&self.scene)
  // Animation updates are now handled in render thread for smooth animation at render FPS
  update_emitters(self, delta_time)
  update_force_fields(self)
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
  }
  self.last_update_timestamp = time.now()
  return true
}

deinit :: proc(self: ^Engine) {
  vk.DeviceWaitIdle(self.gpu_context.device)
  free_command_buffers :: proc(device: vk.Device, pool: vk.CommandPool, buffers: []vk.CommandBuffer) {
    vk.FreeCommandBuffers(device, pool, u32(len(buffers)), raw_data(buffers[:]))
  }
  free_command_buffers(self.gpu_context.device, self.gpu_context.command_pool, self.command_buffers[:])
  free_command_buffers(self.gpu_context.device, self.gpu_context.command_pool, self.gbuffer_command_buffers[:])
  free_command_buffers(self.gpu_context.device, self.gpu_context.command_pool, self.shadow_pass_command_buffers[:])
  free_command_buffers(self.gpu_context.device, self.gpu_context.command_pool, self.lighting_command_buffers[:])
  free_command_buffers(self.gpu_context.device, self.gpu_context.command_pool, self.transparency_command_buffers[:])
  free_command_buffers(self.gpu_context.device, self.gpu_context.command_pool, self.postprocess_command_buffers[:])
  if item, freed := resources.free(
    &self.resource_manager.render_targets,
    self.main_render_target,
  ); freed {
    resources.render_target_deinit(item, &self.gpu_context, &self.resource_manager)
  }
  for j in 0 ..< MAX_SHADOW_MAPS {
    resources.free(
      &self.resource_manager.render_targets,
      self.shadow_render_targets[j],
    )
    for face in 0 ..< 6 {
      resources.free(
        &self.resource_manager.render_targets,
        self.cube_shadow_render_targets[j][face],
      )
    }
  }
  delete(self.frame_active_render_targets)
  delete(self.pending_node_deletions)
  vk.DestroyFence(self.gpu_context.device, self.frame_fence, nil)
  ui_deinit(&self.ui, &self.gpu_context)
  navmesh_deinit(&self.navmesh, &self.gpu_context)
  scene_deinit(&self.scene, &self.resource_manager)
  lighting_deinit(&self.lighting, &self.gpu_context)
  ambient_deinit(&self.ambient, &self.gpu_context, &self.resource_manager)
  gbuffer_deinit(&self.gbuffer, &self.gpu_context)
  shadow_deinit(&self.shadow, &self.gpu_context)
  postprocess_deinit(&self.postprocess, &self.gpu_context, &self.resource_manager)
  particle_deinit(&self.particle, &self.gpu_context)
  visibility_culler_deinit(&self.visibility_culler, &self.gpu_context)
  transparent_deinit(&self.transparent, &self.gpu_context)
  resources.shutdown(&self.resource_manager, &self.gpu_context)
  swapchain_deinit(&self.swapchain, &self.gpu_context)
  gpu.gpu_context_deinit(&self.gpu_context)
  glfw.DestroyWindow(self.window)
  glfw.Terminate()
  log.infof("Engine deinitialized")
}

@(private = "file")
record_shadow_pass :: proc(
  self: ^Engine,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  shadow_include := resources.NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
  shadow_exclude := resources.NodeFlagSet{
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
  }

  for &light_info, light_index in self.lights[:self.active_light_count] {
    if !light_info.light_cast_shadow do continue

    switch light_info.light_kind {
    case .POINT:
      if light_info.shadow_map.generation == 0 {
        log.errorf("Point light %d has invalid shadow map handle", light_index)
        continue
      }
      for face in 0 ..< 6 {
        target := resources.get(
          self.resource_manager.render_targets,
          light_info.cube_render_targets[face],
        )
        if target == nil do continue
        visibility_culler_dispatch(
          &self.visibility_culler,
          &self.gpu_context,
          command_buffer,
          self.frame_index,
          light_info.cube_cameras[face].index,
          shadow_include,
          shadow_exclude,
        )
        shadow_draw_buffer := visibility_culler_command_buffer(
          &self.visibility_culler,
          self.frame_index,
        )
        shadow_draw_count := visibility_culler_max_draw_count(
          &self.visibility_culler,
        )
        shadow_begin(
          target,
          command_buffer,
          &self.resource_manager,
          self.frame_index,
          u32(face),
        )
        shadow_render(
          &self.shadow,
          target^,
          command_buffer,
          &self.resource_manager,
          self.frame_index,
          shadow_draw_buffer,
          shadow_draw_count,
        )
        shadow_end(
          command_buffer,
          target,
          &self.resource_manager,
          self.frame_index,
          u32(face),
        )
      }
    case .SPOT:
      if light_info.shadow_map.generation == 0 {
        log.errorf("Spot light %d has invalid shadow map handle", light_index)
        continue
      }
      shadow_target := resources.get(
        self.resource_manager.render_targets,
        light_info.render_target,
      )
      if shadow_target == nil do continue

      visibility_culler_dispatch(
        &self.visibility_culler,
        &self.gpu_context,
        command_buffer,
        self.frame_index,
        light_info.camera.index,
        shadow_include,
        shadow_exclude,
      )
      shadow_draw_buffer := visibility_culler_command_buffer(
        &self.visibility_culler,
        self.frame_index,
      )
      shadow_draw_count := visibility_culler_max_draw_count(
        &self.visibility_culler,
      )
      shadow_begin(
        shadow_target,
        command_buffer,
        &self.resource_manager,
        self.frame_index,
      )
      shadow_render(
        &self.shadow,
        shadow_target^,
        command_buffer,
        &self.resource_manager,
        self.frame_index,
        shadow_draw_buffer,
        shadow_draw_count,
      )
      shadow_end(
        command_buffer,
        shadow_target,
        &self.resource_manager,
        self.frame_index,
      )

    case .DIRECTIONAL:
      // Directional shadow rendering not yet implemented
    }
  }

  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

@(private = "file")
record_depth_gbuffer_pass :: proc(
  self: ^Engine,
  command_buffer: vk.CommandBuffer,
  main_render_target: ^resources.RenderTarget,
) -> vk.Result {
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
  }
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return
  depth_texture := resources.get(
    self.resource_manager.image_2d_buffers,
    resources.get_depth_texture(main_render_target, self.frame_index),
  )
  if depth_texture != nil {
    gpu.transition_image(
      command_buffer,
      depth_texture.image,
      .UNDEFINED,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      {.DEPTH},
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    )
  }
  visibility_culler_dispatch(
    &self.visibility_culler,
    &self.gpu_context,
    command_buffer,
    self.frame_index,
    main_render_target.camera.index,
    {.VISIBLE},
    {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
  )
  draw_buffer := visibility_culler_command_buffer(
    &self.visibility_culler,
    self.frame_index,
  )
  draw_count := visibility_culler_max_draw_count(&self.visibility_culler)
  depth_prepass_begin(
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )
  depth_prepass_render(
    &self.gbuffer,
    command_buffer,
    main_render_target.camera.index,
    &self.resource_manager,
    self.frame_index,
    draw_buffer,
    draw_count,
  )
  depth_prepass_end(command_buffer)
  gbuffer_begin(
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )
  gbuffer_render(
    &self.gbuffer,
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
    draw_buffer,
    draw_count,
  )
  gbuffer_end(
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )
  if depth_texture != nil {
    gpu.transition_image(
      command_buffer,
      depth_texture.image,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      .SHADER_READ_ONLY_OPTIMAL,
      {.DEPTH},
      {.LATE_FRAGMENT_TESTS},
      {.FRAGMENT_SHADER},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      {.SHADER_READ},
    )
  }
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

@(private = "file")
record_lighting_pass :: proc(
  self: ^Engine,
  command_buffer: vk.CommandBuffer,
  main_render_target: ^resources.RenderTarget,
) -> vk.Result {
  vk.ResetCommandBuffer(command_buffer, {}) or_return

  color_format := self.swapchain.format.format
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = &color_format,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  ambient_begin(
    &self.ambient,
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )
  ambient_render(
    &self.ambient,
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )
  ambient_end(command_buffer)

  lighting_begin(
    &self.lighting,
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )
  lighting_render(
    &self.lighting,
    self.lights[:self.active_light_count],
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )
  lighting_end(command_buffer)

  particle_begin(
    &self.particle,
    command_buffer,
    main_render_target,
    &self.resource_manager,
    self.frame_index,
  )
  particle_render(
    &self.particle,
    command_buffer,
    main_render_target.camera.index,
    &self.resource_manager,
  )
  particle_end(command_buffer)
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

@(private = "file")
record_transparency_pass :: proc(
  self: ^Engine,
  command_buffer: vk.CommandBuffer,
  main_render_target: ^resources.RenderTarget,
) -> vk.Result {
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_format := self.swapchain.format.format
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = &color_format,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  transparent_begin(
    &self.transparent,
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
  )

  navmesh_render(
    &self.navmesh,
    command_buffer,
    linalg.MATRIX4F32_IDENTITY,
    main_render_target.camera.index,
  )
  visibility_culler_dispatch(
    &self.visibility_culler,
    &self.gpu_context,
    command_buffer,
    self.frame_index,
    main_render_target.camera.index,
    {.VISIBLE, .MATERIAL_TRANSPARENT},
  )
  transparent_draw_buffer := visibility_culler_command_buffer(&self.visibility_culler, self.frame_index)
  transparent_draw_count := visibility_culler_max_draw_count(&self.visibility_culler)
  transparent_render_pass(
    &self.transparent,
    self.transparent.transparent_pipeline,
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
    transparent_draw_buffer,
    transparent_draw_count,
  )
  visibility_culler_dispatch(
    &self.visibility_culler,
    &self.gpu_context,
    command_buffer,
    self.frame_index,
    main_render_target.camera.index,
    {.VISIBLE, .MATERIAL_WIREFRAME},
  )
  wireframe_draw_buffer := visibility_culler_command_buffer(&self.visibility_culler, self.frame_index)
  wireframe_draw_count := visibility_culler_max_draw_count(&self.visibility_culler)
  transparent_render_pass(
    &self.transparent,
    self.transparent.wireframe_pipeline,
    main_render_target,
    command_buffer,
    &self.resource_manager,
    self.frame_index,
    wireframe_draw_buffer,
    wireframe_draw_count,
  )
  transparent_end(&self.transparent, command_buffer)
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

@(private = "file")
record_postprocess_pass :: proc(
  self: ^Engine,
  command_buffer: vk.CommandBuffer,
  main_render_target: ^resources.RenderTarget,
) -> vk.Result {
  vk.ResetCommandBuffer(command_buffer, {}) or_return

  color_format := self.swapchain.format.format
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = &color_format,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  final_image := resources.get(
    self.resource_manager.image_2d_buffers,
    resources.get_final_image(main_render_target, self.frame_index),
  )
  if final_image != nil {
    gpu.transition_image_to_shader_read(command_buffer, final_image.image)
  }

  postprocess_begin(&self.postprocess, command_buffer, self.swapchain.extent)
  gpu.transition_image(
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
    &self.resource_manager,
    self.frame_index,
  )
  postprocess_end(&self.postprocess, command_buffer)

  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

@(private = "file")
update_skeletal_animations :: proc(self: ^Engine, render_delta_time: f32) {
    for &entry in self.scene.nodes.entries do if entry.active {
    data, is_mesh := &entry.item.attachment.(MeshAttachment)
    if !is_mesh do continue
    skinning, has_skin := &data.skinning.?
    if !has_skin do continue
    anim_inst, has_animation := &skinning.animation.?
    if !has_animation do continue
    animation.instance_update(anim_inst, render_delta_time)
    mesh := resources.get_mesh(&self.resource_manager, data.handle) or_continue
    mesh_skin, mesh_has_skin := mesh.skinning.?
    if !mesh_has_skin do continue
    l := skinning.bone_matrix_offset
    r := l + u32(len(mesh_skin.bones))
    bone_matrices := self.resource_manager.bone_buffers[self.frame_index].mapped[l:r]
    resources.sample_clip(mesh, anim_inst.clip, anim_inst.time, bone_matrices)
  }
}

@(private = "file")
setup_point_light_shadow_cameras :: proc(
  self: ^Engine,
  light_info: ^LightInfo,
  position: [3]f32,
  shadow_map_index: int,
) {
  @(static) face_dirs := [6][3]f32 {
    {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
  }
  @(static) face_ups := [6][3]f32 {
    {0, -1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, -1, 0},
  }

  light_info.cube_render_targets = self.cube_shadow_render_targets[shadow_map_index]

  for i in 0 ..< 6 {
    render_target := resources.get(
      self.resource_manager.render_targets,
      light_info.cube_render_targets[i],
    )
    camera: ^geometry.Camera
    light_info.cube_cameras[i], camera = resources.alloc(&self.resource_manager.cameras)
    geometry.camera_perspective(camera, math.PI * 0.5, 1.0, 0.1, light_info.light_radius)
    render_target.camera = light_info.cube_cameras[i]
    target_pos := position + face_dirs[i]
    geometry.camera_look_at(camera, position, target_pos, face_ups[i])
    resources.render_target_update_camera_data(&self.resource_manager, render_target)
  }
}

@(private = "file")
process_point_light :: proc(
  self: ^Engine,
  node: ^Node,
  attachment: ^PointLightAttachment,
  cube_shadow_map_count: ^int,
) {
  light_info := &self.lights[self.active_light_count]
  position := get_world_matrix(node) * [4]f32{0, 0, 0, 1}

  light_info.light_kind = .POINT
  light_info.light_color = attachment.color.xyz
  light_info.light_position = position.xyz
  light_info.light_radius = attachment.radius
  light_info.light_cast_shadow = b32(attachment.cast_shadow && cube_shadow_map_count^ < MAX_SHADOW_MAPS)

  if light_info.light_cast_shadow {
    light_info.shadow_map_id = self.cube_shadow_maps[self.frame_index][cube_shadow_map_count^].index
    light_info.shadow_map = self.cube_shadow_maps[self.frame_index][cube_shadow_map_count^]
    cube_shadow_map_count^ += 1

    setup_point_light_shadow_cameras(self, light_info, position.xyz, cube_shadow_map_count^ - 1)
    light_info.light_camera_idx = light_info.cube_cameras[0].index
  }

  self.active_light_count += 1
}

@(private = "file")
process_spot_light :: proc(
  self: ^Engine,
  node: ^Node,
  attachment: ^SpotLightAttachment,
  shadow_map_count: ^int,
) {
  light_info := &self.lights[self.active_light_count]
  position := get_world_matrix(node) * [4]f32{0, 0, 0, 1}
  direction := get_world_matrix(node) * [4]f32{0, -1, 0, 0}
  light_info.light_kind = .SPOT
  light_info.light_color = attachment.color.xyz
  light_info.light_position = position.xyz
  light_info.light_direction = direction.xyz
  light_info.light_radius = attachment.radius
  light_info.light_angle = attachment.angle
  light_info.light_cast_shadow = b32(attachment.cast_shadow) && shadow_map_count^ < MAX_SHADOW_MAPS
  if light_info.light_cast_shadow {
    light_info.shadow_map_id = self.shadow_maps[self.frame_index][shadow_map_count^].index
    light_info.shadow_map = self.shadow_maps[self.frame_index][shadow_map_count^]
    shadow_map_count^ += 1
    light_info.render_target = self.shadow_render_targets[shadow_map_count^ - 1]
    render_target := resources.get_render_target(&self.resource_manager, light_info.render_target)
    camera: ^geometry.Camera
    light_info.camera, camera = resources.alloc(&self.resource_manager.cameras)
    geometry.camera_perspective(camera, light_info.light_angle * 2.0, 1.0, 0.1, light_info.light_radius)
    render_target.camera = light_info.camera
    target_pos := position.xyz + direction.xyz
    geometry.camera_look_at(camera, position.xyz, target_pos)
    resources.render_target_update_camera_data(&self.resource_manager, render_target)
    light_info.light_camera_idx = light_info.camera.index
  }

  self.active_light_count += 1
}

@(private = "file")
process_directional_light :: proc(
  self: ^Engine,
  node: ^Node,
  attachment: ^DirectionalLightAttachment,
) {
  light_info := &self.lights[self.active_light_count]
  direction := get_world_matrix(node) * [4]f32{0, 0, -1, 0}
  light_info.light_kind = .DIRECTIONAL
  light_info.light_color = attachment.color.xyz
  light_info.light_direction = direction.xyz
  light_info.light_cast_shadow = b32(attachment.cast_shadow)

  self.active_light_count += 1
}

@(private = "file")
process_scene_lights :: proc(self: ^Engine) {
  self.active_light_count = 0
  shadow_map_count := 0
  cube_shadow_map_count := 0
  for &entry in self.scene.nodes.entries do if entry.active {
    node := &entry.item
    if self.active_light_count >= len(self.lights) do continue
    #partial switch &attachment in &node.attachment {
    case PointLightAttachment:
      process_point_light(self, node, &attachment, &cube_shadow_map_count)
    case SpotLightAttachment:
      process_spot_light(self, node, &attachment, &shadow_map_count)
    case DirectionalLightAttachment:
      process_directional_light(self, node, &attachment)
    }
  }
}

@(private = "file")
render_debug_ui :: proc(self: ^Engine) {
  if mu.window(&self.ui.ctx, "Engine", {40, 40, 300, 200}, {.NO_CLOSE}) {
    mu.label(&self.ui.ctx, fmt.tprintf("Objects %d", len(self.scene.nodes.entries) - len(self.scene.nodes.free_indices)))
    mu.label(&self.ui.ctx, fmt.tprintf("Textures %d", len(self.resource_manager.image_2d_buffers.entries) - len(self.resource_manager.image_2d_buffers.free_indices)))
    mu.label(&self.ui.ctx, fmt.tprintf("Materials %d", len(self.resource_manager.materials.entries) - len(self.resource_manager.materials.free_indices)))
    mu.label(&self.ui.ctx, fmt.tprintf("Meshes %d", len(self.resource_manager.meshes.entries) - len(self.resource_manager.meshes.free_indices)))
    mu.label(&self.ui.ctx, fmt.tprintf("Visible nodes (max %d): %d", self.visibility_culler.max_draws, self.visibility_culler.node_count))
  }
}


@(private = "file")
recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  swapchain_recreate(
    &engine.gpu_context,
    &engine.swapchain,
    engine.window,
  ) or_return
  new_aspect_ratio :=
    f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
  if main_camera := get_main_camera(engine); main_camera != nil {
    geometry.camera_update_aspect_ratio(main_camera, new_aspect_ratio)
  }
  if main_render_target, ok := resources.get_render_target(&engine.resource_manager, engine.main_render_target); ok {
    // Save current camera state
    old_camera := resources.get(
      engine.resource_manager.cameras,
      main_render_target.camera,
    )
    old_position :=
      old_camera.position if old_camera != nil else [3]f32{0, 0, 3}
    old_target := [3]f32{0, 0, 0} // Calculate from camera direction if needed

    resources.render_target_deinit(
      main_render_target,
      &engine.gpu_context,
      &engine.resource_manager,
    )
    resources.render_target_init(
      main_render_target,
      &engine.gpu_context,
      &engine.resource_manager,
      engine.swapchain.extent.width,
      engine.swapchain.extent.height,
      engine.swapchain.format.format,
      .D32_SFLOAT,
      {
        .FINAL_IMAGE,
        .POSITION_TEXTURE,
        .NORMAL_TEXTURE,
        .ALBEDO_TEXTURE,
        .METALLIC_ROUGHNESS,
        .EMISSIVE_TEXTURE,
        .DEPTH_TEXTURE,
      },
      old_position, // Preserve camera position
      old_target, // Preserve camera target
    ) or_return
  }
  lighting_recreate_images(
    &engine.lighting,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
    vk.Format.D32_SFLOAT,
  ) or_return
  // renderer_ambient_recreate_images does not exist - skip
  postprocess_recreate_images(
    &engine.gpu_context,
    &engine.postprocess,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
    &engine.resource_manager,
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

render :: proc(self: ^Engine) -> vk.Result {
  acquire_next_image(&self.gpu_context, &self.swapchain, self.frame_index) or_return
  mu.begin(&self.ui.ctx)
  command_buffer := self.command_buffers[self.frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  resource_frame_ctx := resources.FrameContext {
    frame_index = self.frame_index,
    transfer_command_buffer = command_buffer,
    upload_allocator = nil,
  }
  resources.begin_frame(&self.resource_manager, &resource_frame_ctx)
  render_delta_time := f32(time.duration_seconds(time.since(self.last_render_timestamp)))
  update_skeletal_animations(self, render_delta_time)
  main_render_target, found_main_rt := resources.get_render_target(&self.resource_manager, self.main_render_target)
  if !found_main_rt {
    log.errorf("Main render target not found")
    return .ERROR_UNKNOWN
  }
  main_camera, found_camera := resources.get_camera(&self.resource_manager, main_render_target.camera)
  if !found_camera {
    log.errorf("Main camera not found")
    return .ERROR_UNKNOWN
  }
  resources.render_target_update_camera_data(&self.resource_manager, main_render_target)
  upload_world_matrices(&self.resource_manager, &self.scene, self.frame_index)
  defer {
    for i in 0 ..< self.active_light_count {
      light_info := &self.lights[i]
      if !light_info.light_cast_shadow do continue

      switch light_info.light_kind {
      case .POINT:
        for camera_handle in light_info.cube_cameras {
          if camera_handle.generation != 0 {
            resources.free(&self.resource_manager.cameras, camera_handle)
          }
        }
      case .SPOT:
        if light_info.camera.generation != 0 {
          resources.free(&self.resource_manager.cameras, light_info.shadow_resources.camera)
        }
      case .DIRECTIONAL:
      }
    }
  }

  process_scene_lights(self)
  clear(&self.frame_active_render_targets)
  append(&self.frame_active_render_targets, self.main_render_target)
  for light_info in self.lights[:self.active_light_count] {
    if !light_info.light_cast_shadow do continue
    switch light_info.light_kind {
    case .POINT:
      for target_handle in light_info.cube_render_targets {
      resources.get_render_target(&self.resource_manager, target_handle) or_continue
        append(&self.frame_active_render_targets, target_handle)
      }
    case .SPOT:
      resources.get_render_target(&self.resource_manager, light_info.render_target) or_continue
      append(&self.frame_active_render_targets, light_info.render_target)
    case .DIRECTIONAL:
    }
  }
  for &entry, i in self.resource_manager.render_targets.entries do if entry.active {
    handle := Handle{entry.generation, u32(i)}
    if handle.index == self.main_render_target.index do continue
    is_shadow_target := false
    for existing_handle in self.frame_active_render_targets {
      if handle.index == existing_handle.index {
        is_shadow_target = true
        break
      }
    }
    if is_shadow_target do continue
    append(&self.frame_active_render_targets, handle)
  }
  visibility_culler_update(
    &self.visibility_culler,
    &self.scene,
  )
  record_shadow_pass(
    self,
    self.shadow_pass_command_buffers[self.frame_index],
  ) or_return
  record_depth_gbuffer_pass(
    self,
    self.gbuffer_command_buffers[self.frame_index],
    main_render_target,
  ) or_return
  record_lighting_pass(
    self,
    self.lighting_command_buffers[self.frame_index],
    main_render_target,
  ) or_return
  record_transparency_pass(
    self,
    self.transparency_command_buffers[self.frame_index],
    main_render_target,
  ) or_return
  record_postprocess_pass(
    self,
    self.postprocess_command_buffers[self.frame_index],
    main_render_target,
  ) or_return
  resources.commit(&self.resource_manager, &self.gpu_context, &resource_frame_ctx) or_return
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  compute_particles(
    &self.particle,
    command_buffer,
    main_camera^,
    self.resource_manager.world_matrix_descriptor_sets[self.frame_index],
  )
  if self.custom_render_proc != nil {
    self.custom_render_proc(self, command_buffer)
  }
  secondary_commands := [?]vk.CommandBuffer{
    self.shadow_pass_command_buffers[self.frame_index],
    self.gbuffer_command_buffers[self.frame_index],
    self.lighting_command_buffers[self.frame_index],
    self.transparency_command_buffers[self.frame_index],
    self.postprocess_command_buffers[self.frame_index],
  }
  vk.CmdExecuteCommands(command_buffer, len(secondary_commands), raw_data(secondary_commands[:]))
  render_debug_ui(self)
  if self.render2d_proc != nil {
    self.render2d_proc(self, &self.ui.ctx)
  }
  mu.end(&self.ui.ctx)
  ui_begin(
    &self.ui,
    command_buffer,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
  )
  ui_render(&self.ui, command_buffer)
  ui_end(&self.ui, command_buffer)
  gpu.transition_image_to_present(
    command_buffer,
    self.swapchain.images[self.swapchain.image_index],
  )
  vk.EndCommandBuffer(command_buffer) or_return
  submit_queue_and_present(
    &self.gpu_context,
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
  defer deinit(self)
  when USE_PARALLEL_UPDATE {
    self.update_active = true
    update_data := UpdateThreadData{engine = self}
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
    // Handle input and GLFW events on main thread, GLFW cannot run on subthreads
    update_input(self)
    when !USE_PARALLEL_UPDATE {
      // Single threaded mode - run update directly
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

update_thread_proc :: proc(thread: ^thread.Thread) {
  data := cast(^UpdateThreadData)thread.data
  engine := data.engine
  for engine.update_active {
    // Run update at consistent rate
    should_update := update(engine)
    if !should_update {
      // Sleep briefly to avoid busy waiting
      // MAXIMUM 500 FPS
      time.sleep(time.Millisecond * 2)
    }
  }
  log.info("Update thread terminating")
}

// Deferred cleanup functions for thread safety
queue_node_deletion :: proc(engine: ^Engine, handle: Handle) {
  append(&engine.pending_node_deletions, handle)
}

process_pending_deletions :: proc(engine: ^Engine) {
  for handle in engine.pending_node_deletions {
    if node, freed := resources.free(&engine.scene.nodes, handle); freed {
      deinit_node(node, &engine.resource_manager)
    }
  }
  clear(&engine.pending_node_deletions)
}

screen_to_world_ray :: proc(engine: ^Engine, screen_x, screen_y: f32) -> (ray_origin: [3]f32, ray_dir: [3]f32) {
    main_camera := get_main_camera(engine)
    if main_camera == nil do return
    width, height := glfw.GetWindowSize(engine.window)
    // Normalize screen coordinates to [-1, 1]
    ndc_x := (2.0 * screen_x / f32(width)) - 1.0
    ndc_y := 1.0 - (2.0 * screen_y / f32(height))  // Flip Y
    view, proj := geometry.camera_calculate_matrices(main_camera^)
    ray_clip := [4]f32{ndc_x, ndc_y, -1.0, 1.0}
    ray_eye := linalg.matrix4x4_inverse(proj) * ray_clip
    ray_eye = [4]f32{ray_eye.x, ray_eye.y, -1.0, 0.0}  // Point at infinity
    ray_world := linalg.matrix4x4_inverse(view) * ray_eye
    ray_dir = linalg.normalize(ray_world.xyz)
    ray_origin = main_camera.position
    return ray_origin, ray_dir
}
