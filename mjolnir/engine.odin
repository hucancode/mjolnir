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
MAX_CAMERA_UNIFORMS :: 16
MAX_TEXTURES :: 90
MAX_CUBE_TEXTURES :: 20
USE_GPU_CULLING :: true  // Set to false to use CPU culling instead

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
  views:    [6]matrix[4,4]f32,
  proj:     matrix[4,4]f32,
  world:    matrix[4,4]f32,
  color:    [4]f32,
  position: [4]f32,
  radius:   f32,
}

SpotLightData :: struct {
  view:      matrix[4,4]f32,
  proj:      matrix[4,4]f32,
  world:     matrix[4,4]f32,
  color:     [4]f32,
  position:  [4]f32,
  direction: [4]f32,
  radius:    f32,
  angle:     f32,
}

DirectionalLightData :: struct {
  view:      matrix[4,4]f32,
  proj:      matrix[4,4]f32,
  world:     matrix[4,4]f32,
  color:     [4]f32,
  direction: [4]f32,
}

LightData :: union {
  PointLightData,
  SpotLightData,
  DirectionalLightData,
}

CameraUniform :: struct {
  view:          matrix[4,4]f32,
  projection:    matrix[4,4]f32,
  viewport_size: [2]f32,
  camera_near:   f32,
  camera_far:    f32,
  padding:       [2]f32, // Align to 16-byte boundary
  camera_position: [3]f32,
  padding2:      f32, // Align to 16-byte boundary
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

// RenderTarget describes the output textures for a render pass.
RenderTarget :: struct {
  final:    vk.ImageView,
  position: vk.ImageView,
  normal:   vk.ImageView,
  albedo:   vk.ImageView,
  metallic: vk.ImageView,
  emissive: vk.ImageView,
  depth:    vk.ImageView,
  extra1:   vk.ImageView,
  extra2:   vk.ImageView,
  extent:   vk.Extent2D,
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

FrameData :: struct {
  camera_uniform:             DataBuffer(CameraUniform),
  shadow_maps:                [MAX_SHADOW_MAPS]Handle,
  cube_shadow_maps:           [MAX_SHADOW_MAPS]Handle,
  // G-buffer images
  gbuffer_position:           Handle,
  gbuffer_normal:             Handle,
  gbuffer_albedo:             Handle,
  gbuffer_metallic_roughness: Handle,
  gbuffer_emissive:           Handle,
  depth_buffer:               Handle,
  final_image:                Handle,
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
  ui:                    RendererUI,
  main:                  RendererLighting,
  ambient:               RendererAmbient,
  shadow:                RendererShadow,
  particle:              RendererParticle,
  scene_culling:         RendererSceneCulling,
  transparent:           RendererTransparent,
  postprocess:           RendererPostProcess,
  gbuffer:               RendererGBuffer,
  depth_prepass:         RendererDepthPrepass,
  command_buffers:       [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  cursor_pos:            [2]i32,
  frames:                [MAX_FRAMES_IN_FLIGHT]FrameData,
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
  // Only need camera uniforms now - shadow textures use bindless system
  DESCRIPTOR_PER_FRAME :: 1
  writes: [MAX_FRAMES_IN_FLIGHT * DESCRIPTOR_PER_FRAME]vk.WriteDescriptorSet
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame_data_init(&self.frames[i], &self.swapchain)
    writes[i * DESCRIPTOR_PER_FRAME + 0] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = g_camera_descriptor_sets[i],
      dstBinding      = 0,
      descriptorCount = 1,
      descriptorType  = .UNIFORM_BUFFER,
      pBufferInfo     = &{
        buffer = self.frames[i].camera_uniform.buffer,
        range = size_of(CameraUniform),
      },
    }
  }
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
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
  renderer_lighting_init(
    &self.main,
    &self.frames,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
    .D32_SFLOAT,
  ) or_return
  renderer_ambient_init(
    &self.ambient,
    &self.frames,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
    self.swapchain.format.format,
  )
  // Initialize ambient renderer fields to match main renderer
  self.ambient.environment_index = self.main.environment_map.index
  self.ambient.brdf_lut_index = self.main.brdf_lut.index
  self.ambient.environment_max_lod = self.main.environment_max_lod
  self.ambient.ibl_intensity = self.main.ibl_intensity
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
  when USE_GPU_CULLING {
    renderer_scene_culling_init(&self.scene_culling) or_return
  }
  renderer_transparent_init(
    &self.transparent,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  log.debugf("initializing shadow pipeline")
  renderer_shadow_init(&self.shadow, .D32_SFLOAT) or_return
  log.debugf("initializing post process pipeline")
  renderer_postprocess_init(
    &self.postprocess,
    self.swapchain.format.format,
    self.swapchain.extent.width,
    self.swapchain.extent.height,
  ) or_return
  renderer_ui_init(
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

update_emitters :: proc(self: ^Engine, delta_time: f32) {
  params := data_buffer_get(&self.particle.params_buffer)
  params.delta_time = delta_time

  emitters_ptr := data_buffer_get(&self.particle.emitter_buffer)
  emitters := slice.from_ptr(emitters_ptr, MAX_EMITTERS)
  emitter_idx: int = 0

  for &entry in self.scene.nodes.entries do if entry.active {
    e, is_emitter := &entry.item.attachment.(EmitterAttachment)
    if !is_emitter do continue
    if !e.enabled do continue
    if emitter_idx >= MAX_EMITTERS do break
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
  for &f in self.frames do frame_data_deinit(&f)
  renderer_ui_deinit(&self.ui)
  scene_deinit(&self.scene)
  renderer_lighting_deinit(&self.main)
  renderer_ambient_deinit(&self.ambient)
  renderer_gbuffer_deinit(&self.gbuffer)
  renderer_shadow_deinit(&self.shadow)
  renderer_postprocess_deinit(&self.postprocess)
  renderer_particle_deinit(&self.particle)
  when USE_GPU_CULLING {
    renderer_scene_culling_deinit(&self.scene_culling)
  }
  renderer_transparent_deinit(&self.transparent)
  renderer_depth_prepass_deinit(&self.depth_prepass)
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
  geometry.camera_update_aspect_ratio(&engine.scene.camera, new_aspect_ratio)
  // Recreate all images that depend on swapchain dimensions
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame_data_deinit(&engine.frames[i])
    frame_data_init(&engine.frames[i], &engine.swapchain)
    // Only need to update camera uniform - shadow textures use bindless system
    write := vk.WriteDescriptorSet {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = g_camera_descriptor_sets[i],
      dstBinding = 0,
      descriptorCount = 1,
      descriptorType = .UNIFORM_BUFFER,
      pBufferInfo = &{
        buffer = engine.frames[i].camera_uniform.buffer,
        range = size_of(CameraUniform),
      },
    }
    vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  }
  renderer_lighting_recreate_images(
    &engine.main,
    &engine.frames,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
    .D32_SFLOAT,
  ) or_return
  renderer_ambient_recreate_images(
    &engine.ambient,
    &engine.frames,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
  ) or_return
  renderer_postprocess_recreate_images(
    &engine.postprocess,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
  ) or_return
  renderer_ui_recreate_images(
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
  log_culling: bool = false,
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
      mesh := resource.get(g_meshes, data.handle)
      if mesh == nil do continue
      material := resource.get(g_materials, data.material)
      if material == nil do continue
      total_count += 1
      // Use GPU culling results if available, otherwise fall back to CPU culling
      visible := true
      when USE_GPU_CULLING {
        visible = is_node_visible(&self.scene_culling, u32(entry_index))
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

  when !USE_GPU_CULLING {
    if log_culling && total_count > 0 {
      log.infof("CPU Culling: %d/%d objects visible (%.1f%%)",
                visible_count, total_count,
                f32(visible_count) / f32(total_count) * 100.0)
    }
  }

  return
}


render :: proc(self: ^Engine) -> vk.Result {
  acquire_next_image(&self.swapchain) or_return
  mu.begin(&self.ui.ctx)
  command_buffer := self.command_buffers[g_frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  camera_uniform := data_buffer_get(&self.frames[g_frame_index].camera_uniform)
  camera_uniform.view = geometry.calculate_view_matrix(self.scene.camera)
  camera_uniform.projection = geometry.calculate_projection_matrix(
    self.scene.camera,
  )
  camera_uniform.viewport_size = {
    f32(self.swapchain.extent.width),
    f32(self.swapchain.extent.height),
  }
  camera_uniform.camera_near, camera_uniform.camera_far = geometry.camera_get_near_far(self.scene.camera)
  camera_uniform.camera_position = self.scene.camera.position
  frustum := geometry.make_frustum(
    camera_uniform.projection * camera_uniform.view,
  )
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  // dispatch computation early and doing other work while GPU is busy
  when USE_GPU_CULLING {
    // Update and perform GPU scene culling
    update_scene_culling_data(&self.scene_culling, &self.scene)
    perform_scene_culling_with_frustum(&self.scene_culling, command_buffer, frustum)

    // Memory barrier to ensure culling is complete before other operations
    visibility_buffer_barrier := vk.BufferMemoryBarrier {
      sType = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.SHADER_READ, .HOST_READ},
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      buffer = self.scene_culling.visibility_buffer[g_frame_index].buffer,
      offset = 0,
      size = vk.DeviceSize(self.scene_culling.visibility_buffer[g_frame_index].bytes_count),
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
      sType = .SUBMIT_INFO,
      commandBufferCount = 1,
      pCommandBuffers = &command_buffer,
    }
    vk.QueueSubmit(g_graphics_queue, 1, &submit_info, 0) or_return
    vk.QueueWaitIdle(g_graphics_queue) or_return

    // Begin command buffer again for the rest of the rendering
    vk.BeginCommandBuffer(
      command_buffer,
      &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
    ) or_return

    // Log culling results
    disabled_count, visible_count, total_count := count_visible_objects(&self.scene_culling)
    log.infof("GPU Culling: %d/%d objects visible (%.1f%%) %d disabled",
              visible_count, total_count,
              total_count > 0 ? (f32(visible_count) / f32(total_count) * 100.0) : 0.0,
              disabled_count,
    )

    // Debug: Compare with CPU culling for a few frames
    @(static) debug_frame_count: u32 = 0
    debug_frame_count += 1
    if debug_frame_count <= 5 {
      params_ptr := data_buffer_get(&self.scene_culling.params_buffer[g_frame_index])
      for i in 0..<6 {
        plane := params_ptr.frustum_planes[i]
        log.debugf("  GPU Plane %d: %v", i, plane)
      }

      // Compare with CPU frustum planes
      log.debugf("CPU Culling debug - Frustum planes:")
      for i in 0..<6 {
        plane := frustum.planes[i]
        log.debugf("  CPU Plane %d: %v", i, plane)
      }

      // Compare with CPU culling for debugging
      cpu_visible: u32 = 0
      cpu_total: u32 = 0
      for &entry, entry_index in self.scene.nodes.entries do if entry.active {
        node := &entry.item
        #partial switch data in node.attachment {
        case MeshAttachment:
          mesh := resource.get(g_meshes, data.handle)
          if mesh == nil do continue
          material := resource.get(g_materials, data.material)
          if material == nil do continue

          cpu_total += 1
          world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
          if geometry.frustum_test_aabb(frustum, world_aabb) {
            cpu_visible += 1
          }
        }
      }
      log.debugf("CPU Culling comparison: %d/%d objects visible (%.1f%%)",
                 cpu_visible, cpu_total,
                 cpu_total > 0 ? (f32(cpu_visible) / f32(cpu_total) * 100.0) : 0.0)
    }
  }

  compute_particles(&self.particle, command_buffer, self.scene.camera)
  lights := make([dynamic]LightData, 0)
  defer delete(lights)
  shadow_casters := make([dynamic]LightData, 0)
  defer delete(shadow_casters)
  for &entry, entry_index in self.scene.nodes.entries do if entry.active {
    node := &entry.item
    when USE_GPU_CULLING {
        visible := is_node_visible(&self.scene_culling, u32(entry_index))
        if !visible do continue
    }
    #partial switch light in &node.attachment {
    case PointLightAttachment:
      @(static) face_dirs := [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
      @(static) face_ups := [6][3]f32{{0, -1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, -1, 0}}
      data: PointLightData
      position := node.transform.world_matrix * [4]f32{0, 0, 0, 1}
      for i in 0 ..< 6 {
        data.views[i] = linalg.matrix4_look_at(position.xyz, position.xyz + face_dirs[i], face_ups[i])
      }
      data.proj = linalg.matrix4_perspective(math.PI * 0.5, 1.0, 0.01, light.radius)
      data.world = node.transform.world_matrix
      data.color = light.color
      data.position = position
      data.radius = light.radius
      append(&lights, data)
      if light.cast_shadow && len(shadow_casters) < MAX_SHADOW_MAPS {
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
      append(&lights, data)
    case SpotLightAttachment:
      data: SpotLightData
      data.position = node.transform.world_matrix * [4]f32{0, 0, 0, 1}
      data.direction = node.transform.world_matrix * [4]f32{0, -1, 0, 0}
      data.proj = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius)
      data.world = node.transform.world_matrix
      data.view = linalg.matrix4_look_at(data.position.xyz, data.position.xyz + data.direction.xyz, linalg.VECTOR3F32_Y_AXIS)
      data.radius = light.radius
      data.angle = light.angle
      data.color = light.color
      append(&lights, data)
      if light.cast_shadow && len(shadow_casters) < MAX_SHADOW_MAPS {
        append(&shadow_casters, data)
      }
    }
  }
  // log.debug("============ rendering shadow pass...============ ")
  // Transition all shadow maps to depth attachment optimal
  shadow_2d_images : [MAX_SHADOW_MAPS]vk.Image
  shadow_2d_count := 0
  for h, i in self.frames[g_frame_index].shadow_maps {
      b, ok := resource.get(g_image_2d_buffers, h)
      if !ok {
        log.debugf("Shadow map 2D texture not found for handle 0x%x at index %d", h, i)
        continue
      }
      shadow_2d_images[shadow_2d_count] = b.image
      shadow_2d_count += 1
  }
  if shadow_2d_count > 0 {
    transition_images(
      command_buffer,
      shadow_2d_images[:shadow_2d_count],
      .UNDEFINED,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      {.DEPTH},
      1,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    )
  }
  shadow_cube_images : [MAX_SHADOW_MAPS]vk.Image
  shadow_cube_count := 0
  for h, i in self.frames[g_frame_index].cube_shadow_maps {
      b, ok := resource.get(g_image_cube_buffers, h)
      if !ok {
        log.debugf("Shadow map cube texture not found for handle 0x%x at index %d", h, i)
        continue
      }
      shadow_cube_images[shadow_cube_count] = b.image
      shadow_cube_count += 1
  }
  if shadow_cube_count > 0 {
    transition_images(
      command_buffer,
      shadow_cube_images[:shadow_cube_count],
      .UNDEFINED,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      {.DEPTH},
      6,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    )
  }
  for node, i in shadow_casters {
    #partial switch light in node {
    case PointLightData:
      // Render 6 faces for point light shadow cubemap
      cube_shadow_handle := self.frames[g_frame_index].cube_shadow_maps[i]
      cube_shadow := resource.get(g_image_cube_buffers, cube_shadow_handle)
      for face in 0 ..< 6 {
        frustum := geometry.make_frustum(light.proj * light.views[face])
        shadow_render_input := generate_render_input(self, frustum)
        shadow_target: RenderTarget
        shadow_target.depth = cube_shadow.face_views[face]
        shadow_target.extent = {
          width  = cube_shadow.width,
          height = cube_shadow.height,
        }
        renderer_shadow_begin(shadow_target, command_buffer)
        renderer_shadow_render(
          &self.shadow,
          shadow_render_input,
          node,
          shadow_target,
          u32(i),
          u32(face),
          command_buffer,
        )
        renderer_shadow_end(command_buffer)
      }
    case DirectionalLightData:
      frustum := geometry.make_frustum(light.proj * light.view)
      shadow_render_input := generate_render_input(self, frustum)
      shadow_map_texture := resource.get(g_image_2d_buffers, self.frames[g_frame_index].shadow_maps[i])
      shadow_target: RenderTarget
      shadow_target.depth = shadow_map_texture.view
      shadow_target.extent = {
        width  = shadow_map_texture.width,
        height = shadow_map_texture.height,
      }
      renderer_shadow_begin(shadow_target, command_buffer)
      renderer_shadow_render(
        &self.shadow,
        shadow_render_input,
        node,
        shadow_target,
        u32(i),
        0,
        command_buffer,
      )
      renderer_shadow_end(command_buffer)
    case SpotLightData:
      frustum := geometry.make_frustum(light.proj * light.view)
      shadow_render_input := generate_render_input(self, frustum)
      shadow_map_texture := resource.get(g_image_2d_buffers, self.frames[g_frame_index].shadow_maps[i])
      shadow_target: RenderTarget
      shadow_target.depth = shadow_map_texture.view
      shadow_target.extent = {
        width  = shadow_map_texture.width,
        height = shadow_map_texture.height,
      }
      renderer_shadow_begin(shadow_target, command_buffer)
      renderer_shadow_render(
        &self.shadow,
        shadow_render_input,
        node,
        shadow_target,
        u32(i),
        0,
        command_buffer,
      )
      renderer_shadow_end(command_buffer)
    }
  }
  // Transition all shadow maps to shader read only optimal
  transition_images(
    command_buffer,
    shadow_2d_images[:shadow_2d_count],
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.DEPTH},
    1,
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.SHADER_READ},
  )
  transition_images(
    command_buffer,
    shadow_cube_images[:shadow_cube_count],
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.DEPTH},
    6,
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.SHADER_READ},
  )
  final_image := resource.get(g_image_2d_buffers, self.frames[g_frame_index].final_image)
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
  depth_target: RenderTarget
  depth_texture := resource.get(g_image_2d_buffers, self.frames[g_frame_index].depth_buffer)
  depth_target.depth = depth_texture.view
  depth_target.extent = self.swapchain.extent
  depth_input := generate_render_input(self, frustum, true)
  renderer_depth_prepass_begin(&depth_target, command_buffer)
  renderer_depth_prepass_render(
    &self.depth_prepass,
    &depth_input,
    command_buffer,
  )
  renderer_depth_prepass_end(command_buffer)
  // log.debug("============ rendering G-buffer pass... =============")
  // Transition G-buffer images to COLOR_ATTACHMENT_OPTIMAL
  frame := &self.frames[g_frame_index]
  gbuffer_position := resource.get(g_image_2d_buffers, frame.gbuffer_position)
  gbuffer_normal := resource.get(g_image_2d_buffers, frame.gbuffer_normal)
  gbuffer_albedo := resource.get(g_image_2d_buffers, frame.gbuffer_albedo)
  gbuffer_metallic := resource.get(g_image_2d_buffers, frame.gbuffer_metallic_roughness)
  gbuffer_emissive := resource.get(g_image_2d_buffers, frame.gbuffer_emissive)

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
  gbuffer_target: RenderTarget
  gbuffer_target.position = gbuffer_position.view
  gbuffer_target.normal = gbuffer_normal.view
  gbuffer_target.albedo = gbuffer_albedo.view
  gbuffer_target.metallic = gbuffer_metallic.view
  gbuffer_target.emissive = gbuffer_emissive.view
  gbuffer_target.depth = resource.get(g_image_2d_buffers, frame.depth_buffer).view
  gbuffer_target.extent = self.swapchain.extent
  gbuffer_input := depth_input
  renderer_gbuffer_begin(&gbuffer_target, command_buffer)
  renderer_gbuffer_render(
    &self.gbuffer,
    &gbuffer_input,
    &gbuffer_target,
    command_buffer,
  )
  renderer_gbuffer_end(&gbuffer_target, command_buffer)
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
  render_target: RenderTarget
  render_target.final = final_image.view
  render_target.depth = resource.get(g_image_2d_buffers, frame.depth_buffer).view
  render_target.extent = self.swapchain.extent
  // Ambient pass
  renderer_ambient_begin(&self.ambient, render_target, command_buffer)
  renderer_ambient_render(
    &self.ambient,
    self.scene.camera.position,
    command_buffer,
  )
  renderer_ambient_end(command_buffer)
  // Per-light additive pass
  renderer_lighting_begin(&self.main, render_target, command_buffer)
  renderer_lighting_render(
    &self.main,
    lights,
    self.scene.camera.position,
    command_buffer,
  )
  renderer_lighting_end(command_buffer)
  // log.debug("============ rendering particles... =============")
  renderer_particle_begin(&self.particle, command_buffer, render_target)
  renderer_particle_render(&self.particle, command_buffer)
  renderer_particle_end(command_buffer)

  // Transparent & wireframe pass
  renderer_transparent_begin(&self.transparent, render_target, command_buffer)
  renderer_transparent_render(
    &self.transparent,
    gbuffer_input,
    render_target,
    command_buffer,
  )
  renderer_transparent_end(&self.transparent, command_buffer)

  // log.debug("============ rendering post processes... =============")
  transition_image_to_shader_read(
    command_buffer,
    final_image.image,
  )
  renderer_postprocess_begin(
    &self.postprocess,
    command_buffer,
    self.frames[g_frame_index],
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
  }
  if self.render2d_proc != nil {
    self.render2d_proc(self, &self.ui.ctx)
  }
  mu.end(&self.ui.ctx)
  // log.debug("============ rendering UI... =============")
  renderer_ui_begin(
    &self.ui,
    command_buffer,
    self.swapchain.views[self.swapchain.image_index],
    self.swapchain.extent,
  )
  renderer_ui_render(&self.ui, command_buffer)
  renderer_ui_end(&self.ui, command_buffer)
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
    // if frame > 3 do break
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

frame_data_init :: proc(
  frame: ^FrameData,
  swapchain: ^Swapchain,
) -> vk.Result {
  // G-buffer position (high precision for world position)
  frame.gbuffer_position, _ = create_empty_texture_2d(
    swapchain.extent.width,
    swapchain.extent.height,
    .R32G32B32A32_SFLOAT,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  log.debugf("created g buffer position image")

  // Final color image (matches swapchain format)
  frame.final_image, _ = create_empty_texture_2d(
    swapchain.extent.width,
    swapchain.extent.height,
    swapchain.format.format,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  log.debugf("created g buffer final image")

  // G-buffer normal (standard precision)
  frame.gbuffer_normal, _ = create_empty_texture_2d(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  log.debugf("created g buffer normal image")

  // G-buffer albedo (standard precision)
  frame.gbuffer_albedo, _ = create_empty_texture_2d(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  log.debugf("created g buffer albedo image")

  // G-buffer metallic/roughness (standard precision)
  frame.gbuffer_metallic_roughness, _ = create_empty_texture_2d(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  log.debugf("created g buffer metallic roughness image")

  // G-buffer emissive (standard precision)
  frame.gbuffer_emissive, _ = create_empty_texture_2d(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED},
  ) or_return
  log.debugf("created g buffer emissive image")

  // Depth buffer (special case - still needs manual initialization for depth aspect)
  frame.depth_buffer, _ = create_empty_texture_2d(
    swapchain.extent.width,
    swapchain.extent.height,
    .D32_SFLOAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  ) or_return
  log.debugf("created g buffer depth image")
  for j in 0 ..< MAX_SHADOW_MAPS {
    frame.shadow_maps[j], _ = create_empty_texture_2d(
      SHADOW_MAP_SIZE,
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    frame.cube_shadow_maps[j], _ = create_empty_texture_cube(
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
  }
  log.debugf("created shadow map image")
  frame.camera_uniform = create_host_visible_buffer(
    CameraUniform,
    MAX_CAMERA_UNIFORMS,
    {.UNIFORM_BUFFER},
  ) or_return
  return .SUCCESS
}

frame_data_deinit :: proc(frame: ^FrameData) {
  data_buffer_deinit(&frame.camera_uniform)

  // Release 2D texture handles with immediate cleanup
  resource.free(&g_image_2d_buffers, frame.final_image, image_buffer_deinit)
  resource.free(&g_image_2d_buffers, frame.gbuffer_position, image_buffer_deinit)
  resource.free(&g_image_2d_buffers, frame.gbuffer_normal, image_buffer_deinit)
  resource.free(&g_image_2d_buffers, frame.gbuffer_albedo, image_buffer_deinit)
  resource.free(&g_image_2d_buffers, frame.gbuffer_metallic_roughness, image_buffer_deinit)
  resource.free(&g_image_2d_buffers, frame.gbuffer_emissive, image_buffer_deinit)
  resource.free(&g_image_2d_buffers, frame.depth_buffer, image_buffer_deinit)

  // Release shadow map handles with immediate cleanup
  for handle in frame.shadow_maps {
    resource.free(&g_image_2d_buffers, handle, image_buffer_deinit)
  }
  for handle in frame.cube_shadow_maps {
    resource.free(&g_image_cube_buffers, handle, cube_depth_texture_deinit)
  }
}
