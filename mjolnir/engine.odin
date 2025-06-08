package mjolnir

import "base:runtime"
import "core:c"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"

import linalg "core:math/linalg"
import glfw "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

import "animation"
import "geometry"
import "resource"

RENDER_FPS :: 60.0
FRAME_TIME :: 1.0 / RENDER_FPS
FRAME_TIME_MILIS :: FRAME_TIME * 1_000.0
UPDATE_FPS :: 60.0
UPDATE_FRAME_TIME :: 1.0 / UPDATE_FPS
UPDATE_FRAME_TIME_MILIS :: UPDATE_FRAME_TIME * 1_000.0
MOUSE_SENSITIVITY_X :: 0.005
MOUSE_SENSITIVITY_Y :: 0.005
SCROLL_SENSITIVITY :: 0.5

Handle :: resource.Handle

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
Render2DProc :: #type proc(engine: ^Engine, ctx: ^mu.Context)
KeyInputProc :: #type proc(engine: ^Engine, key, action, mods: int)
MousePressProc :: #type proc(engine: ^Engine, key, action, mods: int)
MouseDragProc :: #type proc(engine: ^Engine, delta, offset: linalg.Vector2f64)
MouseScrollProc :: #type proc(engine: ^Engine, offset: linalg.Vector2f64)
MouseMoveProc :: #type proc(engine: ^Engine, pos, delta: linalg.Vector2f64)

CollectLightsContext :: struct {
  engine:        ^Engine,
  light_uniform: ^SceneLightUniform,
}

RenderMeshesContext :: struct {
  engine:         ^Engine,
  command_buffer: vk.CommandBuffer,
  camera_frustum: geometry.Frustum,
  rendered_count: ^u32,
}

ShadowRenderContext :: struct {
  engine:          ^Engine,
  command_buffer:  vk.CommandBuffer,
  obstacles_count: ^u32,
  shadow_idx:      u32,
  shadow_layer:    u32,
  frustum:         geometry.Frustum,
}

InputState :: struct {
  mouse_pos:         linalg.Vector2f64,
  mouse_drag_origin: linalg.Vector2f32,
  mouse_buttons:     [8]bool,
  mouse_holding:     [8]bool,
  key_holding:       [512]bool,
  keys:              [512]bool,
}

Engine :: struct {
  window:                glfw.WindowHandle,
  swapchain:             Swapchain,
  renderer:              Renderer,
  scene:                 Scene,
  ui:                    UIRenderer,
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
}

g_context: runtime.Context

init :: proc(
  engine: ^Engine,
  width: u32,
  height: u32,
  title: string,
) -> vk.Result {
  context.user_ptr = engine
  g_context = context

  // glfw.SetErrorCallback(glfw_error_callback) // Define this callback
  if !glfw.Init() {
    log.errorf("Failed to initialize GLFW")
    return .ERROR_INITIALIZATION_FAILED
  }
  if !glfw.VulkanSupported() {
    log.errorf("GLFW: Vulkan Not Supported")
    return .ERROR_INITIALIZATION_FAILED
  }
  glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
  engine.window = glfw.CreateWindow(
    c.int(width),
    c.int(height),
    strings.clone_to_cstring(title),
    nil,
    nil,
  )
  if engine.window == nil {
    log.errorf("Failed to create GLFW window")
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof("Window created %v\n", engine.window)

  vulkan_context_init(engine.window) or_return

  engine.start_timestamp = time.now()
  engine.last_frame_timestamp = engine.start_timestamp
  engine.last_update_timestamp = engine.start_timestamp

  build_3d_pipelines(.B8G8R8A8_SRGB, .D32_SFLOAT) or_return
  build_3d_unlit_pipelines(.B8G8R8A8_SRGB, .D32_SFLOAT) or_return
  build_shadow_pipelines(.D32_SFLOAT) or_return
  init_scene(&engine.scene)
  build_renderer(engine) or_return
  if engine.swapchain.extent.width > 0 &&
     engine.swapchain.extent.height > 0 {
    w := f32(engine.swapchain.extent.width)
    h := f32(engine.swapchain.extent.height)
    #partial switch &proj in engine.scene.camera.projection {
    case geometry.PerspectiveProjection:
      proj.aspect_ratio = w / h
    }
  }
  build_postprocess_pipelines(
    engine.swapchain.format.format,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
  )

  ui_init(
    &engine.ui,
    engine,
    engine.swapchain.format.format,
    engine.swapchain.extent.width,
    engine.swapchain.extent.height,
  )
  glfw.SetScrollCallback(
    engine.window,
    proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      geometry.camera_orbit_zoom(
        &engine.scene.camera,
        -f32(yoffset) * SCROLL_SENSITIVITY,
      )
      if engine.mouse_scroll_proc != nil {
        engine.mouse_scroll_proc(engine, {xoffset, yoffset})
      }
    },
  )
  glfw.SetKeyCallback(
    engine.window,
    proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      if engine.key_press_proc != nil {
        engine.key_press_proc(engine, int(key), int(action), int(mods))
      }
    },
  )

  glfw.SetMouseButtonCallback(
    engine.window,
    proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
      context = g_context
      engine := cast(^Engine)context.user_ptr
      if engine.mouse_press_proc != nil {
        engine.mouse_press_proc(engine, int(button), int(action), int(mods))
      }
    },
  )

  if engine.setup_proc != nil {
    engine.setup_proc(engine)
  }

  log.infof("Engine initialized")
  return .SUCCESS
}

build_renderer :: proc(engine: ^Engine) -> vk.Result {
  // Initialize swapchain first - now owned by Engine
  swapchain_init(&engine.swapchain, engine.window) or_return

  // Initialize renderer with swapchain info
  renderer_init(
    &engine.renderer,
    engine.swapchain.format.format,
    engine.swapchain.extent,
  ) or_return

  engine.renderer.environment_map_handle, engine.renderer.environment_map =
    create_hdr_texture_from_path(
      engine,
      "assets/teutonic_castle_moat_4k.hdr",
    ) or_return

  engine.renderer.brdf_lut_handle, engine.renderer.brdf_lut =
    create_texture_from_path(engine, "assets/lut_ggx.png") or_return

  vk.AllocateDescriptorSets(
    g_device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &g_environment_descriptor_set_layout,
    },
    &engine.renderer.environment_descriptor_set,
  ) or_return

  env_write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = engine.renderer.environment_descriptor_set,
      dstBinding      = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo      = &vk.DescriptorImageInfo {
        sampler = engine.renderer.environment_map.sampler,
        imageView = engine.renderer.environment_map.buffer.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    }

  brdf_lut_write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = engine.renderer.environment_descriptor_set,
      dstBinding      = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo      = &vk.DescriptorImageInfo {
        sampler = engine.renderer.brdf_lut.sampler,
        imageView = engine.renderer.brdf_lut.buffer.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    }

  writes := [?]vk.WriteDescriptorSet{env_write, brdf_lut_write}
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  return .SUCCESS
}

get_delta_time :: proc(engine: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(engine.last_update_timestamp)))
}

time_since_app_start :: proc(engine: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(engine.start_timestamp)))
}

update :: proc(engine: ^Engine) -> bool {
  glfw.PollEvents()
  delta_time := get_delta_time(engine)
  if delta_time < UPDATE_FRAME_TIME {
    return false
  }
  for &entry in engine.scene.nodes.entries {
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
    mesh, found := resource.get(engine.renderer.meshes, data.handle)
    if !found {
      continue
    }
    mesh_skin, mesh_has_skin := mesh.skinning.?
    if !mesh_has_skin {
      continue
    }
    frame := engine.renderer.current_frame_index
    buffer := skinning.bone_buffers[frame]
    bone_matrices := slice.from_ptr(buffer.mapped, len(mesh_skin.bones))
    sample_clip(mesh, anim_inst.clip_handle, anim_inst.time, bone_matrices)
    //animation.pose_flush(&skinning.pose, buffer.mapped)
  }
  update_emitters(&engine.renderer.particle_compute, delta_time)
  last_mouse_pos := engine.input.mouse_pos
  engine.input.mouse_pos.x, engine.input.mouse_pos.y = glfw.GetCursorPos(
    engine.window,
  )
  delta := engine.input.mouse_pos - last_mouse_pos

  for i in 0 ..< len(engine.input.mouse_buttons) {
    is_pressed := glfw.GetMouseButton(engine.window, c.int(i)) == glfw.PRESS
    engine.input.mouse_holding[i] = is_pressed && engine.input.mouse_buttons[i]
    engine.input.mouse_buttons[i] = is_pressed
  }
  for k in 0 ..< len(engine.input.keys) {
    is_pressed := glfw.GetKey(engine.window, c.int(k)) == glfw.PRESS
    engine.input.key_holding[k] = is_pressed && engine.input.keys[k]
    engine.input.keys[k] = is_pressed
  }
  if engine.input.mouse_holding[glfw.MOUSE_BUTTON_1] {
    geometry.camera_orbit_rotate(
      &engine.scene.camera,
      f32(delta.x * MOUSE_SENSITIVITY_X),
      f32(delta.y * MOUSE_SENSITIVITY_Y),
    )
  }
  if engine.mouse_move_proc != nil {
    engine.mouse_move_proc(engine, engine.input.mouse_pos, delta)
  }
  if engine.update_proc != nil {
    engine.update_proc(engine, delta_time)
  }
  engine.last_update_timestamp = time.now()
  return true
}

deinit :: proc(engine: ^Engine) {
  vk.DeviceWaitIdle(g_device)
  pipeline2d_deinit(&engine.ui.pipeline)
  pipeline3d_deinit()
  pipeline_shadow_deinit()
  deinit_scene(&engine.scene)
  renderer_deinit(&engine.renderer)
  swapchain_deinit(&engine.swapchain)  // Clean up engine's swapchain
  vulkan_context_deinit()
  glfw.DestroyWindow(engine.window)
  glfw.Terminate()
  log.infof("Engine deinitialized")
}

recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  // Recreate swapchain first
  swapchain_recreate(&engine.swapchain, engine.window) or_return

  // Then recreate renderer's size-dependent resources
  renderer_recreate_size_dependent_resources(
    &engine.renderer,
    engine.swapchain.format.format,
    engine.swapchain.extent,
  ) or_return

  return .SUCCESS
}

run :: proc(engine: ^Engine, width: u32, height: u32, title: string) {
  if init(engine, width, height, title) != .SUCCESS {
    return
  }
  defer deinit(engine)
  for !glfw.WindowShouldClose(engine.window) {
    update(engine)
    if time.duration_milliseconds(time.since(engine.last_frame_timestamp)) <
       FRAME_TIME_MILIS {
      continue
    }
    res := render(engine)
    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
      recreate_swapchain(engine) or_continue  // Use new engine function
    }
    if res != .SUCCESS {
      log.errorf("Error during rendering", res)
    }
    engine.last_frame_timestamp = time.now()
    // break
  }
}

create_mesh :: proc(
  engine: ^Engine,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  mesh: ^Mesh,
  ret: vk.Result,
) {
  handle, mesh = resource.alloc(&engine.renderer.meshes)
  mesh_init(mesh, data)
  ret = .SUCCESS
  return
}
