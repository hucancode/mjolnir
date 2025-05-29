package mjolnir

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
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
  renderer:              Renderer,
  scene:                 Scene,
  ui:                    UIRenderer,
  last_frame_timestamp:  time.Time,
  last_update_timestamp: time.Time,
  start_timestamp:       time.Time,
  meshes:                resource.Pool(StaticMesh),
  skeletal_meshes:       resource.Pool(SkeletalMesh),
  materials:             resource.Pool(Material),
  textures:              resource.Pool(Texture),
  in_transaction:        bool,
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
    fmt.eprintln("Failed to initialize GLFW")
    return .ERROR_INITIALIZATION_FAILED
  }
  if !glfw.VulkanSupported() {
    fmt.eprintln("GLFW: Vulkan Not Supported")
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
    fmt.eprintln("Failed to create GLFW window")
    return .ERROR_INITIALIZATION_FAILED
  }
  fmt.printf("Window created %v\n", engine.window)

  vulkan_context_init(engine.window) or_return

  engine.start_timestamp = time.now()
  engine.last_frame_timestamp = engine.start_timestamp
  engine.last_update_timestamp = engine.start_timestamp

  fmt.println("\nInitializing Resource Pools...")

  fmt.print("Initializing static mesh pool... ")
  resource.pool_init(&engine.meshes)
  fmt.println("done")

  fmt.print("Initializing skeletal mesh pool... ")
  resource.pool_init(&engine.skeletal_meshes)
  fmt.println("done")

  fmt.print("Initializing materials pool... ")
  resource.pool_init(&engine.materials)
  fmt.println("done")

  fmt.print("Initializing textures pool... ")
  resource.pool_init(&engine.textures)
  fmt.println("done")

  fmt.println("All resource pools initialized successfully")

  build_3d_pipelines(.B8G8R8A8_SRGB, .D32_SFLOAT) or_return
  build_3d_unlit_pipelines(.B8G8R8A8_SRGB, .D32_SFLOAT) or_return
  build_shadow_pipelines(.D32_SFLOAT) or_return
  init_scene(&engine.scene)
  engine_build_renderer(engine) or_return
  if engine.renderer.extent.width > 0 && engine.renderer.extent.height > 0 {
    w := f32(engine.renderer.extent.width)
    h := f32(engine.renderer.extent.height)
    #partial switch &proj in engine.scene.camera.projection {
    case geometry.PerspectiveProjection:
      proj.aspect_ratio = w / h
    }
  }

  ui_init(
    &engine.ui,
    engine,
    engine.renderer.format.format,
    engine.renderer.extent.width,
    engine.renderer.extent.height,
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

  fmt.println("Engine initialized")
  return .SUCCESS
}

engine_build_renderer :: proc(engine: ^Engine) -> vk.Result {
  renderer_init(&engine.renderer) or_return
  indices := find_queue_families(g_physical_device, g_surface) or_return

  support := query_swapchain_support(g_physical_device, g_surface) or_return
  defer swapchain_support_deinit(&support)

  fb_width, fb_height := glfw.GetFramebufferSize(engine.window)

  renderer_build_swapchain(
    &engine.renderer,
    support.capabilities,
    support.formats,
    support.present_modes,
    indices.graphics_family,
    indices.present_family,
    u32(fb_width),
    u32(fb_height),
  ) or_return
  renderer_build_command_buffers(&engine.renderer) or_return
  renderer_build_synchronizers(&engine.renderer) or_return

  engine.renderer.depth_buffer = create_depth_image(
    engine.renderer.extent.width,
    engine.renderer.extent.height,
  ) or_return
  engine.renderer.environment_map_handle, engine.renderer.environment_map =
    create_hdr_texture_from_path(
      engine,
      "assets/teutonic_castle_moat_4k.hdr",
    ) or_return

  alloc_info_env := vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &environment_descriptor_set_layout,
    }
  vk.AllocateDescriptorSets(
    g_device,
    &alloc_info_env,
    &engine.renderer.environment_descriptor_set,
  ) or_return

  env_image_info := vk.DescriptorImageInfo {
      sampler     = engine.renderer.environment_map.sampler,
      imageView   = engine.renderer.environment_map.buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
  env_write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = engine.renderer.environment_descriptor_set,
      dstBinding      = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo      = &env_image_info,
    }
  vk.UpdateDescriptorSets(g_device, 1, &env_write, 0, nil)

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
    data, is_skeletal_mesh := &entry.item.attachment.(SkeletalMeshAttachment)
    if !is_skeletal_mesh || data.animation == nil {
      continue
    }
    anim_inst := &data.animation.?
    animation.instance_update(anim_inst, delta_time)
    skeletal_mesh := resource.get(engine.skeletal_meshes, data.handle)
    if skeletal_mesh != nil {
      calculate_animation_transform(skeletal_mesh, anim_inst, &data.pose)
      animation.pose_flush(&data.pose, data.bone_buffer.mapped)
    }
  }

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
  resource.pool_deinit(engine.textures, texture_deinit)
  resource.pool_deinit(engine.meshes, static_mesh_deinit)
  resource.pool_deinit(engine.skeletal_meshes, skeletal_mesh_deinit)
  resource.pool_deinit(engine.materials, material_deinit)
  pipeline2d_deinit(&engine.ui.pipeline)
  pipeline3d_deinit()
  pipeline_shadow_deinit()
  deinit_scene(&engine.scene)
  renderer_deinit(&engine.renderer)
  vulkan_context_deinit()
  glfw.DestroyWindow(engine.window)
  glfw.Terminate()
  fmt.println("Engine deinitialized")
}

// TODO: Transaction System
engine_begin_transaction :: proc(engine: ^Engine) {
  engine.in_transaction = true
}

engine_commit_transaction :: proc(engine: ^Engine) {
  engine.in_transaction = false
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
      engine_recreate_swapchain(engine)
    } else if res != .SUCCESS {
      fmt.eprintln("Error during rendering")
    }
    engine.last_frame_timestamp = time.now()
    // break
  }
}
