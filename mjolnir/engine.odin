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
  engine:               ^Engine,
  command_buffer:       vk.CommandBuffer,
  camera_frustum:       geometry.Frustum,
  rendered_count:       ^u32,
  scene_descriptor_set: vk.DescriptorSet,
}

ShadowRenderContext :: struct {
  engine:          ^Engine,
  command_buffer:  vk.CommandBuffer,
  obstacles_count: ^u32,
  light_view_proj: linalg.Matrix4f32, // Added to pass light's VP matrix
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
  vk_ctx:                VulkanContext,
  renderer:              Renderer,
  scene:                 Scene,
  ui:                    UIRenderer,
  last_frame_timestamp:  time.Time,
  last_update_timestamp: time.Time,
  start_timestamp:       time.Time,
  meshes:                resource.ResourcePool(StaticMesh),
  skeletal_meshes:       resource.ResourcePool(SkeletalMesh),
  materials:             resource.ResourcePool(Material),
  skinned_materials:     resource.ResourcePool(SkinnedMaterial),
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
engine_init :: proc(
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
  vulkan_context_init(&engine.vk_ctx, engine.window) or_return

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

  fmt.print("Initializing skinned materials pool... ")
  resource.pool_init(&engine.skinned_materials)
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
  renderer_init(&engine.renderer, &engine.vk_ctx) or_return

  indices := find_queue_families(
    engine.vk_ctx.physical_device,
    engine.vk_ctx.surface,
  ) or_return

  support := query_swapchain_support(
    engine.vk_ctx.physical_device,
    engine.vk_ctx.surface,
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
    &engine.vk_ctx,
    engine.renderer.extent.width,
    engine.renderer.extent.height,
  ) or_return
  return .SUCCESS
}

traverse_scene :: proc(
  engine: ^Engine,
  user_context: rawptr,
  callback: proc(
    eng: ^Engine,
    node_h: Handle,
    node_ptr: ^Node,
    world_matrix: ^linalg.Matrix4f32,
    cb_context: rawptr,
  ) -> bool,
) -> bool {
  node_stack := make([dynamic]Handle, 0)
  defer delete(node_stack)
  transform_stack := make([dynamic]linalg.Matrix4f32, 0)
  defer delete(transform_stack)

  append(&node_stack, engine.scene.root)
  append(&transform_stack, linalg.MATRIX4F32_IDENTITY)

  for len(node_stack) > 0 {
    current_node_handle := pop(&node_stack)
    parent_world_matrix := pop(&transform_stack)

    current_node := resource.get(&engine.nodes, current_node_handle)
    if current_node == nil {
      fmt.eprintf(
        "traverse_scene: Node with handle %v not found\n",
        current_node_handle,
      )
      continue
    }

    // TODO: instead of DFS and update transform matrix on render, we should transform on object request
    // Ensure transform is up-to-date (local_matrix from TRS)
    if current_node.transform.is_dirty {
      current_node.transform.local_matrix = linalg.matrix4_from_trs(
        current_node.transform.position,
        current_node.transform.rotation,
        current_node.transform.scale,
      )
      // current_node.transform.is_dirty = false; // World matrix update will clear it if needed
    }
    current_node.transform.world_matrix =
      parent_world_matrix * current_node.transform.local_matrix
    current_node.transform.is_dirty = false

    if !callback(
      engine,
      current_node_handle,
      current_node,
      &current_node.transform.world_matrix,
      user_context,
    ) {
      continue
    }
    // No need to write back if using pointers from resource pool

    for child_handle in current_node.children {
      append(&node_stack, child_handle)
      append(&transform_stack, current_node.transform.world_matrix)
    }
  }
  return true
}

// --- Traversal Callbacks ---
collect_lights_callback :: proc(
  eng: ^Engine,
  node_h: Handle,
  node_ptr: ^Node,
  world_matrix: ^linalg.Matrix4f32,
  cb_context: rawptr,
) -> bool {
  ctx := (^CollectLightsContext)(cb_context)

  #partial switch data in node_ptr.attachment {
  case NodeLightAttachment:
    light_handle := data.handle
    light_obj := resource.get(&eng.lights, light_handle)
    if light_obj == nil {return true}
    uniform: SingleLightUniform
    #partial switch light_type in light_obj {
    case PointLight:
      uniform.kind = 0
      uniform.color = light_type.color
      uniform.radius = light_type.radius
      uniform.has_shadow = light_type.cast_shadow ? 1 : 0
      uniform.position = linalg.Vector4f32{0, 0, 0, 1} * world_matrix^
    case DirectionalLight:
      uniform.kind = 1
      uniform.color = light_type.color
      uniform.has_shadow = light_type.cast_shadow ? 1 : 0
      uniform.position = linalg.Vector4f32{0, 0, 0, 1} * world_matrix^
      uniform.direction = linalg.Vector4f32{0, 0, 1, 0} * world_matrix^ // Assuming +Z is forward
    case SpotLight:
      uniform.kind = 2
      uniform.color = light_type.color
      uniform.radius = light_type.radius
      uniform.has_shadow = light_type.cast_shadow ? 1 : 0
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

render_scene_node_callback :: proc(
  eng: ^Engine,
  node_h: Handle,
  node_ptr: ^Node,
  world_matrix: ^linalg.Matrix4f32,
  cb_context: rawptr,
) -> bool {
  ctx := (^RenderMeshesContext)(cb_context)
  // fmt.printfln("rendering node", node_h,"matrix", world_matrix^)

  #partial switch data in node_ptr.attachment {
  case NodeSkeletalMeshAttachment:
    mesh := resource.get(&eng.skeletal_meshes, data.handle)
    if mesh == nil {return true}
    material := resource.get(&eng.skinned_materials, mesh.material)
    if material == nil {return true}
    world_aabb := geometry.aabb_transform(mesh.aabb, world_matrix)
    if !geometry.frustum_test_aabb(
      &ctx.camera_frustum,
      world_aabb.min.xyz,
      world_aabb.max.xyz,
    ) {
      return true
    }
    // fmt.printfln("rendering skinned mesh %v, with material %v, pipeline %d, descriptor set %d", data.handle, mesh.material, material.pipeline, material.descriptor_set)
    skinned_material_update_bone_buffer(
      material,
      data.pose.bone_buffer.buffer,
      data.pose.bone_buffer.size,
    )
    descriptor_sets := [?]vk.DescriptorSet {
      ctx.scene_descriptor_set,
      material.descriptor_set,
    }
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, material.pipeline)
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      material.pipeline_layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      0,
      nil,
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      material.pipeline_layout,
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
  case NodeStaticMeshAttachment:
    mesh_handle := data.handle
    mesh := resource.get(&eng.meshes, mesh_handle)
    if mesh == nil {return true}
    material := resource.get(&eng.materials, mesh.material)
    if material == nil {return true}
    world_aabb := geometry.aabb_transform(mesh.aabb, world_matrix)
    if !geometry.frustum_test_aabb(
      &ctx.camera_frustum,
      world_aabb.min.xyz,
      world_aabb.max.xyz,
    ) {
      return true
    }
    descriptor_sets := [?]vk.DescriptorSet {
      ctx.scene_descriptor_set,
      material.descriptor_set,
    }
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, material.pipeline)
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      material.pipeline_layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      0,
      nil,
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      material.pipeline_layout,
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
    // fmt.printfln("rendered static mesh %v indices %d", mesh_handle, mesh.indices_len)
    ctx.rendered_count^ += 1
  }
  return true
}

render_shadow_node_callback :: proc(
  eng: ^Engine,
  node_h: Handle,
  node_ptr: ^Node,
  world_matrix: ^linalg.Matrix4f32,
  cb_context: rawptr,
) -> bool {
  ctx := (^ShadowRenderContext)(cb_context)
  shadow_pass_material := &eng.renderer.shadow_pass_material

  #partial switch data in node_ptr.attachment {
  case NodeStaticMeshAttachment:
    mesh_handle := data.handle
    mesh := resource.get(&eng.meshes, mesh_handle)
    if mesh == nil {return true}
    vk.CmdPushConstants(
      ctx.command_buffer,
      shadow_pass_material.pipeline_layout,
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
      &mesh.simple_vertex_buffer.buffer,
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
    mesh := resource.get(&eng.skeletal_meshes, data.handle)
    if mesh == nil {return true}
    vk.CmdPushConstants(
      ctx.command_buffer,
      shadow_pass_material.pipeline_layout,
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
      &mesh.simple_vertex_buffer.buffer,
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

try_render :: proc(engine: ^Engine) -> vk.Result {
  elapsed_seconds := time.duration_seconds(time.since(engine.start_timestamp))

  scene_uniform := SceneUniform {
    view       = camera_calculate_view_matrix(&engine.scene.camera),
    projection = camera_calculate_projection_matrix(&engine.scene.camera),
    time       = f32(elapsed_seconds),
  }
  // fmt.printfln("Scene uniform: %v", scene_uniform)

  light_uniform: SceneLightUniform

  // fmt.printfln("Camera %v", engine.scene.camera)
  camera_frustum := camera_make_frustum(&engine.scene.camera)

  // Collect Lights
  collect_ctx := CollectLightsContext {
    engine        = engine,
    light_uniform = &light_uniform,
  }
  if !traverse_scene(
    engine,
    &collect_ctx,
    collect_lights_callback,
  ) {
    fmt.eprintln("Error during light collection")
    // return false
  }

  render_shadow_maps(engine, &light_uniform) or_return

  // Begin Main Render Pass
  image_idx := renderer_begin_frame(&engine.renderer) or_return
  command_buffer_main := renderer_get_command_buffer(&engine.renderer)

  // Render Scene Meshes
  rendered_count: u32 = 0
  render_meshes_ctx := RenderMeshesContext {
    engine               = engine,
    command_buffer       = command_buffer_main,
    camera_frustum       = camera_frustum,
    rendered_count       = &rendered_count,
    scene_descriptor_set = renderer_get_scene_descriptor_set(&engine.renderer),
  }
  if !traverse_scene(
    engine,
    &render_meshes_ctx,
    render_scene_node_callback,
  ) {
    fmt.eprintln("Error during scene mesh rendering")
    // return false
  }

  // Update Uniforms
  data_buffer_write(
    renderer_get_scene_uniform(&engine.renderer),
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
  ctx := &engine.ui.ctx
  mu.begin(ctx)
  if mu.window(ctx, "Inspector", {40, 40, 300, 150}, {.NO_CLOSE}) {
    mu.label(
      ctx,
      fmt.tprintf(
        "Objects %d",
        len(engine.nodes.entries) - len(engine.nodes.free_indices),
      ),
    )
    mu.label(
      ctx,
      fmt.tprintf(
        "Lights %d",
        len(engine.lights.entries) - len(engine.lights.free_indices),
      ),
    )
    mu.label(ctx, fmt.tprintf("Rendered %d", rendered_count))
  }
  if engine.render2d_proc != nil {
    engine.render2d_proc(engine, ctx)
  }
  mu.end(ctx)
  ui_render(&engine.ui, command_buffer_main)
  renderer_end_frame(&engine.renderer, image_idx) or_return
  return .SUCCESS
}

engine_render :: proc(engine: ^Engine) {
  if time.duration_milliseconds(time.since(engine.last_frame_timestamp)) <
     FRAME_TIME_MILIS {
    return
  }
  res := try_render(engine)
  if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
    engine_recreate_swapchain(engine)
  } else if res != .SUCCESS {
    fmt.eprintln("Error during rendering")
  }
  engine.last_frame_timestamp = time.now()
}

render_shadow_maps :: proc(
  engine: ^Engine,
  light_uniform: ^SceneLightUniform,
) -> vk.Result {
  total_obstacles: u32 = 0

  for i := 0; i < int(light_uniform.light_count); i += 1 {
    light := &light_uniform.lights[i]
    if light.has_shadow == 0 || i >= MAX_SHADOW_MAPS {continue}

    shadow_map_texture := renderer_get_shadow_map(&engine.renderer, i)

    light_pos_3d := light.position.xyz
    light_dir_3d := linalg.normalize(light.direction.xyz)

    switch light.kind {
    case 0:
      look_target := light_pos_3d + light_dir_3d // Example target
      light_view := linalg.matrix4_look_at(
        light_pos_3d,
        look_target,
        linalg.VECTOR3F32_Y_AXIS,
      )
      light_proj := linalg.matrix4_perspective(
        math.PI * 2,
        1.0,
        0.1,
        light.radius,
      )
      light.view_proj = light_proj * light_view
    case 1:
      look_target := light_pos_3d + light_dir_3d
      light_view := linalg.matrix4_look_at(
        light_pos_3d,
        look_target,
        linalg.VECTOR3F32_Y_AXIS,
      )
      // Ortho size needs to encompass the visible scene from light's POV
      ortho_size: f32 = 20.0 // Example, should be dynamic
      light_proj := linalg.matrix_ortho3d(
        -ortho_size,
        ortho_size,
        -ortho_size,
        ortho_size,
        0.1,
        light.radius,
      )
      light.view_proj = light_proj * light_view
    case 2:
      // Spot
      look_target := light_pos_3d + light_dir_3d
      light_view := linalg.matrix4_look_at(
        light_pos_3d,
        look_target,
        linalg.VECTOR3F32_Y_AXIS,
      )
      light_proj := linalg.matrix4_perspective(
        light.angle,
        1.0,
        0.1,
        light.radius,
      )
      light.view_proj = light_proj * light_view
    case:
    }
    // fmt.printfln("Light view_proj matrix for shadow pass: %v", light_vp)

    // TODO: shadow rendering could benefit from parallel rendering, recheck synchronization in this part

    shadow_cmd_buffer := renderer_get_command_buffer(&engine.renderer)
    vk.ResetCommandBuffer(shadow_cmd_buffer, {}) or_return
    vk.BeginCommandBuffer(
      shadow_cmd_buffer,
      &vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
      },
    ) or_return

    // Transition shadow map to depth attachment
    initial_barrier := vk.ImageMemoryBarrier {
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
    }
    vk.CmdPipelineBarrier(
      shadow_cmd_buffer,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {},
      0,
      nil,
      0,
      nil,
      1,
      &initial_barrier,
    )

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
    vk.CmdBeginRenderingKHR(shadow_cmd_buffer, &render_info_khr)

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
    vk.CmdSetViewport(shadow_cmd_buffer, 0, 1, &viewport)
    vk.CmdSetScissor(shadow_cmd_buffer, 0, 1, &scissor)

    vk.CmdBindPipeline(
      shadow_cmd_buffer,
      .GRAPHICS,
      engine.renderer.shadow_pass_material.pipeline,
    )
    shadow_ds := renderer_get_shadow_descriptor_set(&engine.renderer)
    vk.CmdBindDescriptorSets(
      shadow_cmd_buffer,
      .GRAPHICS,
      engine.renderer.shadow_pass_material.pipeline_layout,
      0,
      1,
      &shadow_ds,
      0,
      nil,
    )
    // Update light view_proj uniform for shadow pass
    data_buffer_write(
      renderer_get_light_view_proj_uniform(&engine.renderer),
      raw_data(&light.view_proj),
      size_of(linalg.Matrix4f32),
    )

    obstacles_this_light: u32 = 0
    shadow_render_ctx := ShadowRenderContext {
      engine          = engine,
      command_buffer  = shadow_cmd_buffer,
      obstacles_count = &obstacles_this_light,
      light_view_proj = light.view_proj,
    }
    traverse_scene(
      engine,
      &shadow_render_ctx,
      render_shadow_node_callback,
    )
    total_obstacles += obstacles_this_light

    vk.CmdEndRenderingKHR(shadow_cmd_buffer)

    // Transition shadow map to shader read
    final_barrier := vk.ImageMemoryBarrier {
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
    }
    vk.CmdPipelineBarrier(
      shadow_cmd_buffer,
      {.LATE_FRAGMENT_TESTS},
      {.FRAGMENT_SHADER},
      {},
      0,
      nil,
      0,
      nil,
      1,
      &final_barrier,
    )

    vk.EndCommandBuffer(shadow_cmd_buffer) or_return
    wait_stage := vk.PipelineStageFlags{.TOP_OF_PIPE}
    vk.QueueSubmit(
      engine.vk_ctx.graphics_queue,
      1,
      &vk.SubmitInfo {
        sType = .SUBMIT_INFO,
        pWaitDstStageMask = &wait_stage,
        commandBufferCount = 1,
        pCommandBuffers = &shadow_cmd_buffer,
      },
      vk.Fence(0),
    ) or_return
    vk.DeviceWaitIdle(engine.vk_ctx.vkd) or_return
  }
  // fmt.printfln("Rendered shadow maps, total obstacles in shadow maps: %d", total_obstacles)
  return .SUCCESS
}


engine_recreate_swapchain :: proc(engine: ^Engine) -> vk.Result {
  vkd := engine.vk_ctx.vkd
  vk.DeviceWaitIdle(vkd)
  indices := find_queue_families(
    engine.vk_ctx.physical_device,
    engine.vk_ctx.surface,
  ) or_return
  support := query_swapchain_support(
    engine.vk_ctx.physical_device,
    engine.vk_ctx.surface,
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
    &engine.vk_ctx,
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

engine_get_delta_time :: proc(engine: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(engine.last_update_timestamp)))
}

engine_get_time :: proc(engine: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(engine.start_timestamp)))
}

engine_should_close :: proc(engine: ^Engine) -> bool {
  return bool(glfw.WindowShouldClose(engine.window))
}

engine_update :: proc(engine: ^Engine) -> bool {
  glfw.PollEvents()
  delta_time := engine_get_delta_time(engine)
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

engine_deinit :: proc(engine: ^Engine) {
  vkd := engine.vk_ctx.vkd
  vk.DeviceWaitIdle(vkd)

  // Deinit resources
  resource.pool_deinit(&engine.nodes)
  resource.pool_deinit(&engine.textures)
  resource.pool_deinit(&engine.meshes)
  resource.pool_deinit(&engine.skeletal_meshes)
  resource.pool_deinit(&engine.materials)
  resource.pool_deinit(&engine.skinned_materials)
  resource.pool_deinit(&engine.lights)

  deinit_scene(&engine.scene)
  renderer_deinit(&engine.renderer)
  vulkan_context_deinit(&engine.vk_ctx)

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

// --- Animation Control ---
engine_play_animation :: proc(
  engine: ^Engine,
  node_handle: Handle,
  name: string,
  mode: Animation_Play_Mode,
) -> bool {
  node := resource.get(&engine.nodes, node_handle)
  if node == nil {
    return false
  }
  data, ok := &node.attachment.(NodeSkeletalMeshAttachment)
  if !ok {
    return false
  }
  skeletal_mesh_res := resource.get(&engine.skeletal_meshes, data.handle)
  if skeletal_mesh_res == nil {
    return false
  }
  anim_inst, found := play_animation(skeletal_mesh_res, name, mode)
  if !found {
    return false
  }
  data.animation = anim_inst
  return true
}

// Spawns a node with a point light attached
spawn_point_light :: proc(
  engine: ^Engine,
  color: linalg.Vector4f32,
  radius: f32,
  cast_shadow: bool = true,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = spawn_node(engine)
  if node != nil {
    light_handle, light := resource.alloc(&engine.lights)
    light^ = PointLight {
      color       = color,
      radius      = radius,
      cast_shadow = cast_shadow,
    }
    node.attachment = NodeLightAttachment{light_handle}
  }
  return
}

// Spawns a node with a directional light attached
spawn_directional_light :: proc(
  engine: ^Engine,
  color: linalg.Vector4f32,
  cast_shadow: bool = true,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = spawn_node(engine)
  if node != nil {
    light_handle, light := resource.alloc(&engine.lights)
    light^ = DirectionalLight {
      color       = color,
      cast_shadow = cast_shadow,
    }
    node.attachment = NodeLightAttachment{light_handle}
  }
  return
}

// Spawns a node with a spot light attached
spawn_spot_light :: proc(
  engine: ^Engine,
  color: linalg.Vector4f32,
  angle: f32,
  radius: f32,
  cast_shadow: bool = true,
) -> (
  handle: Handle,
  node: ^Node,
) {
  handle, node = spawn_node(engine)
  if node != nil {
    light_handle, light := resource.alloc(&engine.lights)
    light^ = SpotLight {
      color       = color,
      angle       = angle,
      radius      = radius,
      cast_shadow = cast_shadow,
    }
    node.attachment = NodeLightAttachment{light_handle}
  }
  return
}

// Spawns a generic node and returns its handle and pointer
spawn_node :: proc(engine: ^Engine) -> (handle: Handle, node: ^Node) {
  handle, node = resource.alloc(&engine.nodes)
  if node != nil {
    node.transform = geometry.transform_identity()
    node.children = make([dynamic]Handle, 0)
    parent_node(&engine.nodes, engine.scene.root, handle)
  }
  return
}

engine_run :: proc(engine: ^Engine) {
  for !engine_should_close(engine) {
    engine_update(engine)
    engine_render(engine)
  }
}
