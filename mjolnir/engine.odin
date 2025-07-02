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

LightUniform :: struct {
  view:       linalg.Matrix4f32, // 64 bytes
  proj:       linalg.Matrix4f32, // 64 bytes
  color:      linalg.Vector4f32, // 16 bytes
  position:   linalg.Vector4f32, // 16 bytes
  direction:  linalg.Vector4f32, // 16 bytes
  kind:       LightKind, // 4 bytes
  angle:      f32, // 4 bytes (spot light angle)
  radius:     f32, // 4 bytes (point/spot light radius)
  has_shadow: b32, // 4 bytes
}

CameraUniform :: struct {
  view:       linalg.Matrix4f32,
  projection: linalg.Matrix4f32,
}

LightArrayUniform :: struct {
  lights:      [MAX_LIGHTS]LightUniform,
  light_count: u32,
  padding:     [3]u32,
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

BatchingContext :: struct {
  engine:  ^Engine,
  frustum: geometry.Frustum,
  lights:  [dynamic]LightUniform,
  batches: map[BatchKey][dynamic]BatchData,
}

// RenderInput groups render batches and other per-frame data for the renderer.
RenderInput :: struct {
  batches: map[BatchKey][dynamic]BatchData,
}

// RenderTarget describes the output textures for a render pass.
RenderTarget :: struct {
  final:    vk.ImageView,
  normal:   vk.ImageView,
  albedo:   vk.ImageView,
  metallic: vk.ImageView,
  emissive: vk.ImageView,
  depth:    vk.ImageView,
  extra1:   vk.ImageView,
  extra2:   vk.ImageView,
  width:    u32,
  height:   u32,
  extent:   vk.Extent2D,
}


// Generate render input for a given frustum (camera or light)
generate_render_input_for_frustum :: proc(
  self: ^Engine,
  frustum: geometry.Frustum,
) -> RenderInput {
  batching_ctx := BatchingContext {
    engine  = self,
    frustum = frustum,
    lights  = make([dynamic]LightUniform),
    batches = make(map[BatchKey][dynamic]BatchData),
  }
  populate_render_batches(&batching_ctx)
  return RenderInput{batches = batching_ctx.batches}
}

generate_render_input :: proc(self: ^Engine) -> RenderInput {
  return generate_render_input_for_frustum(
    self,
    geometry.camera_make_frustum(self.scene.camera),
  )
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
  light_uniform:              DataBuffer(LightArrayUniform),
  shadow_maps:                [MAX_SHADOW_MAPS]ImageBuffer,
  cube_shadow_maps:           [MAX_SHADOW_MAPS]CubeImageBuffer,
  // G-buffer images
  gbuffer_normal:             ImageBuffer,
  gbuffer_albedo:             ImageBuffer,
  gbuffer_metallic_roughness: ImageBuffer,
  gbuffer_emissive:           ImageBuffer,
  depth_buffer:               ImageBuffer,
  final_image:                ImageBuffer,
  // Add more per-frame resources as needed (gbuffer, particles, etc.)
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
  main:                  RendererMain,
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
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame_data_init(&self.frames[i], &self.swapchain)
    shadow_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
    for j in 0 ..< MAX_SHADOW_MAPS {
      shadow_image_infos[j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = self.frames[i].shadow_maps[j].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    cube_shadow_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
    for j in 0 ..< MAX_SHADOW_MAPS {
      cube_shadow_image_infos[j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = self.frames[i].cube_shadow_maps[j].view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_camera_descriptor_sets[i],
        dstBinding = 0,
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType = .UNIFORM_BUFFER,
        pBufferInfo = &{
          buffer = self.frames[i].camera_uniform.buffer,
          range = size_of(CameraUniform),
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_lights_descriptor_sets[i],
        dstBinding = 0,
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType = .UNIFORM_BUFFER,
        pBufferInfo = &{
          buffer = self.frames[i].light_uniform.buffer,
          range = size_of(LightArrayUniform),
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_lights_descriptor_sets[i],
        dstBinding = 1,
        dstArrayElement = 0,
        descriptorCount = len(shadow_image_infos),
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = raw_data(shadow_image_infos[:]),
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_lights_descriptor_sets[i],
        dstBinding = 2,
        dstArrayElement = 0,
        descriptorCount = len(cube_shadow_image_infos),
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = raw_data(cube_shadow_image_infos[:]),
      },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
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
  for &f in self.frames do frame_data_deinit(&f)
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
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType = .UNIFORM_BUFFER,
        pBufferInfo = &{
          buffer = engine.frames[i].camera_uniform.buffer,
          range = size_of(CameraUniform),
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_lights_descriptor_sets[i],
        dstBinding = 0,
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType = .UNIFORM_BUFFER,
        pBufferInfo = &{
          buffer = engine.frames[i].light_uniform.buffer,
          range = size_of(LightArrayUniform),
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_lights_descriptor_sets[i],
        dstBinding = 1,
        dstArrayElement = 0,
        descriptorCount = len(shadow_image_infos),
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = raw_data(shadow_image_infos[:]),
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = g_lights_descriptor_sets[i],
        dstBinding = 2,
        dstArrayElement = 0,
        descriptorCount = len(cube_shadow_image_infos),
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = raw_data(cube_shadow_image_infos[:]),
      },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  }
  renderer_postprocess_recreate_images(
    &engine.postprocess,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
    engine.swapchain.format.format,
  ) or_return
  return .SUCCESS
}

update_visible_lights :: proc(self: ^Engine) {
  light_uniform := data_buffer_get(&self.frames[g_frame_index].light_uniform)
  light_uniform.light_count = 0
  // Traverse scene and update/add visible lights
  for entry in self.scene.nodes.entries do if entry.active {
    node := entry.item
    light_info := &light_uniform.lights[light_uniform.light_count]
    #partial switch light in node.attachment {
    case PointLightAttachment:
      position := node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      light_info.kind = .POINT
      light_info.color = light.color
      light_info.radius = light.radius
      light_info.has_shadow = b32(light.cast_shadow)
      light_info.position = position
      light_info.proj = linalg.matrix4_perspective(math.PI * 0.5, 1.0, 0.01, light.radius)
      // point light needs 6 view matrices, it will not be calculated here
      light_uniform.light_count += 1
    case DirectionalLightAttachment:
      ortho_size: f32 = 20.0
      position := node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      direction := node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0}
      light_info.kind = .DIRECTIONAL
      light_info.color = light.color
      light_info.has_shadow = b32(light.cast_shadow)
      light_info.position = position
      light_info.direction = direction
      light_info.proj = linalg.matrix_ortho3d(-ortho_size, ortho_size, -ortho_size, ortho_size, 0.1, 9999.0)
      light_info.view = linalg.matrix4_look_at(position.xyz, position.xyz + direction.xyz, linalg.VECTOR3F32_Y_AXIS)
      light_uniform.light_count += 1
    case SpotLightAttachment:
      position := node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
      direction := node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0}
      light_info.kind = .SPOT
      light_info.color = light.color
      light_info.radius = light.radius
      light_info.angle = light.angle
      light_info.has_shadow = b32(light.cast_shadow)
      light_info.position = position
      light_info.direction = direction
      light_info.proj = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius)
      light_info.view = linalg.matrix4_look_at(position.xyz, position.xyz + direction.xyz, linalg.VECTOR3F32_Y_AXIS)
      light_uniform.light_count += 1
    case:
      continue
    }
    if light_uniform.light_count >= MAX_LIGHTS {
      break
    }
  }
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
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  // dispatch computation early and doing other work while GPU is busy
  compute_particles(&self.particle, command_buffer)
  update_visible_lights(self)
  // log.debug("============ rendering shadow pass...============ ")
  initial_barriers := make([dynamic]vk.ImageMemoryBarrier, 0)
  defer delete(initial_barriers)
  light_uniform := data_buffer_get(&self.frames[g_frame_index].light_uniform)
  // Transition all shadow maps to depth attachment optimal
  for i in 0 ..< light_uniform.light_count {
    light := &light_uniform.lights[i]
    if !light.has_shadow do continue
    switch light.kind {
    case .POINT:
      append(
        &initial_barriers,
        vk.ImageMemoryBarrier {
          sType = .IMAGE_MEMORY_BARRIER,
          oldLayout = .UNDEFINED,
          newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          image = self.frames[g_frame_index].cube_shadow_maps[i].image,
          subresourceRange = {
            aspectMask = {.DEPTH},
            baseMipLevel = 0,
            levelCount = 1,
            baseArrayLayer = 0,
            layerCount = 6,
          },
          dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        },
      )
    case .DIRECTIONAL, .SPOT:
      append(
        &initial_barriers,
        vk.ImageMemoryBarrier {
          sType = .IMAGE_MEMORY_BARRIER,
          oldLayout = .UNDEFINED,
          newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          image = self.frames[g_frame_index].shadow_maps[i].image,
          subresourceRange = {
            aspectMask = {.DEPTH},
            baseMipLevel = 0,
            levelCount = 1,
            baseArrayLayer = 0,
            layerCount = 1,
          },
          dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        },
      )
    }
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {},
    0,
    nil,
    0,
    nil,
    u32(len(initial_barriers)),
    raw_data(initial_barriers),
  )
  for i in 0 ..< light_uniform.light_count {
    light := &light_uniform.lights[i]
    if !light.has_shadow do continue
    switch light.kind {
    case .POINT:
      // Render 6 faces for point light shadow cubemap
      cube_shadow := &self.frames[g_frame_index].cube_shadow_maps[i]
      for face in 0 ..< 6 {
        @(static) face_dirs := [6][3]f32 {
          {1, 0, 0},
          {-1, 0, 0},
          {0, 1, 0},
          {0, -1, 0},
          {0, 0, 1},
          {0, 0, -1},
        }
        @(static) face_ups := [6][3]f32 {
          {0, -1, 0},
          {0, -1, 0},
          {0, 0, 1},
          {0, 0, -1},
          {0, -1, 0},
          {0, -1, 0},
        }
        light.view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + face_dirs[face],
          face_ups[face],
        )
        frustum := geometry.make_frustum(light.proj * light.view)
        shadow_render_input := generate_render_input_for_frustum(self, frustum)
        shadow_target: RenderTarget
        shadow_target.depth = cube_shadow.face_views[face]
        shadow_target.extent = {
          width  = cube_shadow.width,
          height = cube_shadow.height,
        }
        shadow_target.width = cube_shadow.width
        shadow_target.height = cube_shadow.height
        renderer_shadow_begin(shadow_target, command_buffer)
        renderer_shadow_render(
          &self.shadow,
          shadow_render_input,
          light,
          shadow_target,
          u32(i),
          u32(face),
          command_buffer,
        )
        renderer_shadow_end(command_buffer)
      }
    case .DIRECTIONAL, .SPOT:
      frustum := geometry.make_frustum(light.proj * light.view)
      shadow_render_input := generate_render_input_for_frustum(self, frustum)
      shadow_map_texture := &self.frames[g_frame_index].shadow_maps[i]
      shadow_target: RenderTarget
      shadow_target.depth = shadow_map_texture.view
      shadow_target.extent = {
        width  = shadow_map_texture.width,
        height = shadow_map_texture.height,
      }
      shadow_target.width = shadow_map_texture.width
      shadow_target.height = shadow_map_texture.height
      renderer_shadow_begin(shadow_target, command_buffer)
      renderer_shadow_render(
        &self.shadow,
        shadow_render_input,
        light,
        shadow_target,
        u32(i),
        0,
        command_buffer,
      )
      renderer_shadow_end(command_buffer)
    }
  }
  final_barriers := make([dynamic]vk.ImageMemoryBarrier, 0)
  defer delete(final_barriers)
  // Transition all shadow maps to depth attachment optimal
  for i in 0 ..< light_uniform.light_count {
    light := &light_uniform.lights[i]
    if !light.has_shadow do continue
    switch light.kind {
    case .POINT:
      append(
        &final_barriers,
        vk.ImageMemoryBarrier {
          sType = .IMAGE_MEMORY_BARRIER,
          oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          newLayout = .SHADER_READ_ONLY_OPTIMAL,
          srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          image = self.frames[g_frame_index].cube_shadow_maps[i].image,
          subresourceRange = {
            aspectMask = {.DEPTH},
            baseMipLevel = 0,
            levelCount = 1,
            baseArrayLayer = 0,
            layerCount = 6,
          },
          dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        },
      )
    case .DIRECTIONAL, .SPOT:
      append(
        &final_barriers,
        vk.ImageMemoryBarrier {
          sType = .IMAGE_MEMORY_BARRIER,
          oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          newLayout = .SHADER_READ_ONLY_OPTIMAL,
          srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          image = self.frames[g_frame_index].shadow_maps[i].image,
          subresourceRange = {
            aspectMask = {.DEPTH},
            baseMipLevel = 0,
            levelCount = 1,
            baseArrayLayer = 0,
            layerCount = 1,
          },
          dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        },
      )
    }
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    u32(len(final_barriers)),
    raw_data(final_barriers),
  )
  prepare_image_for_render(
    command_buffer,
    self.frames[g_frame_index].final_image.image,
  )
  // log.debug("============ rendering depth pre-pass... =============")
  depth_target: RenderTarget
  depth_target.depth = self.frames[g_frame_index].depth_buffer.view
  depth_target.extent = self.swapchain.extent
  depth_target.width = self.swapchain.extent.width
  depth_target.height = self.swapchain.extent.height
  depth_input := generate_render_input(self)
  renderer_depth_prepass_begin(&depth_target, command_buffer)
  renderer_depth_prepass_render(
    &self.depth_prepass,
    &depth_input,
    command_buffer,
  )
  renderer_depth_prepass_end(command_buffer)
  if true {
    // log.debug("============ rendering G-buffer pass... =============")
    prepare_image_for_render(
      command_buffer,
      self.frames[g_frame_index].gbuffer_normal.image,
      .COLOR_ATTACHMENT_OPTIMAL,
    )
    prepare_image_for_render(
      command_buffer,
      self.frames[g_frame_index].gbuffer_albedo.image,
      .COLOR_ATTACHMENT_OPTIMAL,
    )
    prepare_image_for_render(
      command_buffer,
      self.frames[g_frame_index].gbuffer_metallic_roughness.image,
      .COLOR_ATTACHMENT_OPTIMAL,
    )
    prepare_image_for_render(
      command_buffer,
      self.frames[g_frame_index].gbuffer_emissive.image,
      .COLOR_ATTACHMENT_OPTIMAL,
    )
    gbuffer_target: RenderTarget
    gbuffer_target.normal = self.frames[g_frame_index].gbuffer_normal.view
    gbuffer_target.albedo = self.frames[g_frame_index].gbuffer_albedo.view
    gbuffer_target.metallic =
      self.frames[g_frame_index].gbuffer_metallic_roughness.view
    gbuffer_target.emissive = self.frames[g_frame_index].gbuffer_emissive.view
    gbuffer_target.depth = self.frames[g_frame_index].depth_buffer.view
    gbuffer_target.extent = self.swapchain.extent
    gbuffer_target.width = self.swapchain.extent.width
    gbuffer_target.height = self.swapchain.extent.height
    gbuffer_input := generate_render_input(self)
    renderer_gbuffer_begin(&gbuffer_target, command_buffer)
    renderer_gbuffer_render(
      &self.gbuffer,
      &gbuffer_input,
      &gbuffer_target,
      command_buffer,
    )
    renderer_gbuffer_end(&gbuffer_target, command_buffer)

    prepare_image_for_shader_read(
      command_buffer,
      self.frames[g_frame_index].gbuffer_normal.image,
    )
    prepare_image_for_shader_read(
      command_buffer,
      self.frames[g_frame_index].gbuffer_albedo.image,
    )
    prepare_image_for_shader_read(
      command_buffer,
      self.frames[g_frame_index].gbuffer_metallic_roughness.image,
    )
    prepare_image_for_shader_read(
      command_buffer,
      self.frames[g_frame_index].gbuffer_emissive.image,
    )
    // log.debug("============ rendering main pass... =============")
    // Prepare RenderTarget and RenderInput for decoupled renderer
    render_target: RenderTarget
    render_target.final = self.frames[g_frame_index].final_image.view
    render_target.depth = self.frames[g_frame_index].depth_buffer.view
    render_target.normal = self.frames[g_frame_index].gbuffer_normal.view
    render_target.albedo = self.frames[g_frame_index].gbuffer_albedo.view
    render_target.metallic =
      self.frames[g_frame_index].gbuffer_metallic_roughness.view
    render_target.emissive = self.frames[g_frame_index].gbuffer_emissive.view
    render_target.extent = self.swapchain.extent
    render_target.width = self.swapchain.extent.width
    render_target.height = self.swapchain.extent.height
    render_input := generate_render_input(self)
    renderer_main_begin(render_target, command_buffer)
    renderer_main_render(&self.main, render_input, command_buffer)
    renderer_main_end(command_buffer)
    // log.debug("============ rendering particles... =============")
    renderer_particle_begin(
      self,
      command_buffer,
      self.frames[g_frame_index].final_image.view,
      self.frames[g_frame_index].depth_buffer.view,
    )
    renderer_particle_render(self, command_buffer)
    renderer_particle_end(self, command_buffer)
  }
  // log.debug("============ rendering post processes... =============")
  prepare_image_for_shader_read(
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
    (MAX_CAMERA_UNIFORMS),
    {.UNIFORM_BUFFER},
  ) or_return
  frame.light_uniform = create_host_visible_buffer(
    LightArrayUniform,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  return .SUCCESS
}

frame_data_deinit :: proc(frame: ^FrameData) {
  data_buffer_deinit(&frame.camera_uniform)
  data_buffer_deinit(&frame.light_uniform)
  image_buffer_deinit(&frame.final_image)
  for &t in frame.shadow_maps do image_buffer_deinit(&t)
  for &t in frame.cube_shadow_maps do cube_depth_texture_deinit(&t)
  image_buffer_deinit(&frame.gbuffer_normal)
  image_buffer_deinit(&frame.gbuffer_albedo)
  image_buffer_deinit(&frame.gbuffer_metallic_roughness)
  image_buffer_deinit(&frame.gbuffer_emissive)
  image_buffer_deinit(&frame.depth_buffer)
}
