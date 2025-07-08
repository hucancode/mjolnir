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
MAX_LIGHTS :: 10
SHADOW_MAP_SIZE :: 512
MAX_SHADOW_MAPS :: MAX_LIGHTS
MAX_CAMERA_UNIFORMS :: 16
MAX_TEXTURES :: 50

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

PointLightData :: struct {
  views:    [6]linalg.Matrix4f32,
  proj:     linalg.Matrix4f32,
  world:    linalg.Matrix4f32,
  color:    linalg.Vector4f32,
  position: linalg.Vector4f32,
  radius:   f32,
}

SpotLightData :: struct {
  view:      linalg.Matrix4f32,
  proj:      linalg.Matrix4f32,
  world:     linalg.Matrix4f32,
  color:     linalg.Vector4f32,
  position:  linalg.Vector4f32,
  direction: linalg.Vector4f32,
  radius:    f32,
  angle:     f32,
}

DirectionalLightData :: struct {
  view:      linalg.Matrix4f32,
  proj:      linalg.Matrix4f32,
  world:     linalg.Matrix4f32,
  color:     linalg.Vector4f32,
  direction: linalg.Vector4f32,
}

LightData :: union {
  PointLightData,
  SpotLightData,
  DirectionalLightData,
}

CameraUniform :: struct {
  view:          linalg.Matrix4f32,
  projection:    linalg.Matrix4f32,
  viewport_size: [2]f32,
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

// Generate render input for a given frustum (camera or light)
generate_render_input :: proc(
  self: ^Engine,
  frustum: geometry.Frustum,
) -> (
  ret: RenderInput,
) {
  ret.batches = make(
    map[BatchKey][dynamic]BatchData,
    allocator = context.temp_allocator,
  )
  for &entry in self.scene.nodes.entries do if entry.active {
    node := &entry.item
    #partial switch data in node.attachment {
    case MeshAttachment:
      mesh := resource.get(g_meshes, data.handle)
      if mesh == nil do continue
      material := resource.get(g_materials, data.material)
      if material == nil do continue
      world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
      if !geometry.frustum_test_aabb(frustum, world_aabb) do continue
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

FrameData :: struct {
  camera_uniform:             DataBuffer(CameraUniform),
  shadow_maps:                [MAX_SHADOW_MAPS]ImageBuffer,
  cube_shadow_maps:           [MAX_SHADOW_MAPS]CubeImageBuffer,
  // G-buffer images
  gbuffer_position:           ImageBuffer,
  gbuffer_normal:             ImageBuffer,
  gbuffer_albedo:             ImageBuffer,
  gbuffer_metallic_roughness: ImageBuffer,
  gbuffer_emissive:           ImageBuffer,
  depth_buffer:               ImageBuffer,
  final_image:                ImageBuffer,
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
  DESCRIPTOR_PER_FRAME :: 3
  writes: [MAX_FRAMES_IN_FLIGHT * DESCRIPTOR_PER_FRAME]vk.WriteDescriptorSet
  shadow_image_infos: [MAX_FRAMES_IN_FLIGHT *
  MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  cube_shadow_image_infos: [MAX_FRAMES_IN_FLIGHT *
  MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame_data_init(&self.frames[i], &self.swapchain)
    log.debugf("write frame descriptor sets for frame %d", i)
    for j in 0 ..< MAX_SHADOW_MAPS {
      shadow_image_infos[i * MAX_SHADOW_MAPS + j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = self.frames[i].shadow_maps[j].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    for j in 0 ..< MAX_SHADOW_MAPS {
      cube_shadow_image_infos[i * MAX_SHADOW_MAPS + j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = self.frames[i].cube_shadow_maps[j].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
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
    writes[i * DESCRIPTOR_PER_FRAME + 1] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = g_shadow_descriptor_sets[i],
      dstBinding      = 0,
      descriptorCount = MAX_SHADOW_MAPS,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = raw_data(shadow_image_infos[i * MAX_SHADOW_MAPS:]),
    }
    writes[i * DESCRIPTOR_PER_FRAME + 2] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = g_shadow_descriptor_sets[i],
      dstBinding      = 1,
      descriptorCount = MAX_SHADOW_MAPS,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = raw_data(
        cube_shadow_image_infos[i * MAX_SHADOW_MAPS:],
      ),
    }
  }
  log.debugf("vk.UpdateDescriptorSets %d", len(writes))
  // TODO: investigate this, why do we need this
  vk.DeviceWaitIdle(g_device)
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
  renderer_shadow_init(&self.shadow, .D32_SFLOAT) or_return
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
    ff.position = entry.item.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
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
  // Recreate all images that depend on swapchain dimensions
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame_data_deinit(&engine.frames[i])
    frame_data_init(&engine.frames[i], &engine.swapchain)
    // this code is copied from init procedure. TODO: deduplicate this
    shadow_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
    for j in 0 ..< MAX_SHADOW_MAPS {
      shadow_image_infos[j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = engine.frames[i].shadow_maps[j].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    cube_shadow_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
    for j in 0 ..< MAX_SHADOW_MAPS {
      cube_shadow_image_infos[j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = engine.frames[i].cube_shadow_maps[j].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_camera_descriptor_sets[i],
        dstBinding = 0,
        descriptorCount = 1,
        descriptorType = .UNIFORM_BUFFER,
        pBufferInfo = &{
          buffer = engine.frames[i].camera_uniform.buffer,
          range = size_of(CameraUniform),
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_shadow_descriptor_sets[i],
        dstBinding = 0,
        descriptorCount = len(shadow_image_infos),
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = raw_data(shadow_image_infos[:]),
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_shadow_descriptor_sets[i],
        dstBinding = 1,
        descriptorCount = len(cube_shadow_image_infos),
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = raw_data(cube_shadow_image_infos[:]),
      },
    }
    // TODO: investigate this, why do we need this
    vk.DeviceWaitIdle(g_device)
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
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
  frustum := geometry.make_frustum(
    camera_uniform.projection * camera_uniform.view,
  )
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  // dispatch computation early and doing other work while GPU is busy
  compute_particles(&self.particle, command_buffer)
  lights := make([dynamic]LightData, 0)
  defer delete(lights)
  shadow_casters := make([dynamic]LightData, 0)
  defer delete(shadow_casters)
  for &entry in self.scene.nodes.entries do if entry.active {
    #partial switch light in &entry.item.attachment {
    case PointLightAttachment:
      @(static) face_dirs := [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
      @(static) face_ups := [6][3]f32{{0, -1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, -1, 0}}
      data: PointLightData
      position := entry.item.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      for i in 0 ..< 6 {
        data.views[i] = linalg.matrix4_look_at(position.xyz, position.xyz + face_dirs[i], face_ups[i])
      }
      data.proj = linalg.matrix4_perspective(math.PI * 0.5, 1.0, 0.01, light.radius)
      data.world = entry.item.transform.world_matrix
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
      data.direction = entry.item.transform.world_matrix * linalg.Vector4f32{0, 0, -1, 0}
      data.proj = linalg.matrix_ortho3d(-ortho_size, ortho_size, -ortho_size, ortho_size, 0.1, 9999.0)
      data.view = linalg.matrix4_look_at(linalg.Vector3f32{}, data.direction.xyz, linalg.VECTOR3F32_Y_AXIS)
      data.world = entry.item.transform.world_matrix
      data.color = light.color
      append(&lights, data)
    case SpotLightAttachment:
      data: SpotLightData
      data.position = entry.item.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      data.direction = entry.item.transform.world_matrix * linalg.Vector4f32{0, -1, 0, 0}
      data.proj = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius)
      data.world = entry.item.transform.world_matrix
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
  transition_images(
    command_buffer,
    self.frames[g_frame_index].shadow_maps[:],
    .UNDEFINED,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    {.DEPTH},
    1,
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
  )
  transition_images(
    command_buffer,
    self.frames[g_frame_index].cube_shadow_maps[:],
    .UNDEFINED,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    {.DEPTH},
    6,
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
  )
  for node, i in shadow_casters {
    #partial switch light in node {
    case PointLightData:
      // Render 6 faces for point light shadow cubemap
      cube_shadow := &self.frames[g_frame_index].cube_shadow_maps[i]
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
      shadow_map_texture := &self.frames[g_frame_index].shadow_maps[i]
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
      shadow_map_texture := &self.frames[g_frame_index].shadow_maps[i]
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
    self.frames[g_frame_index].shadow_maps[:],
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
    self.frames[g_frame_index].cube_shadow_maps[:],
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
    {.DEPTH},
    6,
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.SHADER_READ},
  )
  transition_image(
    command_buffer,
    self.frames[g_frame_index].final_image.image,
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
  depth_target.depth = self.frames[g_frame_index].depth_buffer.view
  depth_target.extent = self.swapchain.extent
  depth_input := generate_render_input(self, frustum)
  renderer_depth_prepass_begin(&depth_target, command_buffer)
  renderer_depth_prepass_render(
    &self.depth_prepass,
    &depth_input,
    command_buffer,
  )
  renderer_depth_prepass_end(command_buffer)
  // log.debug("============ rendering G-buffer pass... =============")
  // Transition G-buffer images to COLOR_ATTACHMENT_OPTIMAL
  gbuffer_images := [?]vk.Image {
    self.frames[g_frame_index].gbuffer_position.image,
    self.frames[g_frame_index].gbuffer_normal.image,
    self.frames[g_frame_index].gbuffer_albedo.image,
    self.frames[g_frame_index].gbuffer_metallic_roughness.image,
    self.frames[g_frame_index].gbuffer_emissive.image,
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
  gbuffer_target.position = self.frames[g_frame_index].gbuffer_position.view
  gbuffer_target.normal = self.frames[g_frame_index].gbuffer_normal.view
  gbuffer_target.albedo = self.frames[g_frame_index].gbuffer_albedo.view
  gbuffer_target.metallic =
    self.frames[g_frame_index].gbuffer_metallic_roughness.view
  gbuffer_target.emissive = self.frames[g_frame_index].gbuffer_emissive.view
  gbuffer_target.depth = self.frames[g_frame_index].depth_buffer.view
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
  render_target.final = self.frames[g_frame_index].final_image.view
  render_target.depth = self.frames[g_frame_index].depth_buffer.view
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
  renderer_particle_begin(
    &self.particle,
    command_buffer,
    RenderTarget {
      final = self.frames[g_frame_index].final_image.view,
      depth = self.frames[g_frame_index].depth_buffer.view,
      extent = self.swapchain.extent,
    },
  )
  renderer_particle_render(&self.particle, command_buffer)
  renderer_particle_end(command_buffer)
  // log.debug("============ rendering post processes... =============")
  transition_image_to_shader_read(
    command_buffer,
    self.frames[g_frame_index].final_image.image,
  )
  renderer_postprocess_begin(
    &self.postprocess,
    command_buffer,
    self.frames[g_frame_index].final_image.view,
    self.frames[g_frame_index].depth_buffer.view,
    self.frames[g_frame_index].gbuffer_normal.view,
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
    // if frame > 1 do break
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
  frame.gbuffer_position = malloc_image_buffer(
    swapchain.extent.width,
    swapchain.extent.height,
    .R32G32B32A32_SFLOAT,
    .OPTIMAL,
    {.COLOR_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  frame.gbuffer_position.view = create_image_view(
    frame.gbuffer_position.image,
    .R32G32B32A32_SFLOAT,
    {.COLOR},
  ) or_return
  frame.final_image = malloc_image_buffer(
    swapchain.extent.width,
    swapchain.extent.height,
    swapchain.format.format,
    .OPTIMAL,
    {.COLOR_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  frame.final_image.view = create_image_view(
    frame.final_image.image,
    swapchain.format.format,
    {.COLOR},
  ) or_return
  frame.gbuffer_normal = malloc_image_buffer(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    .OPTIMAL,
    {.COLOR_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  frame.gbuffer_normal.view = create_image_view(
    frame.gbuffer_normal.image,
    .R8G8B8A8_UNORM,
    {.COLOR},
  ) or_return
  frame.gbuffer_albedo = malloc_image_buffer(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    .OPTIMAL,
    {.COLOR_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  frame.gbuffer_albedo.view = create_image_view(
    frame.gbuffer_albedo.image,
    .R8G8B8A8_UNORM,
    {.COLOR},
  ) or_return
  frame.gbuffer_metallic_roughness = malloc_image_buffer(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    .OPTIMAL,
    {.COLOR_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  frame.gbuffer_metallic_roughness.view = create_image_view(
    frame.gbuffer_metallic_roughness.image,
    .R8G8B8A8_UNORM,
    {.COLOR},
  ) or_return
  frame.gbuffer_emissive = malloc_image_buffer(
    swapchain.extent.width,
    swapchain.extent.height,
    .R8G8B8A8_UNORM,
    .OPTIMAL,
    {.COLOR_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  frame.gbuffer_emissive.view = create_image_view(
    frame.gbuffer_emissive.image,
    .R8G8B8A8_UNORM,
    {.COLOR},
  ) or_return
  depth_image_init(
    &frame.depth_buffer,
    swapchain.extent.width,
    swapchain.extent.height,
    .D32_SFLOAT,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  ) or_return
  for j in 0 ..< MAX_SHADOW_MAPS {
    depth_image_init(
      &frame.shadow_maps[j],
      SHADOW_MAP_SIZE,
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    cube_depth_texture_init(
      &frame.cube_shadow_maps[j],
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
  }
  frame.camera_uniform = create_host_visible_buffer(
    CameraUniform,
    MAX_CAMERA_UNIFORMS,
    {.UNIFORM_BUFFER},
  ) or_return
  return .SUCCESS
}

frame_data_deinit :: proc(frame: ^FrameData) {
  data_buffer_deinit(&frame.camera_uniform)
  image_buffer_deinit(&frame.final_image)
  for &t in frame.shadow_maps do image_buffer_deinit(&t)
  for &t in frame.cube_shadow_maps do cube_depth_texture_deinit(&t)
  image_buffer_deinit(&frame.gbuffer_position)
  image_buffer_deinit(&frame.gbuffer_normal)
  image_buffer_deinit(&frame.gbuffer_albedo)
  image_buffer_deinit(&frame.gbuffer_metallic_roughness)
  image_buffer_deinit(&frame.gbuffer_emissive)
  image_buffer_deinit(&frame.depth_buffer)
}
