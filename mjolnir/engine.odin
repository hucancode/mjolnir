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

import "geometry"
import "resource"

RENDER_FPS :: 60.0
FRAME_TIME :: 1.0 / RENDER_FPS
FRAME_TIME_MILIS :: FRAME_TIME * 1_000.0
UPDATE_FPS :: 60.0
UPDATE_FRAME_TIME :: 1.0 / UPDATE_FPS
UPDATE_FRAME_TIME_MILIS :: UPDATE_FRAME_TIME * 1_000.0

Handle :: resource.Handle

SetupProc :: #type proc(engine: ^Engine)
UpdateProc :: #type proc(engine: ^Engine, delta_time: f32)
Render2DProc :: #type proc(engine: ^Engine, ctx: ^mu.Context)
Render3DProc :: #type proc(engine: ^Engine)
KeyInputProc :: #type proc(engine: ^Engine, key, action, mods: int)
MousePressProc :: #type proc(engine: ^Engine, key, action, mods: int)
MouseDragProc :: #type proc(engine: ^Engine, delta, offset: linalg.Vector2f64)
MouseScrollProc :: #type proc(engine: ^Engine, offset: linalg.Vector2f64)
MouseMoveProc :: #type proc(engine: ^Engine, pos, delta: linalg.Vector2f64)

// --- Helper Context Structs for Scene Traversal ---
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

// --- Engine Struct ---
Engine :: struct {
  window:                glfw.WindowHandle,
  ctx:                   VulkanContext,
  renderer:              Renderer,
  scene:                 Scene,
  ui:                    UIRenderer,
  last_frame_timestamp:  time.Time,
  last_update_timestamp: time.Time,
  start_timestamp:       time.Time,
  meshes:                resource.ResourcePool(StaticMesh),
  skeletal_meshes:       resource.ResourcePool(SkeletalMesh),
  materials:             resource.ResourcePool(Material),
  textures:              resource.ResourcePool(Texture),
  lights:                resource.ResourcePool(Light),
  nodes:                 resource.ResourcePool(Node),
  in_transaction:        bool,
  dirty_transforms:      [dynamic]Handle,
  input:                 InputState,
  setup_proc:            SetupProc,
  update_proc:           UpdateProc,
  render2d_proc:         Render2DProc,
  render3d_proc:         Render3DProc,
  key_press_proc:        KeyInputProc,
  mouse_press_proc:      MousePressProc,
  mouse_drag_proc:       MouseDragProc,
  mouse_move_proc:       MouseMoveProc,
  mouse_scroll_proc:     MouseScrollProc,
}

g_context: runtime.Context

// --- Scene Traversal ---
// Generic scene traversal. Callback returns true to continue, false to stop or on error.
// User context is passed as rawptr and cast within the callback.
// --- Engine Methods ---
init :: proc(
  engine: ^Engine,
  width: u32,
  height: u32,
  title: string,
) -> vk.Result {
  context.user_ptr = engine
  g_context = context
  engine.dirty_transforms = make([dynamic]Handle, 0)

  // Init GLFW
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

  // Init Vulkan Context
  vulkan_context_init(&engine.ctx, engine.window) or_return

  engine.start_timestamp = time.now()
  engine.last_frame_timestamp = engine.start_timestamp
  engine.last_update_timestamp = engine.start_timestamp

  // Init Resource Pools
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

  fmt.print("Initializing lights pool... ")
  resource.pool_init(&engine.lights)
  fmt.println("done")

  fmt.print("Initializing nodes pool... ")
  resource.pool_init(&engine.nodes)
  fmt.println("done")

  fmt.println("All resource pools initialized successfully")

  build_3d_pipelines(&engine.ctx, .B8G8R8A8_SRGB, .D32_SFLOAT) or_return
  build_3d_unlit_pipelines(&engine.ctx, .B8G8R8A8_SRGB, .D32_SFLOAT) or_return
  build_shadow_pipelines(&engine.ctx, .D32_SFLOAT) or_return
  engine_build_scene(engine)
  engine_build_renderer(engine) or_return
  // Update camera aspect ratio
  if engine.renderer.extent.width > 0 && engine.renderer.extent.height > 0 {
    w := f32(engine.renderer.extent.width)
    h := f32(engine.renderer.extent.height)
    #partial switch &proj in engine.scene.camera.projection {
    case PerspectiveProjection:
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
      camera_orbit_zoom(
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

engine_build_scene :: proc(engine: ^Engine) {
  init_scene(&engine.scene)
  root_handle, root := resource.alloc(&engine.nodes)
  init_node(root, "root")
  root.parent = root_handle
  engine.scene.root = root_handle
}

query_swapchain_support :: proc(
  device: vk.PhysicalDevice,
  surface: vk.SurfaceKHR,
) -> (
  support: SwapchainSupport,
  result: vk.Result,
) {
  // NOTE: looks like a wrong binding with the third arg being a multipointer.
  fmt.printfln("vulkan: querying swapchain support for device", device)
  vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
    device,
    surface,
    &support.capabilities,
  ) or_return
  fmt.printfln("vulkan: got surface capabilities", support.capabilities)
  count: u32
  vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &count, nil) or_return
  fmt.printfln("vulkan: found %v surface formats", count)
  support.formats = make([]vk.SurfaceFormatKHR, count)
  vk.GetPhysicalDeviceSurfaceFormatsKHR(
    device,
    surface,
    &count,
    raw_data(support.formats),
  ) or_return
  vk.GetPhysicalDeviceSurfacePresentModesKHR(
    device,
    surface,
    &count,
    nil,
  ) or_return
  support.present_modes = make([]vk.PresentModeKHR, count)
  vk.GetPhysicalDeviceSurfacePresentModesKHR(
    device,
    surface,
    &count,
    raw_data(support.present_modes),
  ) or_return
  result = .SUCCESS
  return
}

engine_build_renderer :: proc(engine: ^Engine) -> vk.Result {
  renderer_init(&engine.renderer, &engine.ctx) or_return
  indices := find_queue_families(
    engine.ctx.physical_device,
    engine.ctx.surface,
  ) or_return

  support := query_swapchain_support(
    engine.ctx.physical_device,
    engine.ctx.surface,
  ) or_return
  defer swapchain_support_deinit(&support)

  // Get current window framebuffer size to correctly initialize swapchain extent
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
    &engine.ctx,
    engine.renderer.extent.width,
    engine.renderer.extent.height,
  ) or_return
  // Load environment map (HDR)
  engine.renderer.environment_map_handle, engine.renderer.environment_map =
    create_hdr_texture_from_path(
      engine,
      "assets/teutonic_castle_moat_4k.hdr",
    ) or_return

  // Allocate environment map descriptor set
  alloc_info_env := vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = engine.ctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &environment_descriptor_set_layout,
    }
  vk.AllocateDescriptorSets(
    engine.ctx.vkd,
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
  vk.UpdateDescriptorSets(engine.ctx.vkd, 1, &env_write, 0, nil)

  return .SUCCESS
}

// --- Traversal Callbacks ---
prepare_light :: proc(
  node: ^Node,
  world_matrix: ^linalg.Matrix4f32,
  cb_context: rawptr,
) -> bool {
  ctx := (^CollectLightsContext)(cb_context)

  #partial switch data in node.attachment {
  case NodeLightAttachment:
    light_handle := data.handle
    light_obj := resource.get(&ctx.engine.lights, light_handle)
    if light_obj == nil {return true}
    uniform: SingleLightUniform
    #partial switch light_type in light_obj {
    case PointLight:
      uniform.kind = .POINT
      uniform.color = light_type.color
      uniform.radius = light_type.radius
      uniform.has_shadow = b32(light_type.cast_shadow)
      uniform.position = world_matrix^ * linalg.Vector4f32{0, 0, 0, 1}
    case DirectionalLight:
      uniform.kind = .DIRECTIONAL
      uniform.color = light_type.color
      uniform.has_shadow = b32(light_type.cast_shadow)
      uniform.position = world_matrix^ * linalg.Vector4f32{0, 0, 0, 1}
      uniform.direction = world_matrix^ * linalg.Vector4f32{0, 0, 1, 0} // Assuming +Z is forward
    case SpotLight:
      uniform.kind = .SPOT
      uniform.color = light_type.color
      uniform.radius = light_type.radius
      uniform.has_shadow = b32(light_type.cast_shadow)
      uniform.angle = light_type.angle
      uniform.position = world_matrix^ * linalg.Vector4f32{0, 0, 0, 1}
      uniform.direction = world_matrix^ * linalg.Vector4f32{0, 0, 1, 0}
    // fmt.printfln("Spot light, transform %v matrix %v", node_ptr.transform, world_matrix^)
    // fmt.printfln("Spot light, pos %v, dir %v", uniform.position, uniform.direction)
    }
    push_light(ctx.light_uniform, uniform)
  }
  return true
}

render_single_node :: proc(
  node: ^Node,
  world_matrix: ^linalg.Matrix4f32,
  cb_context: rawptr,
) -> bool {
  ctx := (^RenderMeshesContext)(cb_context)
  // fmt.printfln("rendering node", node_h,"matrix", world_matrix^)

  #partial switch data in node.attachment {
  case NodeSkeletalMeshAttachment:
    mesh := resource.get(&ctx.engine.skeletal_meshes, data.handle)
    if mesh == nil {return true}
    material := resource.get(&ctx.engine.materials, mesh.material)
    if material == nil {return true}
    world_aabb := geometry.aabb_transform(mesh.aabb, world_matrix)
    if !geometry.frustum_test_aabb(
      &ctx.camera_frustum,
      world_aabb.min.xyz,
      world_aabb.max.xyz,
    ) {
      return true
    }
    material_update_bone_buffer(
      material,
      data.pose.bone_buffer.buffer,
      data.pose.bone_buffer.size,
    )
    pipeline := pipelines[material.features] if material.is_lit else unlit_pipelines[material.features]
    layout := pipeline_layout
    // fmt.printfln("rendering skeletal mesh with material %v", material)
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    // Bind all required descriptor sets (set 0: camera+shadow+cube shadow, set 1: material, set 2: skinning)
    descriptor_sets := [?]vk.DescriptorSet {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
        material.texture_descriptor_set, // set 1
        material.skinning_descriptor_set, // set 2
        ctx.engine.renderer.environment_descriptor_set, // set 3
      }
    offsets := [1]u32{0}
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      1,
      1,
      &mesh.skin_buffer.buffer,
      &offset,
    )
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.rendered_count^ += 1
  case NodeStaticMeshAttachment:
    mesh := resource.get(&ctx.engine.meshes, data.handle)
    if mesh == nil {return true}
    material := resource.get(&ctx.engine.materials, mesh.material)
    if material == nil {return true}
    world_aabb := geometry.aabb_transform(mesh.aabb, world_matrix)
    if !geometry.frustum_test_aabb(
      &ctx.camera_frustum,
      world_aabb.min.xyz,
      world_aabb.max.xyz,
    ) {
      return true
    }
    pipeline := pipelines[material.features] if material.is_lit else unlit_pipelines[material.features]
    layout := pipeline_layout
    // Bind all required descriptor sets (set 0: camera+shadow+cube shadow, set 1: material, set 2: skinning)
    descriptor_sets := [?]vk.DescriptorSet {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
        material.texture_descriptor_set, // set 1
        material.skinning_descriptor_set, // set 2
        ctx.engine.renderer.environment_descriptor_set, // set 3
      }
    offsets := [1]u32{0}
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.rendered_count^ += 1
  }
  return true
}

render_single_shadow :: proc(
  node: ^Node,
  world_matrix: ^linalg.Matrix4f32,
  cb_context: rawptr,
) -> bool {
  ctx := (^ShadowRenderContext)(cb_context)
  shadow_idx := ctx.shadow_idx
  shadow_layer := ctx.shadow_layer
  min_alignment :=
    ctx.engine.ctx.physical_device_properties.limits.minUniformBufferOffsetAlignment
  aligned_scene_uniform_size := align_up(size_of(SceneUniform), min_alignment)
  #partial switch data in node.attachment {
  case NodeStaticMeshAttachment:
    if !data.cast_shadow {
      return true
    }
    mesh_handle := data.handle
    mesh := resource.get(&ctx.engine.meshes, mesh_handle)
    if mesh == nil {return true}
    world_aabb := geometry.aabb_transform(mesh.aabb, world_matrix)
    if !geometry.frustum_test_aabb(
      &ctx.frustum,
      world_aabb.min.xyz,
      world_aabb.max.xyz,
    ) {
      return true
    }
    material := resource.get(&ctx.engine.materials, mesh.material)
    if material == nil {return true}
    features: u32 = 0
    pipeline := shadow_pipelines[features]
    layout := shadow_pipeline_layout
    descriptor_sets := [?]vk.DescriptorSet {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
      }
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    offset_shadow :=
      (1 + shadow_idx * 6 + shadow_layer) * u32(aligned_scene_uniform_size)
    offsets := [1]u32{offset_shadow}
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      len(descriptor_sets),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.obstacles_count^ += 1
  case NodeSkeletalMeshAttachment:
    if !data.cast_shadow {
      // return true
    }
    mesh := resource.get(&ctx.engine.skeletal_meshes, data.handle)
    if mesh == nil {return true}
    world_aabb := geometry.aabb_transform(mesh.aabb, world_matrix)
    if !geometry.frustum_test_aabb(
      &ctx.frustum,
      world_aabb.min.xyz,
      world_aabb.max.xyz,
    ) {
      return true
    }
    material := resource.get(&ctx.engine.materials, mesh.material)
    if material == nil {return true}
    descriptor_sets := [?]vk.DescriptorSet {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
        material.skinning_descriptor_set, // set 1
      }
    vk.CmdBindPipeline(
      ctx.command_buffer,
      .GRAPHICS,
      shadow_pipelines[SHADER_FEATURE_SKINNING],
    )
    offset_shadow :=
      (1 + shadow_idx * 6 + shadow_layer) * u32(aligned_scene_uniform_size)
    offsets := [1]u32{offset_shadow}
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      shadow_pipeline_layout,
      0,
      len(descriptor_sets),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      shadow_pipeline_layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      1,
      1,
      &mesh.skin_buffer.buffer,
      &offset,
    )
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.obstacles_count^ += 1
  }
  return true
}

render :: proc(engine: ^Engine) -> vk.Result {
  // --- Optimal Frame Render Flow ---
  ctx := engine.renderer.ctx
  current_fence := renderer_get_in_flight_fence(&engine.renderer)
  // 1. Wait for previous frame's completion
  vk.WaitForFences(ctx.vkd, 1, &current_fence, true, math.max(u64)) or_return
  // 2. Reset frame fence
  vk.ResetFences(ctx.vkd, 1, &current_fence) or_return
  // 3. Acquire next swapchain image
  image_idx: u32
  current_image_available_semaphore := renderer_get_image_available_semaphore(
    &engine.renderer,
  )
  vk.AcquireNextImageKHR(
    ctx.vkd,
    engine.renderer.swapchain,
    math.max(u64),
    current_image_available_semaphore,
    0,
    &image_idx,
  ) or_return
  mu.begin(&engine.ui.ctx)
  // 4. Reset and begin command buffer
  command_buffer := renderer_get_command_buffer(&engine.renderer)
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  begin_info := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {.ONE_TIME_SUBMIT},
  }
  vk.BeginCommandBuffer(command_buffer, &begin_info) or_return

  elapsed_seconds := time.duration_seconds(time.since(engine.start_timestamp))
  scene_uniform := SceneUniform {
    view       = camera_calculate_view_matrix(&engine.scene.camera),
    projection = camera_calculate_projection_matrix(&engine.scene.camera),
    time       = f32(elapsed_seconds),
  }
  light_uniform: SceneLightUniform
  camera_frustum := camera_make_frustum(&engine.scene.camera)
  // Collect Lights
  collect_ctx := CollectLightsContext {
    engine        = engine,
    light_uniform = &light_uniform,
  }
  if !traverse_scene(
    &engine.scene,
    &engine.nodes,
    &collect_ctx,
    prepare_light,
  ) {
    fmt.eprintln("[RENDER] Error during light collection")
  }
  render_shadow_pass(engine, &light_uniform, command_buffer) or_return
  // fmt.printfln("============ rendering main pass =============")
  render_main_pass(engine, command_buffer, image_idx, camera_frustum) or_return
  // Update Uniforms
  data_buffer_write(
    renderer_get_camera_uniform(&engine.renderer),
    &scene_uniform,
    size_of(SceneUniform),
  )
  data_buffer_write(
    renderer_get_light_uniform(&engine.renderer),
    &light_uniform,
    size_of(SceneLightUniform),
  )
  if engine.render3d_proc != nil {
    engine.render3d_proc(engine)
  }
  if engine.render2d_proc != nil {
    engine.render2d_proc(engine, &engine.ui.ctx)
  }
  mu.end(&engine.ui.ctx)
  ui_render(&engine.ui, command_buffer)
  vk.CmdEndRenderingKHR(command_buffer)
  // Transition image to present layout
  present_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = engine.renderer.images[image_idx],
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.BOTTOM_OF_PIPE},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &present_barrier,
  )
  // End and submit command buffer
  vk.EndCommandBuffer(command_buffer) or_return
  current_render_finished_semaphore := renderer_get_render_finished_semaphore(
    &engine.renderer,
  )
  wait_stage_mask: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
  submit_info := vk.SubmitInfo {
    sType                = .SUBMIT_INFO,
    waitSemaphoreCount   = 1,
    pWaitSemaphores      = &current_image_available_semaphore,
    pWaitDstStageMask    = &wait_stage_mask,
    commandBufferCount   = 1,
    pCommandBuffers      = &command_buffer,
    signalSemaphoreCount = 1,
    pSignalSemaphores    = &current_render_finished_semaphore,
  }
  vk.QueueSubmit(ctx.graphics_queue, 1, &submit_info, current_fence) or_return
  // Present
  image_indices := [?]u32{image_idx}
  present_info := vk.PresentInfoKHR {
    sType              = .PRESENT_INFO_KHR,
    waitSemaphoreCount = 1,
    pWaitSemaphores    = &current_render_finished_semaphore,
    swapchainCount     = 1,
    pSwapchains        = &engine.renderer.swapchain,
    pImageIndices      = raw_data(image_indices[:]),
  }
  vk.QueuePresentKHR(ctx.present_queue, &present_info) or_return
  // Advance to next frame
  engine.renderer.current_frame_index =
    (engine.renderer.current_frame_index + 1) % MAX_FRAMES_IN_FLIGHT
  return .SUCCESS
}

render_shadow_pass :: proc(
  engine: ^Engine,
  light_uniform: ^SceneLightUniform,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  // fmt.printfln("============ rendering shadow pass =============")
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(&engine.renderer, i)
    shadow_map_texture := renderer_get_shadow_map(&engine.renderer, i)
    // Transition shadow map to depth attachment
    initial_barriers := [2]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = shadow_map_texture.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
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
      len(initial_barriers),
      raw_data(initial_barriers[:]),
    )
  }
  aligned_scene_uniform_size := align_up(
    size_of(SceneUniform),
    engine.ctx.physical_device_properties.limits.minUniformBufferOffsetAlignment,
  )
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    light := &light_uniform.lights[i]
    if !light.has_shadow || i >= MAX_SHADOW_MAPS {
      continue
    }
    if light.kind == .POINT {
      cube_shadow := renderer_get_cube_shadow_map(&engine.renderer, i)
      light_pos := light.position.xyz
      // Cube face directions and up vectors
      face_dirs := [6][3]f32 {
        {1, 0, 0},
        {-1, 0, 0},
        {0, 1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
      }
      face_ups := [6][3]f32 {
        {0, -1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
        {0, -1, 0},
        {0, -1, 0},
      }
      proj := linalg.matrix4_perspective(
        math.PI * 0.5,
        1.0,
        0.01,
        light.radius,
      )
      for face in 0 ..< 6 {
        view := linalg.matrix4_look_at(
          light_pos,
          light_pos + face_dirs[face],
          face_ups[face],
        )
        face_depth_attachment := vk.RenderingAttachmentInfoKHR {
          sType = .RENDERING_ATTACHMENT_INFO_KHR,
          imageView = cube_shadow.views[face],
          imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          loadOp = .CLEAR,
          storeOp = .STORE,
          clearValue = vk.ClearValue{depthStencil = {depth = 1.0}},
        }
        face_render_info := vk.RenderingInfoKHR {
          sType = .RENDERING_INFO_KHR,
          renderArea = {
            extent = {
              width = cube_shadow.buffer.width,
              height = cube_shadow.buffer.height,
            },
          },
          layerCount = 1,
          pDepthAttachment = &face_depth_attachment,
        }
        viewport := vk.Viewport {
          width    = f32(cube_shadow.buffer.width),
          height   = f32(cube_shadow.buffer.height),
          minDepth = 0.0,
          maxDepth = 1.0,
        }
        scissor := vk.Rect2D {
          extent = {
            width = cube_shadow.buffer.width,
            height = cube_shadow.buffer.height,
          },
        }
        shadow_scene_uniform := SceneUniform {
          view       = view,
          projection = proj,
        }
        offset_shadow :=
          vk.DeviceSize(i * 6 + face + 1) * aligned_scene_uniform_size
        data_buffer_write_at(
          renderer_get_camera_uniform(&engine.renderer),
          &shadow_scene_uniform,
          offset_shadow,
          size_of(SceneUniform),
        )
        vk.CmdBeginRenderingKHR(command_buffer, &face_render_info)
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
        obstacles_this_light: u32 = 0
        shadow_render_ctx := ShadowRenderContext {
          engine          = engine,
          command_buffer  = command_buffer,
          obstacles_count = &obstacles_this_light,
          shadow_idx      = u32(i),
          shadow_layer    = u32(face),
          frustum         = geometry.make_frustum(proj * view),
        }
        traverse_scene(
          &engine.scene,
          &engine.nodes,
          &shadow_render_ctx,
          render_single_shadow,
        )
        vk.CmdEndRenderingKHR(command_buffer)
      }
    } else {
      shadow_map_texture := renderer_get_shadow_map(&engine.renderer, i)
      view: linalg.Matrix4f32
      proj: linalg.Matrix4f32
      if light.kind == .DIRECTIONAL {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_Y_AXIS,
        )
        ortho_size: f32 = 20.0
        proj = linalg.matrix_ortho3d(
          -ortho_size,
          ortho_size,
          -ortho_size,
          ortho_size,
          0.1,
          light.radius,
        )
      } else {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_X_AXIS, // TODO: hardcoding up vector will not work if the light is perfectly aligned with said vector
        )
        proj = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius)
      }
      light.view_proj = proj * view
      depth_attachment := vk.RenderingAttachmentInfoKHR {
        sType = .RENDERING_ATTACHMENT_INFO_KHR,
        imageView = shadow_map_texture.buffer.view,
        imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        loadOp = .CLEAR,
        storeOp = .STORE,
        clearValue = vk.ClearValue{depthStencil = {depth = 1.0}},
      }
      render_info_khr := vk.RenderingInfoKHR {
        sType = .RENDERING_INFO_KHR,
        renderArea = {
          extent = {
            width = shadow_map_texture.buffer.width,
            height = shadow_map_texture.buffer.height,
          },
        },
        layerCount = 1,
        pDepthAttachment = &depth_attachment,
      }
      shadow_scene_uniform := SceneUniform {
        view       = view,
        projection = proj,
      }
      offset_shadow := vk.DeviceSize(i * 6 + 1) * aligned_scene_uniform_size
      data_buffer_write_at(
        renderer_get_camera_uniform(&engine.renderer),
        &shadow_scene_uniform,
        offset_shadow,
        size_of(SceneUniform),
      )
      vk.CmdBeginRenderingKHR(command_buffer, &render_info_khr)
      viewport := vk.Viewport {
        width    = f32(shadow_map_texture.buffer.width),
        height   = f32(shadow_map_texture.buffer.height),
        minDepth = 0.0,
        maxDepth = 1.0,
      }
      scissor := vk.Rect2D {
        extent = {
          width = shadow_map_texture.buffer.width,
          height = shadow_map_texture.buffer.height,
        },
      }
      vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
      vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
      obstacles_this_light: u32 = 0
      shadow_render_ctx := ShadowRenderContext {
        engine          = engine,
        command_buffer  = command_buffer,
        obstacles_count = &obstacles_this_light,
        shadow_idx      = u32(i),
        frustum         = geometry.make_frustum(proj * view),
      }
      traverse_scene(
        &engine.scene,
        &engine.nodes,
        &shadow_render_ctx,
        render_single_shadow,
      )
      vk.CmdEndRenderingKHR(command_buffer)
    }
  }
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(&engine.renderer, i)
    shadow_map_texture := renderer_get_shadow_map(&engine.renderer, i)
    final_barriers := [2]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = shadow_map_texture.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
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
      len(final_barriers),
      raw_data(final_barriers[:]),
    )
  }
  return .SUCCESS
}

render_main_pass :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  image_idx: u32,
  camera_frustum: geometry.Frustum,
) -> vk.Result {
  // Transition swapchain image to color attachment
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = .UNDEFINED,
    newLayout = .COLOR_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = engine.renderer.images[image_idx],
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  // Begin Main Render Pass
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.renderer.views[image_idx],
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue {
      color = {float32 = {0.0117, 0.0117, 0.0179, 1.0}},
    },
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.renderer.depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue{depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = vk.Rect2D{extent = engine.renderer.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  // Set viewport and scissor
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(engine.renderer.extent.height),
    width    = f32(engine.renderer.extent.width),
    height   = -f32(engine.renderer.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = engine.renderer.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  // Render Scene Meshes
  rendered_count: u32 = 0
  render_meshes_ctx := RenderMeshesContext {
    engine         = engine,
    command_buffer = command_buffer,
    camera_frustum = camera_frustum,
    rendered_count = &rendered_count,
  }
  if !traverse_scene(
    &engine.scene,
    &engine.nodes,
    &render_meshes_ctx,
    render_single_node,
  ) {
    fmt.eprintln("[RENDER] Error during scene mesh rendering")
  }
  if mu.window(&engine.ui.ctx, "Inspector", {40, 40, 300, 150}, {.NO_CLOSE}) {
    mu.label(
      &engine.ui.ctx,
      fmt.tprintf(
        "Objects %d",
        len(engine.nodes.entries) - len(engine.nodes.free_indices),
      ),
    )
    mu.label(
      &engine.ui.ctx,
      fmt.tprintf(
        "Lights %d",
        len(engine.lights.entries) - len(engine.lights.free_indices),
      ),
    )
    mu.label(&engine.ui.ctx, fmt.tprintf("Rendered %d", rendered_count))
  }
  return .SUCCESS
}

engine_recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  vkd := engine.ctx.vkd
  vk.DeviceWaitIdle(vkd)
  indices := find_queue_families(
    engine.ctx.physical_device,
    engine.ctx.surface,
  ) or_return
  support := query_swapchain_support(
    engine.ctx.physical_device,
    engine.ctx.surface,
  ) or_return
  renderer_build_swapchain(
    &engine.renderer,
    support.capabilities,
    support.formats,
    support.present_modes,
    indices.graphics_family,
    indices.present_family,
    engine.renderer.extent.width,
    engine.renderer.extent.height,
  ) or_return
  engine.renderer.depth_buffer = create_depth_image(
    &engine.ctx,
    engine.renderer.extent.width,
    engine.renderer.extent.height,
  ) or_return
  if engine.renderer.extent.width > 0 && engine.renderer.extent.height > 0 {
    w := f32(engine.renderer.extent.width)
    h := f32(engine.renderer.extent.height)
    #partial switch &proj in engine.scene.camera.projection {
    case PerspectiveProjection:
      proj.aspect_ratio = w / h
    }
  }
  fmt.println("Swapchain recreated")
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
  for &entry in engine.nodes.entries {
    if !entry.active {
      continue
    }
    data, is_skeletal_mesh := &entry.item.attachment.(NodeSkeletalMeshAttachment)
    if !is_skeletal_mesh || data.animation == nil {
      continue
    }
    anim_inst := &data.animation.?
    animation_instance_update(anim_inst, delta_time)
    skeletal_mesh := resource.get(&engine.skeletal_meshes, data.handle)
    if skeletal_mesh != nil {
      calculate_animation_transform(skeletal_mesh, anim_inst, &data.pose)
    }
  }
  clear(&engine.dirty_transforms)

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
    camera_orbit_rotate(
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
  vkd := engine.ctx.vkd
  vk.DeviceWaitIdle(vkd)

  // Deinit resources
  resource.pool_deinit(&engine.nodes)
  resource.pool_deinit(&engine.textures)
  resource.pool_deinit(&engine.meshes)
  resource.pool_deinit(&engine.skeletal_meshes)
  resource.pool_deinit(&engine.materials)
  resource.pool_deinit(&engine.lights)

  deinit_scene(&engine.scene)
  renderer_deinit(&engine.renderer)
  vulkan_context_deinit(&engine.ctx)

  glfw.DestroyWindow(engine.window)
  glfw.Terminate()

  delete(engine.dirty_transforms)
  fmt.println("Engine deinitialized")
}

// --- Transaction System (Simplified) ---
engine_begin_transaction :: proc(engine: ^Engine) {
  engine.in_transaction = true
}
engine_commit_transaction :: proc(engine: ^Engine) {
  engine.in_transaction = false
  // Process dirty transforms if not handled by traversal
  // for handle in engine.dirty_transforms { ... }
  clear(&engine.dirty_transforms)
}

run :: proc(engine: ^Engine) {
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
