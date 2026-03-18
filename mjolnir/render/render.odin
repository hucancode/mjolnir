package render

import geom "../geometry"
import "../gpu"
import cmd "../gpu/ui"
import "ambient"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import rd "data"
import "debug_bone"
import "debug_ui"
import dp "depth_pyramid"
import "direct_light"
import "geometry"
import rg "graph"
import "line_strip"
import "occlusion_culling"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import "random_color"
import shadow_culling_system "shadow_culling"
import shadow_render_system "shadow_render"
import shadow_sphere_culling_system "shadow_sphere_culling"
import shadow_sphere_render_system "shadow_sphere_render"
import "sprite"
import "transparent"
import ui_render "ui"
import vk "vendor:vulkan"
import "wireframe"

FRAMES_IN_FLIGHT :: rd.FRAMES_IN_FLIGHT

Handle :: rd.Handle
MeshHandle :: rd.MeshHandle
MaterialHandle :: rd.MaterialHandle
Image2DHandle :: gpu.Texture2DHandle
ImageCubeHandle :: gpu.TextureCubeHandle
LightHandle :: rd.LightHandle

MeshFlag :: rd.MeshFlag
MeshFlagSet :: rd.MeshFlagSet
BufferAllocation :: rd.BufferAllocation
Primitive :: rd.Primitive
ShaderFeature :: rd.ShaderFeature
ShaderFeatureSet :: rd.ShaderFeatureSet
NodeFlag :: rd.NodeFlag
NodeFlagSet :: rd.NodeFlagSet
Node :: rd.Node
Mesh :: rd.Mesh
Material :: rd.Material
Emitter :: rd.Emitter
ForceField :: rd.ForceField
Sprite :: rd.Sprite
LightType :: rd.LightType
BoneInstance :: debug_bone.BoneInstance

Manager :: struct {
  using data_manager:       DataManager,
  // Foundational GPU resources
  texture_manager:          gpu.TextureManager,
  mesh_manager:             gpu.MeshManager,
  // Samplers
  linear_repeat_sampler:    vk.Sampler,
  linear_clamp_sampler:     vk.Sampler,
  nearest_repeat_sampler:   vk.Sampler,
  nearest_clamp_sampler:    vk.Sampler,
  // Command buffers
  command_buffers:          [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers:  [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  // Frame graph
  frame_graph:              rg.Graph,
  force_graph_rebuild:      bool,
  show_debug_ui:            bool,
  // Swapchain context for frame graph (set per-frame)
  current_swapchain_image:  vk.Image,
  current_swapchain_view:   vk.ImageView,
  current_swapchain_extent: vk.Extent2D,
  swapchain_format:         vk.Format,
  // Scene topology
  per_camera_data:          map[u32]Camera,
  per_light_data:           map[u32]Light,
  ui_commands:              [dynamic]cmd.RenderCommand, // Staged commands from UI module
  // Renderers
  geometry:                 geometry.Renderer,
  ambient:                  ambient.Renderer,
  direct_light:             direct_light.Renderer,
  transparent_renderer:     transparent.Renderer,
  sprite_renderer:          sprite.Renderer,
  wireframe_renderer:       wireframe.Renderer,
  line_strip_renderer:      line_strip.Renderer,
  random_color_renderer:    random_color.Renderer,
  particles_compute:        particles_compute.Renderer,
  particles_render:         particles_render.Renderer,
  post_process:             post_process.Renderer,
  debug_ui:                 debug_ui.Renderer,
  debug_renderer:           debug_bone.Renderer,
  ui:                       ui_render.Renderer,
  // Compute systems
  visibility:               occlusion_culling.System,
  depth_pyramid:            dp.System,
  shadow_culling:           shadow_culling_system.System,
  shadow_sphere_culling:    shadow_sphere_culling_system.System,
  shadow_render:            shadow_render_system.System,
  shadow_sphere_render:     shadow_sphere_render_system.System,
}

init :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> (
  ret: vk.Result,
) {
  self.per_camera_data = make(map[u32]Camera)
  self.per_light_data = make(map[u32]Light)
  self.ui_commands = make([dynamic]cmd.RenderCommand, 0, 256)
  self.swapchain_format = swapchain_format
  gpu.allocate_command_buffer(gctx, self.command_buffers[:]) or_return
  defer if ret != .SUCCESS {
    gpu.free_command_buffer(gctx, ..self.command_buffers[:])
  }
  if gctx.has_async_compute {
    gpu.allocate_compute_command_buffer(
      gctx,
      self.compute_command_buffers[:],
    ) or_return
    defer if ret != .SUCCESS {
      gpu.free_compute_command_buffer(gctx, self.compute_command_buffers[:])
    }
  }
  // Initialize mesh manager (survives teardown/setup cycles)
  gpu.mesh_manager_init(&self.mesh_manager, gctx)
  defer if ret != .SUCCESS {
    gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  }
  // Initialize all scene/frame buffers (survive teardown/setup cycles)
  data_manager_init(&self.data_manager, gctx) or_return
  defer if ret != .SUCCESS {
    data_manager_shutdown(&self.data_manager, gctx)
  }
  // Initialize texture manager layout (must precede pipeline layout creation)
  gpu.texture_manager_init(&self.texture_manager, gctx) or_return
  defer if ret != .SUCCESS {
    gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  }
  info := vk.SamplerCreateInfo {
    sType        = .SAMPLER_CREATE_INFO,
    magFilter    = .LINEAR,
    minFilter    = .LINEAR,
    addressModeU = .REPEAT,
    addressModeV = .REPEAT,
    addressModeW = .REPEAT,
    mipmapMode   = .LINEAR,
    maxLod       = 1000,
  }
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.linear_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
    self.linear_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.linear_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
    self.linear_clamp_sampler = 0
  }
  info.magFilter, info.minFilter = .NEAREST, .NEAREST
  info.addressModeU, info.addressModeV, info.addressModeW =
    .REPEAT, .REPEAT, .REPEAT
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
    self.nearest_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
    self.nearest_clamp_sampler = 0
  }
  // Initialize all subsystems (pipeline creation only)
  occlusion_culling.init(&self.visibility, gctx) or_return
  dp.init(&self.depth_pyramid, gctx) or_return
  shadow_culling_system.init(&self.shadow_culling, gctx) or_return
  shadow_sphere_culling_system.init(
    &self.shadow_sphere_culling,
    gctx,
  ) or_return
  shadow_render_system.init(
    &self.shadow_render,
    gctx,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  shadow_sphere_render_system.init(
    &self.shadow_sphere_render,
    gctx,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  ambient.init(
    &self.ambient,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  direct_light.init(
    &self.direct_light,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  geometry.init(
    &self.geometry,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  particles_compute.init(
    &self.particles_compute,
    gctx,
    self.emitter_buffer.set_layout,
    self.forcefield_buffer.set_layout,
    self.node_data_buffer.set_layout,
  ) or_return
  particles_render.init(
    &self.particles_render,
    gctx,
    &self.texture_manager,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  transparent.init(
    &self.transparent_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  sprite.init(
    &self.sprite_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.node_data_buffer.set_layout,
    self.sprite_buffer.set_layout,
  ) or_return
  wireframe.init(
    &self.wireframe_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  line_strip.init(
    &self.line_strip_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  random_color.init(
    &self.random_color_renderer,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  post_process.init(
    &self.post_process,
    gctx,
    swapchain_format,
    self.texture_manager.set_layout,
  ) or_return
  debug_ui.init(
    &self.debug_ui,
    gctx,
    swapchain_format,
    swapchain_extent,
    dpi_scale,
    self.texture_manager.set_layout,
  ) or_return
  debug_bone.init(
    &self.debug_renderer,
    gctx,
    self.camera_buffer.set_layout,
  ) or_return
  ui_render.init(
    &self.ui,
    gctx,
    self.texture_manager.set_layout,
    swapchain_format,
  ) or_return
  return .SUCCESS
}

setup :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
) -> (
  ret: vk.Result,
) {
  // Allocate textures descriptor set and init texture pools
  gpu.texture_manager_setup(
    &self.texture_manager,
    gctx,
    {
      self.nearest_clamp_sampler,
      self.linear_clamp_sampler,
      self.nearest_repeat_sampler,
      self.linear_repeat_sampler,
    },
  ) or_return
  defer if ret != .SUCCESS {
    gpu.texture_manager_teardown(&self.texture_manager, gctx)
  }
  // Reallocate descriptor sets for scene buffers + allocate particle buffers
  data_manager_setup(&self.data_manager, gctx) or_return
  gpu.mesh_manager_realloc_descriptors(&self.mesh_manager, gctx) or_return
  // Setup subsystem GPU resources
  ambient.setup(&self.ambient, gctx, &self.texture_manager) or_return
  direct_light.setup(&self.direct_light, gctx) or_return
  particles_compute.setup(
    &self.particles_compute,
    gctx,
    self.emitter_buffer.descriptor_set,
    self.forcefield_buffer.descriptor_set,
    &self.particle_buffer,
    &self.compact_particle_buffer,
    &self.particle_draw_command_buffer,
  ) or_return
  post_process.setup(
    &self.post_process,
    gctx,
    &self.texture_manager,
    swapchain_extent,
    swapchain_format,
  ) or_return
  debug_ui.setup(&self.debug_ui, gctx, &self.texture_manager) or_return
  ui_render.setup(&self.ui, gctx) or_return
  return .SUCCESS
}

teardown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  // Destroy camera GPU resources (VkImages, draw command buffers) before texture_manager goes away
  for _, &cam in self.per_camera_data {
    camera_destroy(gctx, &cam, &self.texture_manager)
  }
  clear(&self.per_camera_data)
  shadow_keys := make([dynamic]u32, 0, context.temp_allocator)
  for light_node_index in self.per_light_data {
    append(&shadow_keys, light_node_index)
  }
  for light_node_index in shadow_keys {
    remove_light_entry(&self.per_light_data, gctx, light_node_index)
  }
  clear(&self.per_light_data)
  ui_render.teardown(&self.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles_compute.teardown(&self.particles_compute, gctx)
  // Destroy particle buffers and zero descriptor set handles
  data_manager_teardown(&self.data_manager, gctx)
  ambient.teardown(&self.ambient, gctx, &self.texture_manager)
  direct_light.teardown(&self.direct_light, gctx)
  // Destroy graph-owned GPU resources before texture_manager goes away
  rg.destroy(&self.frame_graph, gctx, &self.texture_manager)
  gpu.texture_manager_teardown(&self.texture_manager, gctx)
  // Zero mesh manager descriptor (freed in bulk below)
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
  // Bulk-free all descriptor sets allocated from the pool
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
  when DEBUG_SHOW_BONES {
    debug_bone.clear_bones(&self.debug_renderer)
  }
}

clear_mesh :: proc(self: ^Manager, handle: u32) {
  free_mesh_geometry(&self.data_manager, &self.mesh_manager, handle)
}

// Stage UI commands from UI module
stage_ui_commands :: proc(self: ^Manager, commands: []cmd.RenderCommand) {
  clear(&self.ui_commands)
  for command in commands {
    append(&self.ui_commands, command)
  }
}

// Stage bone visualization instances for debug rendering
stage_bone_visualization :: proc(
  self: ^Manager,
  instances: []debug_bone.BoneInstance,
) {
  debug_bone.stage_bones(&self.debug_renderer, instances)
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.free_command_buffer(gctx, ..self.command_buffers[:])
  if gctx.has_async_compute {
    gpu.free_compute_command_buffer(gctx, self.compute_command_buffers[:])
  }
  ui_render.shutdown(&self.ui, gctx)
  delete(self.ui_commands)
  debug_bone.shutdown(&self.debug_renderer, gctx)
  debug_ui.shutdown(&self.debug_ui, gctx)
  post_process.shutdown(&self.post_process, gctx)
  particles_compute.shutdown(&self.particles_compute, gctx)
  particles_render.shutdown(&self.particles_render, gctx)
  transparent.shutdown(&self.transparent_renderer, gctx)
  sprite.shutdown(&self.sprite_renderer, gctx)
  wireframe.shutdown(&self.wireframe_renderer, gctx)
  line_strip.shutdown(&self.line_strip_renderer, gctx)
  random_color.shutdown(&self.random_color_renderer, gctx)
  ambient.shutdown(&self.ambient, gctx)
  direct_light.shutdown(&self.direct_light, gctx)
  shadow_sphere_render_system.shutdown(&self.shadow_sphere_render, gctx)
  shadow_render_system.shutdown(&self.shadow_render, gctx)
  shadow_sphere_culling_system.shutdown(&self.shadow_sphere_culling, gctx)
  shadow_culling_system.shutdown(&self.shadow_culling, gctx)
  geometry.shutdown(&self.geometry, gctx)
  dp.shutdown(&self.depth_pyramid, gctx)
  occlusion_culling.shutdown(&self.visibility, gctx)
  vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
  self.linear_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
  self.linear_clamp_sampler = 0
  vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
  self.nearest_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
  self.nearest_clamp_sampler = 0
  gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  data_manager_shutdown(&self.data_manager, gctx)
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  delete(self.per_camera_data)
  delete(self.per_light_data)
}

resize :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  post_process.recreate_images(
    gctx,
    &self.post_process,
    &self.texture_manager,
    extent,
    color_format,
  ) or_return
  debug_ui.recreate_images(&self.debug_ui, color_format, extent, dpi_scale)
  return .SUCCESS
}

// ============================================================================
// Frame Graph Compilation
// ============================================================================

// Compile frame graph from current topology (camera/light counts)
compile_frame_graph :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  log.info("Compiling frame rg...")

  // Build camera and light handle arrays for graph context
  camera_handles := make([dynamic]u32, 0, len(self.per_camera_data))
  defer delete(camera_handles)
  for handle in self.per_camera_data {
    append(&camera_handles, handle)
  }
  slice.sort(camera_handles[:])

  light_handles := make([dynamic]u32, 0, len(self.per_light_data))
  defer delete(light_handles)
  for handle in self.per_light_data {
    append(&light_handles, handle)
  }
  slice.sort(light_handles[:])

  log.infof(
    "Frame graph topology: %d cameras, %d lights",
    len(camera_handles),
    len(light_handles),
  )

  // Validate we have at least one camera
  if len(camera_handles) == 0 {
    log.warn(
      "No cameras registered - frame graph requires at least one camera",
    )
    return .ERROR_UNKNOWN
  }

  // Build topology hint arrays (temp memory, valid for duration of compile)
  camera_extents := make(
    []vk.Extent2D,
    len(camera_handles),
    context.temp_allocator,
  )
  for h, i in camera_handles {
    if cam, ok := self.per_camera_data[h]; ok {
      camera_extents[i] = cam.render_extent
    } else {
      camera_extents[i] = vk.Extent2D{1920, 1080}
    }
  }
  light_kinds := make(
    []rg.LightKind,
    len(light_handles),
    context.temp_allocator,
  )
  for h, i in light_handles {
    if ld, ok := self.per_light_data[h]; ok {
      switch _ in ld {
      case PointLight:
        light_kinds[i] = .POINT
      case SpotLight:
        light_kinds[i] = .SPOT
      case DirectionalLight:
        light_kinds[i] = .DIRECTIONAL
      }
    }
  }

  // Create compile context
  ctx := rg.CompileContext {
    num_cameras      = len(camera_handles),
    num_lights       = len(light_handles),
    frames_in_flight = FRAMES_IN_FLIGHT,
    camera_handles   = camera_handles[:],
    light_handles    = light_handles[:],
    camera_extents   = camera_extents,
    light_kinds      = light_kinds,
    swapchain_format = self.swapchain_format,
  }

  // Build pass declarations
  pass_decls := build_pass_declarations()
  defer delete(pass_decls)

  if err := rg.build_graph(
    &self.frame_graph,
    pass_decls[:],
    ctx,
    gctx,
    &self.texture_manager,
  ); err != .NONE {
    log.errorf("Failed to build frame graph: %v", err)
    return .ERROR_UNKNOWN
  }

  log.infof(
    "Frame graph compiled: %d passes, %d cameras, %d lights",
    rg.pass_count(&self.frame_graph),
    len(camera_handles),
    len(light_handles),
  )

  return .SUCCESS
}

// get_camera_final_image returns the bindless texture handle of the final rendered
// image for the given camera (as allocated by the frame graph).
get_camera_final_image :: proc(
  manager: ^Manager,
  camera_handle_index: u32,
  frame_index: u32,
) -> (
  gpu.Texture2DHandle,
  bool,
) {
  // Find the graph instance_idx for this camera handle
  instance_idx: int = -1
  for i in 0 ..< rg.camera_handle_count(&manager.frame_graph) {
    if rg.get_camera_handle(&manager.frame_graph, i) == camera_handle_index {
      instance_idx = i
      break
    }
  }
  if instance_idx < 0 do return {}, false
  resource_name := fmt.tprintf("final_image_cam_%d", instance_idx)
  bits, found := rg.get_texture_handle(
    &manager.frame_graph,
    resource_name,
    frame_index,
  )
  if !found do return {}, false
  return transmute(gpu.Texture2DHandle)bits, true
}

// Build array of pass declarations for frame graph compilation.
// Each PassDecl includes an execute callback proc literal.
// At runtime the manager is passed as rawptr (ctx) and cast back to ^Manager.
build_pass_declarations :: proc() -> [dynamic]rg.PassDecl {
  decls := make([dynamic]rg.PassDecl, 0, 15)
  // Compute passes
  append(&decls, rg.PassDecl {
    name = "particles_compute",
    scope = .GLOBAL,
    queue = .COMPUTE,
    setup = particles_compute.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      particles_compute.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "depth_pyramid",
    scope = .PER_CAMERA,
    queue = .COMPUTE,
    setup = dp.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      dp.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "occlusion_culling",
    scope = .PER_CAMERA,
    queue = .COMPUTE,
    setup = occlusion_culling.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      occlusion_culling.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "shadow_culling_spot",
    scope = .PER_SPOT_LIGHT,
    queue = .COMPUTE,
    setup = shadow_culling_system.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      shadow_culling_system.execute_spot(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "shadow_culling_directional",
    scope = .PER_DIRECTIONAL_LIGHT,
    queue = .COMPUTE,
    setup = shadow_culling_system.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      shadow_culling_system.execute_directional(
        cast(^Manager)ctx,
        resources,
        cmd,
        fi,
      )
    },
  })
  append(&decls, rg.PassDecl {
    name = "shadow_culling_sphere",
    scope = .PER_POINT_LIGHT,
    queue = .COMPUTE,
    setup = shadow_sphere_culling_system.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      shadow_sphere_culling_system.execute_point(
        cast(^Manager)ctx,
        resources,
        cmd,
        fi,
      )
    },
  })
  // Graphics passes
  append(&decls, rg.PassDecl {
    name = "shadow_render_spot",
    scope = .PER_SPOT_LIGHT,
    queue = .GRAPHICS,
    setup = shadow_render_system.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      shadow_render_system.execute_spot(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "shadow_render_directional",
    scope = .PER_DIRECTIONAL_LIGHT,
    queue = .GRAPHICS,
    setup = shadow_render_system.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      shadow_render_system.execute_directional(
        cast(^Manager)ctx,
        resources,
        cmd,
        fi,
      )
    },
  })
  append(&decls, rg.PassDecl {
    name = "shadow_render_sphere",
    scope = .PER_POINT_LIGHT,
    queue = .GRAPHICS,
    setup = shadow_sphere_render_system.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      shadow_sphere_render_system.execute_point(
        cast(^Manager)ctx,
        resources,
        cmd,
        fi,
      )
    },
  })
  append(&decls, rg.PassDecl {
    name = "geometry",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = geometry.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      geometry.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "ambient",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = ambient.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      ambient.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "direct_light_point",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = direct_light.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      direct_light.execute_point(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "direct_light_spot",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = direct_light.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      direct_light.execute_spot(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "direct_light_directional",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = direct_light.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      direct_light.execute_directional(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "particles_render",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = particles_render.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      particles_render.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "transparent",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = transparent.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      transparent.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "wireframe",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = wireframe.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      wireframe.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "random_color",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = random_color.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      random_color.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "line_strip",
    scope = .PER_CAMERA,
    queue = .GRAPHICS,
    setup = line_strip.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      line_strip.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "post_process",
    scope = .GLOBAL,
    queue = .GRAPHICS,
    setup = post_process.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      post_process.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "ui",
    scope = .GLOBAL,
    queue = .GRAPHICS,
    setup = ui_render.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      ui_render.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  append(&decls, rg.PassDecl {
    name = "debug_ui",
    scope = .GLOBAL,
    queue = .GRAPHICS,
    setup = debug_ui.declare_resources,
    execute = proc(
      ctx: rawptr,
      resources: ^rg.PassResources,
      cmd: vk.CommandBuffer,
      fi: u32,
    ) {
      debug_ui.execute(cast(^Manager)ctx, resources, cmd, fi)
    },
  })
  return decls
}

// ── Shadow map types ──────────────────────────────────────────────────────────

ShadowMap :: rd.ShadowMap
ShadowMapCube :: rd.ShadowMapCube

// ── Light types ───────────────────────────────────────────────────────────────

PointLight :: rd.PointLight
SpotLight :: rd.SpotLight
DirectionalLight :: rd.DirectionalLight
Light :: rd.Light

// ── Pass type ─────────────────────────────────────────────────────────────────

PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  POST_PROCESS = 5,
}

PassTypeSet :: bit_set[PassType;u32]

// DrawType enumerates indirect draw buffer slots, in the order they are bound
// to the culling descriptor set (must match shader layout binding order).
DrawType :: rd.DrawType

// ── Camera type ───────────────────────────────────────────────────────────────

Camera :: struct {
  // Render pass configuration
  enabled_passes:               PassTypeSet,
  render_extent:                vk.Extent2D,
  // Visibility culling control flags
  enable_culling:               bool, // If false, skip culling compute pass
  // Depth attachment (Camera-owned; needed for depth pyramid descriptor sets)
  depth:                        [FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  // G-buffer and final_image are now owned by the frame graph (Phase 2)
  // Indirect draw buffers (double-buffered for async compute)
  // Frame N compute writes to buffers[N], Frame N graphics reads from buffers[N-1]
  draw_count:                   [DrawType][FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    u32,
  ),
  draw_commands:                [DrawType][FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  // Depth pyramid for hierarchical Z culling
  depth_pyramid:                [FRAMES_IN_FLIGHT]dp.DepthPyramid,
  // Descriptor sets for visibility culling compute shaders
  descriptor_set:               [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][dp.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

// ── Debug constants ───────────────────────────────────────────────────────────

DEBUG_SHOW_BONES :: #config(DEBUG_SHOW_BONES, false)
DEBUG_BONE_SCALE :: #config(DEBUG_BONE_SCALE, 0.15)
DEBUG_BONE_PALETTE :: [6][4]f32 {
  {1.0, 0.0, 0.0, 1.0}, // Level 0: Red (root bones)
  {0.0, 1.0, 0.0, 1.0}, // Level 1: Green
  {0.0, 0.0, 1.0, 1.0}, // Level 2: Blue
  {1.0, 1.0, 1.0, 1.0}, // Level 3: White
  {1.0, 0.5, 0.0, 1.0}, // Level 4: Orange
  {0.0, 1.0, 1.0, 1.0}, // Level 5: Cyan
}

// ── Camera helpers ────────────────────────────────────────────────────────────

// Allocate per-frame depth textures and transition them to DEPTH_STENCIL_READ_ONLY_OPTIMAL.
// Called from both camera_init and camera_resize.
@(private)
camera_allocate_depth_buffers :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  depth_format: vk.Format,
) -> vk.Result {
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    camera.depth[frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    if depth := gpu.get_texture_2d(texture_manager, camera.depth[frame]);
       depth != nil {
      cmd_buf := gpu.begin_single_time_command(gctx) or_return
      gpu.image_barrier(
        cmd_buf,
        depth.image,
        .UNDEFINED,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_READ},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      gpu.end_single_time_command(gctx, &cmd_buf) or_return
    }
  }
  return .SUCCESS
}

// Create a (draw_count, draw_commands) buffer pair for one frame slot.
@(private)
create_draw_buffer_pair :: proc(
  gctx: ^gpu.GPUContext,
  count: ^gpu.MutableBuffer(u32),
  commands: ^gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  max_draws: int,
) -> vk.Result {
  count^ = gpu.create_mutable_buffer(
    gctx,
    u32,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
  ) or_return
  commands^ = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndexedIndirectCommand,
    max_draws,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
  ) or_return
  return .SUCCESS
}

// Destroy a (draw_count, draw_commands) buffer pair.
@(private)
destroy_draw_buffer_pair :: proc(
  device: vk.Device,
  count: ^gpu.MutableBuffer(u32),
  commands: ^gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
) {
  gpu.mutable_buffer_destroy(device, count)
  gpu.mutable_buffer_destroy(device, commands)
}

// ── Camera lifecycle ──────────────────────────────────────────────────────────

// Initialize GPU resources for perspective camera.
camera_init :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .POST_PROCESS,
  },
  max_draws: u32,
) -> vk.Result {
  camera.render_extent = extent
  camera.enabled_passes = enabled_passes

  // G-buffer and final_image textures are owned by the frame graph (Phase 2).
  // Only allocate the depth buffer here (needed for depth pyramid descriptor sets).
  camera_allocate_depth_buffers(
    gctx,
    camera,
    texture_manager,
    extent,
    depth_format,
  ) or_return

  // Create indirect draw buffers (double-buffered)
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    d := int(max_draws)
    for dt in DrawType {
      create_draw_buffer_pair(
        gctx,
        &camera.draw_count[dt][frame],
        &camera.draw_commands[dt][frame],
        d,
      ) or_return
    }
  }

  if camera.enable_culling {
    for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
      dp.setup_pyramid(
        gctx,
        &camera.depth_pyramid[frame],
        texture_manager,
        extent,
      ) or_return
    }
  }

  return .SUCCESS
}

// Destroy GPU resources for perspective/orthographic camera.
camera_destroy :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
) {
  // Free depth textures (Camera-owned; G-buffer owned by frame graph)
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    if camera.depth[frame].index != 0 {
      gpu.free_texture_2d(texture_manager, gctx, camera.depth[frame])
    }
  }

  // Destroy depth pyramids
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    dp.destroy_pyramid(gctx, &camera.depth_pyramid[frame], texture_manager)
  }

  // Destroy indirect draw buffers
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    for dt in DrawType {
      destroy_draw_buffer_pair(
        gctx.device,
        &camera.draw_count[dt][frame],
        &camera.draw_commands[dt][frame],
      )
    }
  }
  // Zero out the GPU struct
  camera^ = {}
}

// Allocate descriptor sets for perspective/orthographic camera culling pipelines.
camera_allocate_descriptors :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  normal_descriptor_layout: ^vk.DescriptorSetLayout,
  depth_reduce_descriptor_layout: ^vk.DescriptorSetLayout,
  node_data_buffer: ^gpu.BindlessBuffer(rd.Node),
  mesh_data_buffer: ^gpu.BindlessBuffer(rd.Mesh),
  camera_buffer: ^gpu.PerFrameBindlessBuffer(rd.Camera, rd.FRAMES_IN_FLIGHT),
) -> vk.Result {
  for frame_index in 0 ..< rd.FRAMES_IN_FLIGHT {
    prev_frame_index :=
      (frame_index + rd.FRAMES_IN_FLIGHT - 1) % rd.FRAMES_IN_FLIGHT
    pyramid := &camera.depth_pyramid[frame_index]
    prev_pyramid := &camera.depth_pyramid[prev_frame_index]
    prev_depth := gpu.get_texture_2d(
      texture_manager,
      camera.depth[prev_frame_index],
    )
    if prev_depth == nil {
      log.errorf(
        "allocate_descriptors: missing depth attachment for frame %d",
        prev_frame_index,
      )
      return .ERROR_INITIALIZATION_FAILED
    }
    if pyramid.mip_levels == 0 {
      log.errorf(
        "allocate_descriptors: missing depth pyramid for frame %d",
        frame_index,
      )
      return .ERROR_INITIALIZATION_FAILED
    }

    camera.descriptor_set[frame_index] = gpu.create_descriptor_set(
      gctx,
      normal_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&camera_buffer.buffers[frame_index])},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_count[.OPAQUE][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_commands[.OPAQUE][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_count[.TRANSPARENT][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_commands[.TRANSPARENT][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_count[.SPRITE][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_commands[.SPRITE][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_count[.WIREFRAME][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_commands[.WIREFRAME][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_count[.RANDOM_COLOR][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_commands[.RANDOM_COLOR][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_count[.LINE_STRIP][frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draw_commands[.LINE_STRIP][frame_index]),
      },
      {
        .COMBINED_IMAGE_SAMPLER,
        vk.DescriptorImageInfo {
          sampler = prev_pyramid.sampler,
          imageView = prev_pyramid.full_view,
          imageLayout = .GENERAL,
        },
      },
    ) or_return

    for mip in 0 ..< pyramid.mip_levels {
      source_info: vk.DescriptorImageInfo
      if mip == 0 {
        source_info = {
          sampler     = pyramid.sampler,
          imageView   = prev_depth.view,
          imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        }
      } else {
        source_info = {
          sampler     = pyramid.sampler,
          imageView   = pyramid.views[mip - 1],
          imageLayout = .GENERAL,
        }
      }
      dest_info := vk.DescriptorImageInfo {
        imageView   = pyramid.views[mip],
        imageLayout = .GENERAL,
      }
      camera.depth_reduce_descriptor_sets[frame_index][mip] =
        gpu.create_descriptor_set(
          gctx,
          depth_reduce_descriptor_layout,
          {.COMBINED_IMAGE_SAMPLER, source_info},
          {.STORAGE_IMAGE, dest_info},
        ) or_return
    }
  }

  return .SUCCESS
}

// Resize camera render targets (called on window resize).
camera_resize :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  camera.render_extent = extent
  camera.enabled_passes = enabled_passes

  // Free old depth textures (Camera-owned; G-buffer owned by frame graph)
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    if camera.depth[frame].index != 0 {
      gpu.free_texture_2d(texture_manager, gctx, camera.depth[frame])
      camera.depth[frame] = {}
    }
  }

  // Destroy old depth pyramids
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    pyramid := &camera.depth_pyramid[frame]
    if pyramid.mip_levels == 0 do continue

    for mip in 0 ..< pyramid.mip_levels {
      vk.DestroyImageView(gctx.device, pyramid.views[mip], nil)
    }
    vk.DestroyImageView(gctx.device, pyramid.full_view, nil)
    vk.DestroySampler(gctx.device, pyramid.sampler, nil)

    gpu.free_texture_2d(texture_manager, gctx, pyramid.texture)
    pyramid^ = {}
  }

  // Reallocate depth texture at new extent
  camera_allocate_depth_buffers(
    gctx,
    camera,
    texture_manager,
    extent,
    depth_format,
  ) or_return
  if camera.enable_culling {
    for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
      dp.setup_pyramid(
        gctx,
        &camera.depth_pyramid[frame],
        texture_manager,
        extent,
      ) or_return
    }
  }

  log.infof("Camera resized to %dx%d", extent.width, extent.height)
  return .SUCCESS
}

// ── Light / shadow helpers ────────────────────────────────────────────────────

@(private)
shadow_make_light_view :: proc(
  position, direction: [3]f32,
) -> matrix[4, 4]f32 {
  forward := geom.safe_normalize(direction, {0, -1, 0})
  up := [3]f32{0, 1, 0}
  if math.abs(linalg.dot(forward, up)) > 0.95 {
    up = {0, 0, 1}
  }
  target := position + forward
  return linalg.matrix4_look_at(position, target, up)
}

// prepare_lights_for_frame computes shadow matrices (view, projection, frustum
// planes) for all lights up to MAX_LIGHTS. Must be called once per frame
// before the frame graph executes shadow culling/rendering.
prepare_lights_for_frame :: proc(per_light_data: ^map[u32]Light) {
  light_node_indices := make(
    [dynamic]u32,
    0,
    len(per_light_data),
    context.temp_allocator,
  )
  defer delete(light_node_indices)
  for light_node_index in per_light_data {
    append(&light_node_indices, light_node_index)
  }
  slice.sort(light_node_indices[:])
  for light_node_index, i in light_node_indices {
    if i >= int(rd.MAX_LIGHTS) do break
    light := &per_light_data[light_node_index]
    switch &variant in light {
    case PointLight:
      shadow, has_shadow := &variant.shadow.?
      if has_shadow {
        shadow.near = 0.1
        shadow.far = max(shadow.near + 0.1, variant.radius)
        shadow.projection = linalg.matrix4_perspective(
          f32(math.PI * 0.5),
          1.0,
          shadow.near,
          shadow.far,
          flip_z_axis = false,
        )
      }
    case SpotLight:
      shadow, has_shadow := &variant.shadow.?
      if has_shadow {
        shadow.near = 0.1
        shadow.far = max(shadow.near + 0.1, variant.radius)
        shadow.view = shadow_make_light_view(
          variant.position,
          variant.direction,
        )
        shadow.projection = linalg.matrix4_perspective(
          max(variant.angle_outer * 2.0, 0.001),
          1.0,
          shadow.near,
          shadow.far,
        )
        shadow.view_projection = shadow.projection * shadow.view
        shadow.frustum_planes =
          geom.make_frustum(shadow.view_projection).planes
      }
    case DirectionalLight:
      shadow, has_shadow := &variant.shadow.?
      if has_shadow {
        shadow.near = 0.1
        shadow.far = max(shadow.near + 0.1, variant.radius * 2.0)
        camera_pos := variant.position - variant.direction * variant.radius
        shadow.view = shadow_make_light_view(camera_pos, variant.direction)
        half_extent := max(variant.radius, 0.5)
        shadow.projection = linalg.matrix_ortho3d(
          -half_extent,
          half_extent,
          -half_extent,
          half_extent,
          shadow.near,
          shadow.far,
        )
        shadow.view_projection = shadow.projection * shadow.view
        shadow.frustum_planes =
          geom.make_frustum(shadow.view_projection).planes
      }
    }
  }
}

@(private)
release_shadow_2d :: proc(gctx: ^gpu.GPUContext, shadow: ^ShadowMap) {
  // Shadow map texture is now owned by the frame graph; only free draw buffers
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
}

@(private)
release_shadow_cube :: proc(gctx: ^gpu.GPUContext, shadow: ^ShadowMapCube) {
  // Shadow map texture is now owned by the frame graph; only free draw buffers
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
}

@(private)
ensure_shadow_2d_resource :: proc(
  gctx: ^gpu.GPUContext,
  culling_layout: ^vk.DescriptorSetLayout,
  node_data_buffer: ^gpu.MutableBuffer(rd.Node),
  mesh_data_buffer: ^gpu.MutableBuffer(rd.Mesh),
  shadow: ^Maybe(ShadowMap),
) -> vk.Result {
  // Check if draw buffers already allocated
  if shadow != nil {
    if sm, ok := shadow^.?; ok {
      if sm.draw_count[0].buffer != 0 do return .SUCCESS
    }
  }

  // Allocate draw buffers and descriptor sets only
  // Shadow map texture is owned by the frame graph (Phase 2)
  sm: ShadowMap
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    sm.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      culling_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(node_data_buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(mesh_data_buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_commands[frame])},
    ) or_return
  }
  shadow^ = sm
  return .SUCCESS
}

@(private)
ensure_shadow_cube_resource :: proc(
  gctx: ^gpu.GPUContext,
  sphere_culling_layout: ^vk.DescriptorSetLayout,
  node_data_buffer: ^gpu.MutableBuffer(rd.Node),
  mesh_data_buffer: ^gpu.MutableBuffer(rd.Mesh),
  shadow: ^Maybe(ShadowMapCube),
) -> vk.Result {
  // Check if draw buffers already allocated
  if shadow != nil {
    if sm, ok := shadow^.?; ok {
      if sm.draw_count[0].buffer != 0 do return .SUCCESS
    }
  }

  // Allocate draw buffers and descriptor sets only
  // Shadow map texture is owned by the frame graph (Phase 2)
  sm: ShadowMapCube
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    sm.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    sm.descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      sphere_culling_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(node_data_buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(mesh_data_buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_commands[frame])},
    ) or_return
  }
  shadow^ = sm
  return .SUCCESS
}

upsert_light_entry :: proc(
  per_light_data: ^map[u32]Light,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
  light_data: ^Light,
  cast_shadow: bool,
  culling_layout: ^vk.DescriptorSetLayout,
  sphere_culling_layout: ^vk.DescriptorSetLayout,
  node_data_buffer: ^gpu.MutableBuffer(rd.Node),
  mesh_data_buffer: ^gpu.MutableBuffer(rd.Mesh),
) -> vk.Result {
  is_existing := light_node_index in per_light_data

  if is_existing {
    // UPDATE PATH: Preserve shadow resources when updating light properties
    light := &per_light_data[light_node_index]
    existing_shadow_2d: Maybe(ShadowMap)
    existing_shadow_cube: Maybe(ShadowMapCube)

    #partial switch &variant in light {
    case SpotLight:
      existing_shadow_2d = variant.shadow
    case DirectionalLight:
      existing_shadow_2d = variant.shadow
    case PointLight:
      existing_shadow_cube = variant.shadow
    }

    // Update light data
    light^ = light_data^

    // Restore preserved shadows
    #partial switch &variant in light {
    case SpotLight:
      variant.shadow = existing_shadow_2d
    case DirectionalLight:
      variant.shadow = existing_shadow_2d
    case PointLight:
      variant.shadow = existing_shadow_cube
    }
  } else {
    // INSERT PATH: Create new entry (no shadows to preserve)
    per_light_data[light_node_index] = light_data^
  }

  // Manage shadow resources (common for both insert and update)
  light := &per_light_data[light_node_index]
  if cast_shadow {
    shadow_result: vk.Result
    switch &variant in light {
    case PointLight:
      shadow_result = ensure_shadow_cube_resource(
        gctx,
        sphere_culling_layout,
        node_data_buffer,
        mesh_data_buffer,
        &variant.shadow,
      )
    case SpotLight:
      shadow_result = ensure_shadow_2d_resource(
        gctx,
        culling_layout,
        node_data_buffer,
        mesh_data_buffer,
        &variant.shadow,
      )
    case DirectionalLight:
      shadow_result = ensure_shadow_2d_resource(
        gctx,
        culling_layout,
        node_data_buffer,
        mesh_data_buffer,
        &variant.shadow,
      )
    }
    if shadow_result != .SUCCESS {
      log.warnf(
        "Failed to allocate shadow resources for light %d: %v (shadows disabled)",
        light_node_index,
        shadow_result,
      )
    }
  } else {
    // Release shadow resources if they exist
    switch &variant in light {
    case PointLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_cube(gctx, &sm)
        variant.shadow = nil
      }
    case SpotLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_2d(gctx, &sm)
        variant.shadow = nil
      }
    case DirectionalLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_2d(gctx, &sm)
        variant.shadow = nil
      }
    }
  }

  return .SUCCESS
}

remove_light_entry :: proc(
  per_light_data: ^map[u32]Light,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  light, ok := per_light_data[light_node_index]
  if !ok do return

  // Release shadow resources if they exist
  switch &variant in light {
  case PointLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_cube(gctx, &sm)
    }
  case SpotLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_2d(gctx, &sm)
    }
  case DirectionalLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_2d(gctx, &sm)
    }
  }

  delete_key(per_light_data, light_node_index)
}
