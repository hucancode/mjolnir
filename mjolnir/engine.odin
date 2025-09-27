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
import world "world"
import particles "render/particles"
import "render/lighting"
import "render/debug_ui"
import navmesh_renderer "render/navigation"
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

// Re-export world types for convenience
Node :: world.Node
PointLightAttachment :: world.PointLightAttachment
DirectionalLightAttachment :: world.DirectionalLightAttachment
SpotLightAttachment :: world.SpotLightAttachment
MeshAttachment :: world.MeshAttachment
ForceFieldAttachment :: world.ForceFieldAttachment
EmitterAttachment :: world.EmitterAttachment

// Legacy wrapper functions for backwards compatibility
spawn :: proc {
  spawn_world,
  spawn_world_at,
  spawn_world_child,
}

spawn_world :: proc(
  engine: ^Engine,
  attachment: world.NodeAttachment = nil,
) -> (handle: Handle, node: ^Node) {
  return world.spawn_node(&engine.world, {0, 0, 0}, attachment, &engine.resource_manager)
}

spawn_world_at :: proc(
  engine: ^Engine,
  position: [3]f32,
  attachment: world.NodeAttachment = nil,
) -> (handle: Handle, node: ^Node) {
  return world.spawn_node(&engine.world, position, attachment, &engine.resource_manager)
}

spawn_world_child :: proc(
  engine: ^Engine,
  parent: Handle,
  attachment: world.NodeAttachment = nil,
) -> (handle: Handle, node: ^Node) {
  return world.spawn_child_node(&engine.world, parent, {0, 0, 0}, attachment, &engine.resource_manager)
}

despawn :: proc(engine: ^Engine, handle: Handle) -> bool {
  return world.destroy_node_handle(&engine.world, handle)
}

// Add missing navmesh functions
navmesh_build_from_recast :: navmesh_renderer.build_from_recast
navmesh_get_triangle_count :: navmesh_renderer.get_triangle_count

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

InputState :: struct {
  mouse_pos:         [2]f64,
  mouse_drag_origin: [2]f32,
  mouse_buttons:     [8]bool,
  mouse_holding:     [8]bool,
  key_holding:       [512]bool,
  keys:              [512]bool,
}

Engine :: struct {
  window:                      glfw.WindowHandle,
  gpu_context:                 gpu.GPUContext,
  resource_manager:            resources.Manager,
  frame_index:                 u32,
  swapchain:                   gpu.Swapchain,
  world:                       world.World,
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
  render:                      Renderer,
  navmesh:                     navmesh_renderer.Renderer,
  command_buffers:             [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  cursor_pos:                  [2]i32,
  // Engine-managed shadow maps
  shadow_maps:                 [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  cube_shadow_maps:            [MAX_FRAMES_IN_FLIGHT][MAX_SHADOW_MAPS]Handle,
  // Persistent shadow render targets
  shadow_render_targets:       [MAX_SHADOW_MAPS]Handle,
  cube_shadow_render_targets:  [MAX_SHADOW_MAPS][6]Handle,
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
  world.init(&self.world)
  world.init_gpu(&self.world, &self.gpu_context, &self.resource_manager) or_return
  gpu.swapchain_init(&self.swapchain, &self.gpu_context, self.window) or_return

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
  self.render.targets.main, main_render_target = resources.alloc(
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
  renderer_init(
    &self.render,
    &self.gpu_context,
    &self.resource_manager,
    self.swapchain.extent,
    self.swapchain.format.format,
    self.render.targets.main,
    get_window_dpi(self.window),
  ) or_return
  log.debugf("initializing navigation mesh renderer")
  navmesh_renderer.init(&self.navmesh, &self.gpu_context, &self.resource_manager) or_return
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
      mu.input_text(&engine.render.ui.ctx, string(bytes[:size]))
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
  params := gpu.data_buffer_get(&self.render.particles.params_buffer)
  params.delta_time = delta_time
  emitters := gpu.staged_buffer_get_all(&self.resource_manager.emitter_buffer)
  world.sync_emitters(&self.world, &self.resource_manager, emitters, params)
}

get_main_camera :: proc(self: ^Engine) -> ^geometry.Camera {
  target, ok := resources.get_render_target(&self.resource_manager, self.render.targets.main)
  if !ok {
    return nil
  }
  camera_ptr, camera_found := resources.get_camera(&self.resource_manager, target.camera)
  if !camera_found {
    return nil
  }
  return camera_ptr
}

@(private = "file")
update_force_fields :: proc(self: ^Engine) {
  params := gpu.data_buffer_get(&self.render.particles.params_buffer)
  params.forcefield_count = 0
  forcefields := slice.from_ptr(
    self.render.particles.force_field_buffer.mapped,
    particles.MAX_FORCE_FIELDS,
  )
  for &entry in self.world.nodes.entries do if entry.active {
    ff, is_ff := &entry.item.attachment.(ForceFieldAttachment)
    if !is_ff do continue
    forcefields[params.forcefield_count].position = world.node_get_world_matrix(&entry.item) * [4]f32{0, 0, 0, 1}
    forcefields[params.forcefield_count].tangent_strength = ff.tangent_strength
    forcefields[params.forcefield_count].strength = ff.strength
    forcefields[params.forcefield_count].area_of_effect = ff.area_of_effect
    forcefields[params.forcefield_count].fade = ff.fade
    params.forcefield_count += 1
  }
}

update_skeletal_animations :: proc(self: ^Engine, delta_time: f32) {
  if delta_time <= 0 {
    return
  }
  bone_buffer := &self.resource_manager.bone_buffers[self.frame_index]
  if bone_buffer.mapped == nil {
    return
  }

  for &entry in self.world.nodes.entries do if entry.active {
    node := &entry.item
    mesh_attachment, has_mesh := node.attachment.(MeshAttachment)
    if !has_mesh do continue

    skinning, has_skin := mesh_attachment.skinning.?;
    if !has_skin do continue

    anim_instance, has_anim := skinning.animation.?;
    if !has_anim do continue

    animation.instance_update(&anim_instance, delta_time)
    clip := anim_instance.clip
    if clip == nil do continue

    mesh := resources.get_mesh(&self.resource_manager, mesh_attachment.handle)
    if mesh == nil do continue
    mesh_skinning, mesh_has_skin := mesh.skinning.?;
    if !mesh_has_skin do continue

    bone_count := len(mesh_skinning.bones)
    if bone_count == 0 do continue

    if skinning.bone_matrix_offset == 0xFFFFFFFF do continue

    matrices_ptr := gpu.data_buffer_get(
      bone_buffer,
      skinning.bone_matrix_offset,
    )
    matrices := slice.from_ptr(matrices_ptr, bone_count)
    resources.sample_clip(
      mesh,
      clip,
      anim_instance.time,
      matrices,
    )

    skinning.animation = anim_instance
    mesh_attachment.skinning = skinning
    node.attachment = mesh_attachment
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
  frame_ctx := world.FrameContext {
    frame_index = self.frame_index,
    delta_time  = delta_time,
  }
  world.begin_frame(&self.world, &frame_ctx)
  // Animation updates are now handled in render thread for smooth animation at render FPS
  update_emitters(self, delta_time)
  update_force_fields(self)
  if self.update_proc != nil {
    self.update_proc(self, delta_time)
  }
  self.last_update_timestamp = time.now()
  return true
}

shutdown :: proc(self: ^Engine) {
  vk.DeviceWaitIdle(self.gpu_context.device)
  gpu.free_command_buffers(self.gpu_context.device, self.gpu_context.command_pool, self.command_buffers[:])
  if item, ok := resources.free(
    &self.resource_manager.render_targets,
    self.render.targets.main,
  ); ok {
    resources.render_target_destroy(item, self.gpu_context.device, &self.resource_manager)
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
  delete(self.pending_node_deletions)
  vk.DestroyFence(self.gpu_context.device, self.frame_fence, nil)
  renderer_shutdown(&self.render, self.gpu_context.device, self.gpu_context.command_pool, &self.resource_manager)
  navmesh_renderer.destroy(&self.navmesh, self.gpu_context.device)
  world.shutdown(&self.world, &self.gpu_context, &self.resource_manager)
  resources.shutdown(&self.resource_manager, &self.gpu_context)
  gpu.swapchain_destroy(&self.swapchain, self.gpu_context.device)
  gpu.shutdown(&self.gpu_context)
  glfw.DestroyWindow(self.window)
  glfw.Terminate()
  log.infof("Engine deinitialized")
}

@(private = "file")
prepare_light_shadow_resources :: proc(self: ^Engine) {
  cube_dirs := [6][3]f32{
    {1, 0, 0},
    {-1, 0, 0},
    {0, 1, 0},
    {0, -1, 0},
    {0, 0, 1},
    {0, 0, -1},
  }
  cube_ups := [6][3]f32{
    {0, -1, 0},
    {0, -1, 0},
    {0, 0, 1},
    {0, 0, -1},
    {0, -1, 0},
    {0, -1, 0},
  }
  shadow_map_count: u32 = 0
  cube_shadow_map_count: u32 = 0
  for &entry, index in self.resource_manager.lights.entries {
    if !entry.active {
      continue
    }
    handle := Handle{index = u32(index), generation = entry.generation}
    light := &entry.item
    light.shadow.shadow_map = {}
    light.shadow.render_target = {}
    for face in 0 ..< len(light.shadow.cube_render_targets) {
      light.shadow.cube_render_targets[face] = {}
    }
    if !light.cast_shadow || !light.enabled {
      light.is_dirty = true
      if light.is_dirty {
        resources.update_light_gpu_data(&self.resource_manager, handle)
        light.is_dirty = false
      }
      continue
    }
    switch light.kind {
    case resources.LightKind.POINT:
      if cube_shadow_map_count < MAX_SHADOW_MAPS {
        slot := cube_shadow_map_count
        cube_shadow_map_count += 1
        light.shadow.shadow_map = self.cube_shadow_maps[self.frame_index][slot]
        far_plane := light.radius
        if far_plane <= 0.1 {
          far_plane = 0.1
        }
        for face in 0 ..< 6 {
          light.shadow.cube_render_targets[face] = self.cube_shadow_render_targets[slot][face]
          camera_handle := light.shadow.cube_cameras[face]
          if camera_handle.generation == 0 {
            camera_handle, camera := resources.alloc(&self.resource_manager.cameras)
            if camera != nil {
              camera^ = geometry.make_camera_perspective(math.PI * 0.5, 1.0, 0.1, far_plane)
            }
            light.shadow.cube_cameras[face] = camera_handle
          }
          camera := resources.get(self.resource_manager.cameras, light.shadow.cube_cameras[face])
          if camera != nil {
            geometry.camera_perspective(camera, math.PI * 0.5, 1.0, 0.1, far_plane)
            target := light.position + cube_dirs[face]
            geometry.camera_look_at(camera, light.position, target, cube_ups[face])
          }
          render_target := resources.get(
            self.resource_manager.render_targets,
            light.shadow.cube_render_targets[face],
          )
          if render_target != nil {
            render_target.camera = light.shadow.cube_cameras[face]
            resources.render_target_upload_camera_data(&self.resource_manager, render_target)
          }
        }
      }
      light.is_dirty = true
    case resources.LightKind.SPOT:
      if shadow_map_count < MAX_SHADOW_MAPS {
        slot := shadow_map_count
        shadow_map_count += 1
        light.shadow.render_target = self.shadow_render_targets[slot]
        light.shadow.shadow_map = self.shadow_maps[self.frame_index][slot]
        if light.shadow.camera.generation == 0 {
          camera_handle, camera := resources.alloc(&self.resource_manager.cameras)
          if camera != nil {
            far_plane := light.radius
            if far_plane <= 0.1 {
              far_plane = 0.1
            }
            fov_init := light.angle * 2.0
            if fov_init <= 0.0 {
              fov_init = 0.1
            }
            camera^ = geometry.make_camera_perspective(fov_init, 1.0, 0.1, far_plane)
          }
          light.shadow.camera = camera_handle
        }
        camera := resources.get(self.resource_manager.cameras, light.shadow.camera)
        if camera != nil {
          fov := light.angle * 2.0
          if fov <= 0.0 {
            fov = 0.1
          }
          max_fov: f32 = f32(math.PI) * 0.95
          if fov > max_fov {
            fov = max_fov
          }
          far_plane := light.radius
          if far_plane <= 0.1 {
            far_plane = 0.1
          }
          geometry.camera_perspective(camera, fov, 1.0, 0.1, far_plane)
          target := light.position + light.direction
          geometry.camera_look_at(camera, light.position, target)
        }
        render_target := resources.get(
          self.resource_manager.render_targets,
          light.shadow.render_target,
        )
        if render_target != nil {
          render_target.camera = light.shadow.camera
          resources.render_target_upload_camera_data(&self.resource_manager, render_target)
        }
      }
      light.is_dirty = true
    case resources.LightKind.DIRECTIONAL:
      light.is_dirty = true
    }
    if light.is_dirty {
      resources.update_light_gpu_data(&self.resource_manager, handle)
      light.is_dirty = false
    }
  }
}

@(private = "file")
render_debug_ui :: proc(self: ^Engine) {
  if mu.window(&self.render.ui.ctx, "Engine", {40, 40, 300, 200}, {.NO_CLOSE}) {
    mu.label(&self.render.ui.ctx, fmt.tprintf("Objects %d", len(self.world.nodes.entries) - len(self.world.nodes.free_indices)))
    mu.label(&self.render.ui.ctx, fmt.tprintf("Textures %d", len(self.resource_manager.image_2d_buffers.entries) - len(self.resource_manager.image_2d_buffers.free_indices)))
    mu.label(&self.render.ui.ctx, fmt.tprintf("Materials %d", len(self.resource_manager.materials.entries) - len(self.resource_manager.materials.free_indices)))
    mu.label(&self.render.ui.ctx, fmt.tprintf("Meshes %d", len(self.resource_manager.meshes.entries) - len(self.resource_manager.meshes.free_indices)))
    mu.label(
      &self.render.ui.ctx,
      fmt.tprintf(
        "Visible nodes (max %d): %d",
        self.world.visibility.max_draws,
        self.world.visibility.node_count,
      ),
    )
  }
}


@(private = "file")
recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  gpu.swapchain_recreate(
    &engine.gpu_context,
    &engine.swapchain,
    engine.window,
  ) or_return
  new_aspect_ratio :=
    f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
  if main_camera := get_main_camera(engine); main_camera != nil {
    geometry.camera_update_aspect_ratio(main_camera, new_aspect_ratio)
  }
  if main_render_target, ok := resources.get_render_target(&engine.resource_manager, engine.render.targets.main); ok {
    // Save current camera state
    old_camera := resources.get(
      engine.resource_manager.cameras,
      main_render_target.camera,
    )
    old_position :=
      old_camera.position if old_camera != nil else [3]f32{0, 0, 3}
    old_target := [3]f32{0, 0, 0} // Calculate from camera direction if needed

    resources.render_target_destroy(
      main_render_target,
      engine.gpu_context.device,
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
  render_subsystem_resize(
    &engine.render,
    &engine.gpu_context,
    &engine.resource_manager,
    engine.swapchain.extent,
    engine.swapchain.format.format,
    get_window_dpi(engine.window),
  ) or_return
  return .SUCCESS
}

render :: proc(self: ^Engine) -> vk.Result {
  gpu.acquire_next_image(self.gpu_context.device, &self.swapchain, self.frame_index) or_return
  mu.begin(&self.render.ui.ctx)
  command_buffer := self.command_buffers[self.frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  resource_frame_ctx := resources.FrameContext {
    frame_index = self.frame_index,
    transfer_command_buffer = command_buffer,
  }
  resources.begin_frame(&self.resource_manager, &resource_frame_ctx)
  render_delta_time := f32(time.duration_seconds(time.since(self.last_render_timestamp)))
  update_skeletal_animations(self, render_delta_time)
  main_render_target, found_main_rt := resources.get_render_target(&self.resource_manager, self.render.targets.main)
  if !found_main_rt {
    log.errorf("Main render target not found")
    return .ERROR_UNKNOWN
  }
  resources.render_target_upload_camera_data(&self.resource_manager, main_render_target)
  world.upload_world_matrices(&self.world, &self.resource_manager, self.frame_index)
  world.sync_lights(&self.world, &self.resource_manager)
  prepare_light_shadow_resources(self)
  renderer_prepare_targets(
    &self.render,
    &self.resource_manager,
  )
  // Visibility is now updated in begin_frame
  record_shadow_pass(
    &self.render,
    self.frame_index,
    &self.gpu_context,
    &self.resource_manager,
    &self.world,
  )
  record_geometry_pass(
    &self.render,
    self.frame_index,
    &self.gpu_context,
    &self.resource_manager,
    &self.world,
    main_render_target,
  )
  record_lighting_pass(
    &self.render,
    self.frame_index,
    &self.resource_manager,
    main_render_target,
    self.swapchain.format.format,
  )
  record_particles_pass(
    &self.render,
    self.frame_index,
    &self.resource_manager,
    main_render_target,
    self.swapchain.format.format,
  )
  record_transparency_pass(
    &self.render,
    self.frame_index,
    &self.gpu_context,
    &self.resource_manager,
    &self.world,
    main_render_target,
    &self.navmesh,
    self.swapchain.format.format,
  )
  record_post_process_pass(
    &self.render,
    self.frame_index,
    &self.resource_manager,
    main_render_target,
    self.swapchain.format.format,
    self.swapchain.extent,
    self.swapchain.images[self.swapchain.image_index],
    self.swapchain.views[self.swapchain.image_index],
  )
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  particles.simulate(
    &self.render.particles,
    command_buffer,
    self.resource_manager.world_matrix_descriptor_sets[self.frame_index],
  )
  if self.custom_render_proc != nil {
    self.custom_render_proc(self, command_buffer)
  }
  // Commit resource changes after custom render to ensure any material updates are flushed
  buffers := [?]vk.CommandBuffer{
    self.render.shadow.commands[self.frame_index],
    self.render.geometry.commands[self.frame_index],
    self.render.lighting.commands[self.frame_index],
    self.render.particles.commands[self.frame_index],
    self.render.transparency.commands[self.frame_index],
    self.render.post_process.commands[self.frame_index],
  }
  vk.CmdExecuteCommands(
    command_buffer,
    len(buffers),
    raw_data(buffers[:]),
  )
  render_debug_ui(self)
  if self.render2d_proc != nil {
    self.render2d_proc(self, &self.render.ui.ctx)
  }
  mu.end(&self.render.ui.ctx)
  debug_ui.begin_pass(
    &self.render.ui,
    command_buffer,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
  )
  debug_ui.render(&self.render.ui, command_buffer)
  debug_ui.end_pass(&self.render.ui, command_buffer)
  gpu.transition_image_to_present(
    command_buffer,
    self.swapchain.images[self.swapchain.image_index],
  )
  vk.EndCommandBuffer(command_buffer) or_return
  gpu.submit_queue_and_present(
    &self.gpu_context,
    &self.swapchain,
    &command_buffer,
    self.frame_index,
  ) or_return
  resources.commit(&self.resource_manager, &self.gpu_context, &resource_frame_ctx) or_return
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
    world.destroy_node_handle(&engine.world, handle)
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
