package render

import alg "../algebra"
import cont "../containers"
import geom "../geometry"
import "../gpu"
import cmd "../gpu/ui"
import "ambient"
import "camera"
import cam "camera"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import rd "data"
import "debug_bone"
import "debug_ui"
import "direct_light"
import "geometry"
import rg "graph"
import "line_strip"
import "occlusion_culling"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import "random_color"
import "shadow"
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
Light :: rd.Light
LightType :: rd.LightType
BoneInstance :: debug_bone.BoneInstance

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

Manager :: struct {
  command_buffers:         [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers: [FRAMES_IN_FLIGHT]vk.CommandBuffer,

  // Render graph system
  graph:                   rg.Graph,
  resource_pool:           RenderResourceManager,

  // Renderers
  geometry:                geometry.Renderer,
  ambient:                 ambient.Renderer,
  direct_light:            direct_light.Renderer,
  transparent_renderer:    transparent.Renderer,
  sprite_renderer:         sprite.Renderer,
  wireframe_renderer:      wireframe.Renderer,
  line_strip_renderer:     line_strip.Renderer,
  random_color_renderer:   random_color.Renderer,
  particles_compute:       particles_compute.Renderer,
  particles_render:        particles_render.Renderer,
  post_process:            post_process.Renderer,
  debug_ui:                debug_ui.Renderer,
  debug_renderer:          debug_bone.Renderer,
  ui:                      ui_render.Renderer,
  ui_commands:             [dynamic]cmd.RenderCommand, // Staged commands from UI module
  cameras:                 map[u32]camera.Camera,
  meshes:                  map[u32]Mesh,
  visibility:              occlusion_culling.System,
  shadow:                  shadow.ShadowSystem,
  linear_repeat_sampler:   vk.Sampler,
  linear_clamp_sampler:    vk.Sampler,
  nearest_repeat_sampler:  vk.Sampler,
  nearest_clamp_sampler:   vk.Sampler,
  mesh_manager:            gpu.MeshManager,
  bone_matrix_slab:        cont.SlabAllocator,
  bone_matrix_offsets:     map[u32]u32,
  texture_manager:         gpu.TextureManager,
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
  self.cameras = make(map[u32]camera.Camera)
  self.meshes = make(map[u32]Mesh)
  self.ui_commands = make([dynamic]cmd.RenderCommand, 0, 256)

  // Initialize render graph
  rg.graph_init(&self.graph)
  resource_pool_build(&self.resource_pool)

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
  // Initialize geometry/bone/camera/scene buffers (survive teardown/setup cycles)
  gpu.mesh_manager_init(&self.mesh_manager, gctx)
  defer if ret != .SUCCESS {
    gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  }
  cont.slab_init(
    &self.bone_matrix_slab,
    {
      {32, 64},
      {64, 128},
      {128, 4096},
      {256, 1792},
      {512, 0},
      {1024, 0},
      {2048, 0},
      {4096, 0},
    },
  )
  self.bone_matrix_offsets = make(map[u32]u32)
  defer if ret != .SUCCESS {
    delete(self.bone_matrix_offsets)
    cont.slab_destroy(&self.bone_matrix_slab)
  }
  resource_pool_init_persistent(
    &self.resource_pool,
    gctx,
    int(self.bone_matrix_slab.capacity),
  ) or_return
  defer if ret != .SUCCESS {
    resource_pool_destroy_persistent(&self.resource_pool, gctx.device)
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
  occlusion_culling.init(
    &self.visibility,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.resource_pool.bone_buffer.set_layout,
    self.resource_pool.material_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  shadow.init(
    &self.shadow,
    gctx,
    self.texture_manager.set_layout,
    self.resource_pool.bone_buffer.set_layout,
    self.resource_pool.material_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  ambient.init(
    &self.ambient,
    gctx,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  direct_light.init(
    &self.direct_light,
    gctx,
    self.resource_pool.camera_buffer.set_layout,
    self.resource_pool.lights_buffer.set_layout,
    self.shadow.shadow_data_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  geometry.init(
    &self.geometry,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.resource_pool.bone_buffer.set_layout,
    self.resource_pool.material_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  particles_compute.init(
    &self.particles_compute,
    gctx,
    self.resource_pool.emitter_buffer.set_layout,
    self.resource_pool.forcefield_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
  ) or_return
  particles_render.init(
    &self.particles_render,
    gctx,
    &self.texture_manager,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return

  // Register render graph resources for particle system
  register_particle_resources(self)

  // Register render graph resources for UI system
  register_ui_resources(self)

  // Register render graph resources for shadow system
  register_shadow_resources(self)

  // Register render graph resources for post-process system
  register_post_process_resources(self)

  // Initialize transparency renderers
  transparent.init(
    &self.transparent_renderer,
    gctx,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.resource_pool.bone_buffer.set_layout,
    self.resource_pool.material_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  sprite.init(
    &self.sprite_renderer,
    gctx,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.sprite_buffer.set_layout,
  ) or_return
  wireframe.init(
    &self.wireframe_renderer,
    gctx,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.resource_pool.bone_buffer.set_layout,
    self.resource_pool.material_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  line_strip.init(
    &self.line_strip_renderer,
    gctx,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.resource_pool.bone_buffer.set_layout,
    self.resource_pool.material_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  random_color.init(
    &self.random_color_renderer,
    gctx,
    self.resource_pool.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.resource_pool.bone_buffer.set_layout,
    self.resource_pool.material_buffer.set_layout,
    self.resource_pool.node_data_buffer.set_layout,
    self.resource_pool.mesh_data_buffer.set_layout,
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
    self.resource_pool.camera_buffer.set_layout,
  ) or_return
  ui_render.init_renderer(
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
  // Re-allocate descriptor sets for scene buffers (freed by previous ResetDescriptorPool)
  resource_pool_realloc_descriptors(&self.resource_pool, gctx) or_return
  gpu.mesh_manager_realloc_descriptors(&self.mesh_manager, gctx) or_return
  // Allocate resource-pool owned per-setup resources.
  resource_pool_setup(
    &self.resource_pool,
    gctx,
    &self.texture_manager,
  ) or_return
  defer if ret != .SUCCESS {
    resource_pool_teardown(&self.resource_pool, gctx, &self.texture_manager)
  }
  // Setup subsystem GPU resources
  ambient.setup(&self.ambient, gctx, &self.texture_manager) or_return
  direct_light.setup(&self.direct_light, gctx) or_return
  shadow.setup(
    &self.shadow,
    gctx,
    &self.texture_manager,
    &self.resource_pool.node_data_buffer,
    &self.resource_pool.mesh_data_buffer,
    &self.resource_pool.shadow_spot_maps,
    &self.resource_pool.shadow_directional_maps,
    &self.resource_pool.shadow_point_cubes,
    &self.resource_pool.shadow_spot_draw_counts,
    &self.resource_pool.shadow_spot_draw_commands,
    &self.resource_pool.shadow_directional_draw_counts,
    &self.resource_pool.shadow_directional_draw_commands,
    &self.resource_pool.shadow_point_draw_counts,
    &self.resource_pool.shadow_point_draw_commands,
  ) or_return
  particles_compute.setup(
    &self.particles_compute,
    gctx,
    self.resource_pool.emitter_buffer.descriptor_set,
    self.resource_pool.forcefield_buffer.descriptor_set,
    self.resource_pool.node_data_buffer.descriptor_set,
    &self.resource_pool.particle_resources.particle_buffer,
    &self.resource_pool.particle_resources.compact_particle_buffer,
    &self.resource_pool.particle_resources.draw_command_buffer,
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
  // Destroy render graph
  rg.graph_destroy(&self.graph)

  // Camera GPU resources are pool-owned (P0.3) and released via resource_pool_teardown.
  clear(&self.cameras)
  ui_render.teardown(&self.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles_compute.teardown(&self.particles_compute, gctx)
  resource_pool_teardown(&self.resource_pool, gctx, &self.texture_manager)
  shadow.teardown(&self.shadow, gctx, &self.texture_manager)
  ambient.teardown(&self.ambient, gctx, &self.texture_manager)
  direct_light.teardown(&self.direct_light, gctx)
  gpu.texture_manager_teardown(&self.texture_manager, gctx)
  // Zero all descriptor set handles (freed in bulk below)
  resource_pool_zero_descriptors(&self.resource_pool)
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
  // Bulk-free all descriptor sets allocated from the pool
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
}

@(private)
ensure_camera_slot :: proc(self: ^Manager, handle: u32) {
  if handle not_in self.cameras {
    self.cameras[handle] = {}
  }
}

@(private)
get_camera :: proc(
  self: ^Manager,
  handle: u32,
) -> (
  cam: camera.Camera,
  ok: bool,
) #optional_ok {
  cam, ok = self.cameras[handle]
  if !ok do return {}, false
  return cam, true
}

@(private)
ensure_mesh_slot :: proc(self: ^Manager, handle: u32) {
  if _, ok := self.meshes[handle]; !ok {
    self.meshes[handle] = {}
  }
}

sync_camera_from_world :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  handle: u32,
  world_camera: ^camera.Camera,
  swapchain_format: vk.Format,
) {
}

clear_mesh :: proc(self: ^Manager, handle: u32) {
  if _, ok := self.meshes[handle]; !ok do return
  free_mesh_geometry(self, handle)
  upload_mesh_data(self, handle, &Mesh{})
}

record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  cmd :=
    gctx.has_async_compute ? self.compute_command_buffers[frame_index] : self.command_buffers[frame_index]
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with rd.FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := alg.next(frame_index, rd.FRAMES_IN_FLIGHT)
  for cam_index, &cam in self.cameras {
    if cam_index >= rd.MAX_ACTIVE_CAMERAS do continue
    cam_idx := u32(cam_index)

    // Only build pyramid if enabled for this camera
    if cam.enable_depth_pyramid {
      occlusion_culling.build_pyramid(
        &self.visibility,
        gctx,
        cmd,
        &self.resource_pool.camera_depth_pyramids[cam_idx][frame_index],
        &self.resource_pool.camera_depth_reduce_descriptor_sets[cam_idx][frame_index],
        &self.resource_pool.camera_opaque_draw_counts[cam_idx][frame_index],
        cam_idx,
        frame_index,
      ) // Build pyramid[N]
    }
    // Only perform culling if enabled for this camera
    if cam.enable_culling {
      prev_frame := alg.prev(next_frame_index, rd.FRAMES_IN_FLIGHT)
      pyramid := self.resource_pool.camera_depth_pyramids[cam_idx][prev_frame]
      occlusion_culling.perform_culling(
        &self.visibility,
        gctx,
        cmd,
        cam_idx,
        next_frame_index,
        {.VISIBLE},
        {},
        &self.resource_pool.camera_opaque_draw_counts[cam_idx][next_frame_index],
        &self.resource_pool.camera_transparent_draw_counts[cam_idx][next_frame_index],
        &self.resource_pool.camera_wireframe_draw_counts[cam_idx][next_frame_index],
        &self.resource_pool.camera_random_color_draw_counts[cam_idx][next_frame_index],
        &self.resource_pool.camera_line_strip_draw_counts[cam_idx][next_frame_index],
        &self.resource_pool.camera_sprite_draw_counts[cam_idx][next_frame_index],
        self.resource_pool.camera_cull_input_descriptor_sets[cam_idx][next_frame_index],
        self.resource_pool.camera_cull_output_descriptor_sets[cam_idx][next_frame_index],
        pyramid.width,
        pyramid.height,
      ) // Write draw_list[N+1]
    }
  }
  particles_compute.simulate(
    &self.particles_compute,
    cmd,
    self.resource_pool.node_data_buffer.descriptor_set,
    self.resource_pool.particle_resources.particle_buffer.buffer,
    self.resource_pool.particle_resources.compact_particle_buffer.buffer,
    self.resource_pool.particle_resources.draw_command_buffer.buffer,
    vk.DeviceSize(
      self.resource_pool.particle_resources.particle_buffer.bytes_count,
    ),
  )
  return .SUCCESS
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

// Clear staged debug visualization data
clear_debug_visualization :: proc(self: ^Manager) {
  debug_bone.clear_bones(&self.debug_renderer)
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
  // Cleanup transparency renderers
  transparent.destroy(&self.transparent_renderer, gctx)
  sprite.destroy(&self.sprite_renderer, gctx)
  wireframe.destroy(&self.wireframe_renderer, gctx)
  line_strip.destroy(&self.line_strip_renderer, gctx)
  random_color.destroy(&self.random_color_renderer, gctx)
  ambient.shutdown(&self.ambient, gctx)
  direct_light.shutdown(&self.direct_light, gctx)
  shadow.shutdown(&self.shadow, gctx)
  geometry.shutdown(&self.geometry, gctx)
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
  resource_pool_destroy_persistent(&self.resource_pool, gctx.device)
  delete(self.bone_matrix_offsets)
  cont.slab_destroy(&self.bone_matrix_slab)
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  delete(self.cameras)
  delete(self.meshes)
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

allocate_mesh_geometry :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  geometry_data: geom.Geometry,
) -> (
  handle: u32,
  ret: vk.Result,
) {
  if len(render.meshes) >= rd.MAX_MESHES do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  found := false
  // TODO: eliminate this inefficiency
  for i in u32(0) ..< rd.MAX_MESHES {
    if _, ok := render.meshes[i]; !ok {
      handle = i
      found = true
      break
    }
  }
  if !found do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  mesh := Mesh{}
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.flags = {}
  mesh.index_count = u32(len(geometry_data.indices))
  vertex_allocation := gpu.allocate_vertices(
    &render.mesh_manager,
    gctx,
    geometry_data.vertices,
  ) or_return
  index_allocation := gpu.allocate_indices(
    &render.mesh_manager,
    gctx,
    geometry_data.indices,
  ) or_return
  mesh.first_index = index_allocation.offset
  mesh.vertex_offset = i32(vertex_allocation.offset)
  mesh.skinning_offset = 0
  if len(geometry_data.skinnings) > 0 {
    skinning_allocation := gpu.allocate_vertex_skinning(
      &render.mesh_manager,
      gctx,
      geometry_data.skinnings,
    ) or_return
    mesh.skinning_offset = skinning_allocation.offset
    mesh.flags |= {.SKINNED}
  }
  render.meshes[handle] = mesh
  upload_mesh_data(render, handle, &mesh)
  return handle, .SUCCESS
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: u32,
  geometry_data: geom.Geometry,
) -> vk.Result {
  ensure_mesh_slot(render, handle)
  mesh := render.meshes[handle]
  if mesh.index_count > 0 {
    gpu.free_vertices(
      &render.mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
    if .SKINNED in mesh.flags {
      gpu.free_vertex_skinning(
        &render.mesh_manager,
        BufferAllocation{offset = mesh.skinning_offset, count = 1},
      )
    }
  }
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.flags = {}
  mesh.index_count = u32(len(geometry_data.indices))
  vertex_allocation := gpu.allocate_vertices(
    &render.mesh_manager,
    gctx,
    geometry_data.vertices,
  ) or_return
  index_allocation := gpu.allocate_indices(
    &render.mesh_manager,
    gctx,
    geometry_data.indices,
  ) or_return
  mesh.first_index = index_allocation.offset
  mesh.vertex_offset = i32(vertex_allocation.offset)
  mesh.skinning_offset = 0
  if len(geometry_data.skinnings) > 0 {
    skinning_allocation := gpu.allocate_vertex_skinning(
      &render.mesh_manager,
      gctx,
      geometry_data.skinnings,
    ) or_return
    mesh.skinning_offset = skinning_allocation.offset
    mesh.flags |= {.SKINNED}
  }
  render.meshes[handle] = mesh
  upload_mesh_data(render, handle, &mesh)
  return .SUCCESS
}

free_mesh_geometry :: proc(render: ^Manager, handle: u32) {
  mesh, ok := render.meshes[handle]
  if !ok do return
  if mesh.index_count > 0 {
    gpu.free_vertices(
      &render.mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
  }
  if .SKINNED in mesh.flags {
    gpu.free_vertex_skinning(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.skinning_offset, count = 1},
    )
  }
  delete_key(&render.meshes, handle)
}

set_texture_2d_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  textures_descriptor_set: vk.DescriptorSet,
  texture_index: u32,
  image_view: vk.ImageView,
) {
  if texture_index >= gpu.MAX_TEXTURES {
    log.warnf("Index %d out of bounds for bindless textures", texture_index)
    return
  }
  if textures_descriptor_set == 0 {
    log.error("textures_descriptor_set is not initialized")
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    textures_descriptor_set,
    0,
    texture_index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}

set_texture_cube_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  textures_descriptor_set: vk.DescriptorSet,
  texture_index: u32,
  image_view: vk.ImageView,
) {
  if texture_index >= gpu.MAX_CUBE_TEXTURES {
    log.warnf(
      "Index %d out of bounds for bindless cube textures",
      texture_index,
    )
    return
  }
  if textures_descriptor_set == 0 {
    log.error("textures_descriptor_set is not initialized")
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    textures_descriptor_set,
    2,
    texture_index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}

upload_node_data :: proc(render: ^Manager, index: u32, node_data: ^Node) {
  gpu.write(
    &render.resource_pool.node_data_buffer.buffer,
    node_data,
    int(index),
  )
}

upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  frame_buffer := &render.resource_pool.bone_buffer.buffers[frame_index]
  if frame_buffer.mapped == nil do return
  l := int(offset)
  r := l + len(matrices)
  gpu_slice := gpu.get_all(frame_buffer)
  copy(gpu_slice[l:r], matrices[:])
}

upload_sprite_data :: proc(
  render: ^Manager,
  index: u32,
  sprite_data: ^Sprite,
) {
  gpu.write(
    &render.resource_pool.sprite_buffer.buffer,
    sprite_data,
    int(index),
  )
}

upload_emitter_data :: proc(render: ^Manager, index: u32, emitter: ^Emitter) {
  gpu.write(&render.resource_pool.emitter_buffer.buffer, emitter, int(index))
}

upload_forcefield_data :: proc(
  render: ^Manager,
  index: u32,
  forcefield: ^ForceField,
) {
  gpu.write(
    &render.resource_pool.forcefield_buffer.buffer,
    forcefield,
    int(index),
  )
}

upload_light_data :: proc(
  render: ^Manager,
  index: u32,
  light_data: ^rd.Light,
) {
  gpu.write(&render.resource_pool.lights_buffer.buffer, light_data, int(index))
  shadow.invalidate_light(&render.shadow, index)
}

upload_mesh_data :: proc(render: ^Manager, index: u32, mesh: ^Mesh) {
  gpu.write(&render.resource_pool.mesh_data_buffer.buffer, mesh, int(index))
}

upload_material_data :: proc(
  render: ^Manager,
  index: u32,
  material: ^Material,
) {
  gpu.write(&render.resource_pool.material_buffer.buffer, material, int(index))
}

ensure_bone_matrix_range_for_node :: proc(
  render: ^Manager,
  handle: u32,
  bone_count: u32,
) -> u32 {
  if existing, ok := render.bone_matrix_offsets[handle]; ok {
    return existing
  }
  offset := cont.slab_alloc(&render.bone_matrix_slab, bone_count)
  if offset == 0xFFFFFFFF do return 0xFFFFFFFF
  render.bone_matrix_offsets[handle] = offset
  return offset
}

release_bone_matrix_range_for_node :: proc(render: ^Manager, handle: u32) {
  if offset, ok := render.bone_matrix_offsets[handle]; ok {
    cont.slab_free(&render.bone_matrix_slab, offset)
    delete_key(&render.bone_matrix_offsets, handle)
  }
}

// Upload camera CPU data to GPU per-frame buffer
upload_camera_data :: proc(
  render: ^Manager,
  camera_index: u32,
  view, projection: matrix[4, 4]f32,
  position: [3]f32,
  extent: [2]u32,
  near, far: f32,
  frame_index: u32,
) {
  camera_data: rd.Camera
  camera_data.view = view
  camera_data.projection = projection
  camera_data.viewport_extent = {f32(extent[0]), f32(extent[1])}
  camera_data.near = near
  camera_data.far = far
  camera_data.position = [4]f32{position.x, position.y, position.z, 1.0}
  frustum := geom.make_frustum(camera_data.projection * camera_data.view)
  camera_data.frustum_planes = frustum.planes
  gpu.write(
    &render.resource_pool.camera_buffer.buffers[frame_index],
    &camera_data,
    int(camera_index),
  )
}

// ====== RENDER GRAPH RESOURCE REGISTRATION ======

MAX_CAMERAS_IN_GRAPH :: rd.MAX_ACTIVE_CAMERAS
MAX_GRAPH_CAMERA_TECHNIQUES :: 6

register_graph_buffer_resource :: proc(
  self: ^Manager,
  resource_ref: rg.ResourceRef,
  element_size: uint,
  element_count: uint,
  usage: vk.BufferUsageFlags,
) {
  rg.graph_register_resource(
    &self.graph,
    rg.ResourceDescriptor {
      ref = resource_ref,
      type = .BUFFER,
      format = rg.BufferFormat {
        element_size = element_size,
        element_count = element_count,
        usage = usage,
      },
      is_transient = false,
    },
  )
}

register_graph_texture_resource :: proc(
  self: ^Manager,
  resource_ref: rg.ResourceRef,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  width: u32 = 1920,
  height: u32 = 1080,
  mip_levels: u32 = 1,
) {
  rg.graph_register_resource(
    &self.graph,
    rg.ResourceDescriptor {
      ref = resource_ref,
      type = .TEXTURE_2D,
      format = rg.TextureFormat {
        width = width,
        height = height,
        format = format,
        usage = usage,
        mip_levels = mip_levels,
      },
      is_transient = false,
    },
  )
}

register_graph_depth_resource :: proc(
  self: ^Manager,
  resource_ref: rg.ResourceRef,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  width: u32 = 1920,
  height: u32 = 1080,
) {
  rg.graph_register_resource(
    &self.graph,
    rg.ResourceDescriptor {
      ref = resource_ref,
      type = .DEPTH_TEXTURE,
      format = rg.TextureFormat {
        width = width,
        height = height,
        format = format,
        usage = usage,
        mip_levels = 1,
      },
      is_transient = false,
    },
  )
}

// Register particle system resources in the render graph
register_particle_resources :: proc(self: ^Manager) {
  register_graph_buffer_resource(
    self,
    rg.ResourceRef{index = .PARTICLE_BUFFER, scope_index = 0},
    size_of(particles_compute.Particle),
    particles_compute.MAX_PARTICLES,
    {.VERTEX_BUFFER, .STORAGE_BUFFER, .TRANSFER_DST, .TRANSFER_SRC},
  )
  register_graph_buffer_resource(
    self,
    rg.ResourceRef {
      index = .COMPACT_PARTICLE_BUFFER,
      scope_index = 0,
    },
    size_of(particles_render.Particle),
    1024 * 1024,
    {.VERTEX_BUFFER, .STORAGE_BUFFER},
  )
  register_graph_buffer_resource(
    self,
    rg.ResourceRef {
      index = .DRAW_COMMAND_BUFFER,
      scope_index = 0,
    },
    size_of(vk.DrawIndirectCommand),
    1,
    {.INDIRECT_BUFFER, .STORAGE_BUFFER},
  )

  for cam_idx in 0 ..< MAX_CAMERAS_IN_GRAPH {
    register_graph_depth_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_DEPTH,
        scope_index = u32(cam_idx),
      },
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT},
    )

    register_graph_texture_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_DEPTH_PYRAMID,
        scope_index = u32(cam_idx),
      },
      .R32_SFLOAT,
      {.SAMPLED, .STORAGE},
      1920,
      1080,
      camera.MAX_DEPTH_MIPS_LEVEL,
    )

    register_graph_texture_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_FINAL_IMAGE,
        scope_index = u32(cam_idx),
      },
      .R16G16B16A16_SFLOAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
    )

    register_graph_texture_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_GBUFFER_POSITION,
        scope_index = u32(cam_idx),
      },
      .R32G32B32A32_SFLOAT,
      {.COLOR_ATTACHMENT, .SAMPLED},
    )

    register_graph_texture_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_GBUFFER_NORMAL,
        scope_index = u32(cam_idx),
      },
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    )
    register_graph_texture_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_GBUFFER_ALBEDO,
        scope_index = u32(cam_idx),
      },
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    )
    register_graph_texture_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_GBUFFER_METALLIC_ROUGHNESS,
        scope_index = u32(cam_idx),
      },
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    )
    register_graph_texture_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_GBUFFER_EMISSIVE,
        scope_index = u32(cam_idx),
      },
      .R8G8B8A8_UNORM,
      {.COLOR_ATTACHMENT, .SAMPLED},
    )

    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_OPAQUE_DRAW_COMMANDS,
        scope_index = u32(cam_idx),
      },
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_OPAQUE_DRAW_COUNT,
        scope_index = u32(cam_idx),
      },
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_TRANSPARENT_DRAW_COMMANDS,
        scope_index = u32(cam_idx),
      },
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_TRANSPARENT_DRAW_COUNT,
        scope_index = u32(cam_idx),
      },
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_WIREFRAME_DRAW_COMMANDS,
        scope_index = u32(cam_idx),
      },
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_WIREFRAME_DRAW_COUNT,
        scope_index = u32(cam_idx),
      },
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_RANDOM_COLOR_DRAW_COMMANDS,
        scope_index = u32(cam_idx),
      },
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_RANDOM_COLOR_DRAW_COUNT,
        scope_index = u32(cam_idx),
      },
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_LINE_STRIP_DRAW_COMMANDS,
        scope_index = u32(cam_idx),
      },
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_LINE_STRIP_DRAW_COUNT,
        scope_index = u32(cam_idx),
      },
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_SPRITE_DRAW_COMMANDS,
        scope_index = u32(cam_idx),
      },
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .CAMERA_SPRITE_DRAW_COUNT,
        scope_index = u32(cam_idx),
      },
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
  }

  log.infof(
    "Registered %d particle resources and %d camera resources in graph",
    3,
    MAX_CAMERAS_IN_GRAPH * (8 + MAX_GRAPH_CAMERA_TECHNIQUES * 2),
  )
}

// Register shadow system resources in the render graph
register_shadow_resources :: proc(self: ^Manager) {
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .SHADOW_DRAW_COMMANDS,
        scope_index = u32(slot),
      },
      size_of(vk.DrawIndexedIndirectCommand),
      rd.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_buffer_resource(
      self,
      rg.ResourceRef {
        index = .SHADOW_DRAW_COUNT,
        scope_index = u32(slot),
      },
      size_of(u32),
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    )
    register_graph_depth_resource(
      self,
      rg.ResourceRef {
        index = .SHADOW_MAP,
        scope_index = u32(slot),
      },
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      shadow.SHADOW_MAP_SIZE,
      shadow.SHADOW_MAP_SIZE,
    )
  }

  log.infof(
    "Registered %d shadow resources in graph (3 per slot)",
    shadow.MAX_SHADOW_MAPS * 3,
  )
}

// Register UI system resources in the render graph
register_ui_resources :: proc(self: ^Manager) {
  register_graph_buffer_resource(
    self,
    rg.ResourceRef {
      index = .UI_VERTEX_BUFFER,
      scope_index = 0,
    },
    size_of(ui_render.Vertex2D),
    ui_render.UI_MAX_VERTICES,
    {.VERTEX_BUFFER},
  )
  register_graph_buffer_resource(
    self,
    rg.ResourceRef {
      index = .UI_INDEX_BUFFER,
      scope_index = 0,
    },
    size_of(u32),
    ui_render.UI_MAX_INDICES,
    {.INDEX_BUFFER},
  )

  // Note: Swapchain image is NOT registered in graph because it's owned by Engine,
  // not Manager. It's passed through runtime fields on ui.Renderer.

  log.info("Registered UI resources in graph (vertex buffer, index buffer)")
}

// Register post-process system resources in the render graph
register_post_process_resources :: proc(self: ^Manager) {
  register_graph_texture_resource(
    self,
    rg.ResourceRef {
      index = .POST_PROCESS_IMAGE_0,
      scope_index = 0,
    },
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
  )
  register_graph_texture_resource(
    self,
    rg.ResourceRef {
      index = .POST_PROCESS_IMAGE_1,
      scope_index = 1,
    },
    .R8G8B8A8_UNORM,
    {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
  )

  log.info("Registered post-process resources in graph (2 ping-pong images)")
}

Blackboard :: struct {
  depth:       rg.DepthTexture,
  final_image: rg.Texture,
}

debug_pass_deps_from_context :: proc(pass_ctx: ^rg.PassContext) -> Blackboard {
  return Blackboard {
    depth = rg.get_depth(pass_ctx, .CAMERA_DEPTH),
    final_image = rg.get_texture(pass_ctx, .CAMERA_FINAL_IMAGE),
  }
}

debug_pass_execute :: proc(
  manager: ^Manager,
  pass_ctx: ^rg.PassContext,
  deps: Blackboard,
) {
  if len(manager.debug_renderer.bone_instances) == 0 do return

  cam_index := pass_ctx.scope_index

  if !debug_bone.begin_pass(
    &manager.debug_renderer,
    pass_ctx.cmd,
    deps.final_image,
    deps.depth,
  ) {
    return
  }

  if err := debug_bone.render(
    &manager.debug_renderer,
    pass_ctx.cmd,
    manager.resource_pool.camera_buffer.descriptor_sets[pass_ctx.frame_index],
    cam_index,
  ); err != .SUCCESS {
    log.errorf(
      "Debug graph pass render failed for camera %d: %v",
      cam_index,
      err,
    )
  }
  debug_bone.end_pass(&manager.debug_renderer, pass_ctx.cmd)
}

render_frame_graph :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  active_cameras: []u32,
  active_lights: []rd.LightHandle,
  main_camera_index: u32,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
) -> vk.Result {
  defer rg.graph_reset(&self.graph)

  shadow.sync_lights(
    &self.shadow,
    &self.resource_pool.lights_buffer,
    active_lights,
    frame_index,
  )
  active_light_slots := collect_active_light_slots(self)
  shadow_texture_indices := build_shadow_texture_indices(
    self,
    active_lights,
    frame_index,
  )

  // GLOBAL passes (post-processing and UI) require a main camera.
  _, has_main_camera := self.cameras[main_camera_index]
  if !has_main_camera {
    log.errorf(
      "Failed to find main camera %d for post-process",
      main_camera_index,
    )
    return .ERROR_UNKNOWN
  }

  build_input := build_frame_graph_template_input(
    self,
    active_cameras,
    active_light_slots,
    main_camera_index,
  )

  payload := FrameGraphExecutionPayload {
    main_camera_index      = main_camera_index,
    active_lights          = active_lights,
    shadow_texture_indices = shadow_texture_indices,
    swapchain_view         = swapchain_view,
    swapchain_extent       = swapchain_extent,
    ui_commands            = self.ui_commands[:],
  }

  // ====== BUILD PASS TEMPLATE ARRAY (P0.1 - static registry + compile parameters) ======
  templates := build_frame_graph_templates(&build_input)

  // ====== COMPILE AND EXECUTE GRAPH ======
  exec_ctx := rg.GraphExecutionContext {
    render_manager         = self,
    frame_payload          = &payload,
    resolve_resource_index = resolve_resource_index_from_manager,
  }
  cmd := self.command_buffers[frame_index]

  // Compile: templates passed as parameter, not stored in Graph
  if err := rg.graph_compile(&self.graph, templates, &exec_ctx);
     err != .SUCCESS {
    log.errorf("Failed to build graph: %v", err)
    return .ERROR_UNKNOWN
  }
  if err := rg.graph_execute(&self.graph, cmd, frame_index); err != .SUCCESS {
    log.errorf("Failed to execute graph: %v", err)
    return .ERROR_UNKNOWN
  }
  return .SUCCESS
}
