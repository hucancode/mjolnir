package render

import cont "../containers"
import "core:fmt"
import geom "../geometry"
import "../gpu"
import cmd "../gpu/ui"
import rg "graph"
import "ambient"
import alg "../algebra"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import rd "data"
import "debug_bone"
import "debug_ui"
import depth_pyramid_system "depth_pyramid"
import "direct_light"
import "geometry"
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
import "shared"
import "sprite"
import "transparent"
import ui_render "ui"
import vk "vendor:vulkan"
import "wireframe"
import dp "depth_pyramid"

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

// ── Private helpers ──────────────────────────────────────────────────────────
// Reduce transmute boilerplate when extracting bindless handles from graph resources.

@(private)
tex2d :: #force_inline proc(t: rg.ResolvedTexture) -> gpu.Texture2DHandle {
	return transmute(gpu.Texture2DHandle)t.handle_bits
}

@(private)
texcube :: #force_inline proc(t: rg.ResolvedTexture) -> gpu.TextureCubeHandle {
	return transmute(gpu.TextureCubeHandle)t.handle_bits
}

ShadowMap :: struct {
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  view:            matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  view_projection: matrix[4, 4]f32, // Pre-multiplied
  near:            f32,
  far:             f32,
  frustum_planes:  [6][4]f32,
}

ShadowMapCube :: struct {
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  projection:      matrix[4, 4]f32,
  near:            f32,
  far:             f32,
}

// Light union variants
PointLight :: struct {
  color:    [4]f32, // RGB + intensity
  position: [3]f32,
  radius:   f32,
  shadow:   Maybe(ShadowMapCube),
}

SpotLight :: struct {
  color:       [4]f32,
  position:    [3]f32,
  direction:   [3]f32,
  radius:      f32,
  angle_inner: f32,
  angle_outer: f32,
  shadow:      Maybe(ShadowMap),
}

DirectionalLight :: struct {
  color:     [4]f32,
  position:  [3]f32,
  direction: [3]f32,
  radius:    f32,
  shadow:    Maybe(ShadowMap),
}

Light :: union {
  PointLight,
  SpotLight,
  DirectionalLight,
}

PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  POST_PROCESS = 5,
}

PassTypeSet :: bit_set[PassType;u32]

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
  opaque_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  opaque_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  transparent_draw_count:       [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  transparent_draw_commands:    [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  wireframe_draw_count:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  wireframe_draw_commands:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  random_color_draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  random_color_draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  line_strip_draw_count:        [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  line_strip_draw_commands:     [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  sprite_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  sprite_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  // Depth pyramid for hierarchical Z culling
  depth_pyramid:                [FRAMES_IN_FLIGHT]dp.DepthPyramid,
  // Descriptor sets for visibility culling compute shaders
  descriptor_set:               [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][dp.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

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
  command_buffers:              [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers:      [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  // Frame graph
  frame_graph:                  rg.Graph,
  force_graph_rebuild:          bool,
  show_debug_ui:                bool,
  // Swapchain context for frame graph (set per-frame)
  current_swapchain_image:      vk.Image,
  current_swapchain_view:       vk.ImageView,
  current_swapchain_extent:     vk.Extent2D,
  // Execute contexts for passes dispatched directly to sub-modules
  particles_compute_ctx:        particles_compute.ExecuteContext,
  ui_ctx:                       ui_render.ExecuteContext,
  debug_ui_ctx:                 debug_ui.ExecuteContext,
  geometry:                     geometry.Renderer,
  ambient:                      ambient.Renderer,
  direct_light:                 direct_light.Renderer,
  transparent_renderer:         transparent.Renderer,
  sprite_renderer:              sprite.Renderer,
  wireframe_renderer:           wireframe.Renderer,
  line_strip_renderer:          line_strip.Renderer,
  random_color_renderer:        random_color.Renderer,
  particles_compute:            particles_compute.Renderer,
  particles_render:             particles_render.Renderer,
  post_process:                 post_process.Renderer,
  debug_ui:                     debug_ui.Renderer,
  debug_renderer:               debug_bone.Renderer,
  ui:                           ui_render.Renderer,
  ui_commands:                  [dynamic]cmd.RenderCommand, // Staged commands from UI module
  per_camera_data:              map[u32]Camera,
  per_light_data:               map[u32]Light,
  visibility:                   occlusion_culling.System,
  depth_pyramid:                depth_pyramid_system.System,
  shadow_culling:               shadow_culling_system.System,
  shadow_sphere_culling:        shadow_sphere_culling_system.System,
  shadow_render:                shadow_render_system.System,
  shadow_sphere_render:         shadow_sphere_render_system.System,
  linear_repeat_sampler:        vk.Sampler,
  linear_clamp_sampler:         vk.Sampler,
  nearest_repeat_sampler:       vk.Sampler,
  nearest_clamp_sampler:        vk.Sampler,
  particle_buffer:              gpu.MutableBuffer(rd.Particle),
  compact_particle_buffer:      gpu.MutableBuffer(rd.Particle),
  particle_draw_command_buffer: gpu.MutableBuffer(vk.DrawIndirectCommand),
  bone_buffer:                  gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:                gpu.PerFrameBindlessBuffer(
    rd.Camera,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:              gpu.BindlessBuffer(Material),
  node_data_buffer:             gpu.BindlessBuffer(Node),
  mesh_data_buffer:             gpu.BindlessBuffer(Mesh),
  emitter_buffer:               gpu.BindlessBuffer(Emitter),
  forcefield_buffer:            gpu.BindlessBuffer(ForceField),
  sprite_buffer:                gpu.BindlessBuffer(Sprite),
  mesh_manager:                 gpu.MeshManager,
  bone_matrix_slab:             cont.SlabAllocator,
  bone_matrix_offsets:          map[u32]u32,
  texture_manager:              gpu.TextureManager,
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
  gpu.per_frame_bindless_buffer_init(
    &self.bone_buffer,
    gctx,
    int(self.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  self.bone_matrix_offsets = make(map[u32]u32)
  defer if ret != .SUCCESS {
    delete(self.bone_matrix_offsets)
    gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
    cont.slab_destroy(&self.bone_matrix_slab)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.camera_buffer,
    gctx,
    rd.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.material_buffer,
    gctx,
    rd.MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.node_data_buffer,
    gctx,
    rd.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.mesh_data_buffer,
    gctx,
    rd.MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.emitter_buffer,
    gctx,
    rd.MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.forcefield_buffer,
    gctx,
    rd.MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.sprite_buffer,
    gctx,
    rd.MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
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
  depth_pyramid_system.init(&self.depth_pyramid, gctx) or_return
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
  // Initialize transparency renderers
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
  // Re-allocate descriptor sets for scene buffers (freed by previous ResetDescriptorPool)
  gpu.bindless_buffer_realloc_descriptor(&self.material_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.node_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.mesh_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.emitter_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &self.forcefield_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.sprite_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &self.bone_buffer,
    gctx,
  ) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &self.camera_buffer,
    gctx,
  ) or_return
  gpu.mesh_manager_realloc_descriptors(&self.mesh_manager, gctx) or_return
  // Setup subsystem GPU resources
  ambient.setup(&self.ambient, gctx, &self.texture_manager) or_return
  direct_light.setup(&self.direct_light, gctx) or_return
  // Allocate particle buffers
  self.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_buffer)
  }
  self.compact_particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.compact_particle_buffer)
  }
  self.particle_draw_command_buffer = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndirectCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_draw_command_buffer)
  }
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
    remove_light_entry(self, gctx, light_node_index)
  }
  clear(&self.per_light_data)
  ui_render.teardown(&self.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles_compute.teardown(&self.particles_compute, gctx)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.compact_particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_draw_command_buffer)
  ambient.teardown(&self.ambient, gctx, &self.texture_manager)
  direct_light.teardown(&self.direct_light, gctx)
  // Destroy graph-owned GPU resources before texture_manager goes away
  rg.destroy(&self.frame_graph, gctx, &self.texture_manager)
  gpu.texture_manager_teardown(&self.texture_manager, gctx)
  // Zero all descriptor set handles (freed in bulk below)
  self.material_buffer.descriptor_set = 0
  self.node_data_buffer.descriptor_set = 0
  self.mesh_data_buffer.descriptor_set = 0
  self.emitter_buffer.descriptor_set = 0
  self.forcefield_buffer.descriptor_set = 0
  self.sprite_buffer.descriptor_set = 0
  for &ds in self.bone_buffer.descriptor_sets do ds = 0
  for &ds in self.camera_buffer.descriptor_sets do ds = 0
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
  // Bulk-free all descriptor sets allocated from the pool
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
}

clear_mesh :: proc(self: ^Manager, handle: u32) {
  free_mesh_geometry(self, handle)
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
  depth_pyramid_system.shutdown(&self.depth_pyramid, gctx)
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
  gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  delete(self.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
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
prepare_lights_for_frame :: proc(self: ^Manager) {
  light_node_indices := make(
    [dynamic]u32,
    0,
    len(self.per_light_data),
    context.temp_allocator,
  )
  defer delete(light_node_indices)
  for light_node_index in self.per_light_data {
    append(&light_node_indices, light_node_index)
  }
  slice.sort(light_node_indices[:])
  for light_node_index, i in light_node_indices {
    if i >= int(rd.MAX_LIGHTS) do break
    light := &self.per_light_data[light_node_index]
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
release_shadow_2d :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  shadow: ^ShadowMap,
) {
  // Shadow map texture is now owned by the frame graph; only free draw buffers
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
}

@(private)
release_shadow_cube :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  shadow: ^ShadowMapCube,
) {
  // Shadow map texture is now owned by the frame graph; only free draw buffers
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &shadow.draw_commands[frame])
    shadow.descriptor_sets[frame] = 0
  }
}

@(private)
ensure_shadow_2d_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
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
      &render.shadow_culling.descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&render.node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&render.mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_commands[frame])},
    ) or_return
  }
  shadow^ = sm
  return .SUCCESS
}

@(private)
ensure_shadow_cube_resource :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
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
      &render.shadow_sphere_culling.descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&render.node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&render.mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&sm.draw_commands[frame])},
    ) or_return
  }
  shadow^ = sm
  return .SUCCESS
}

upsert_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
  light_data: ^Light,
  cast_shadow: bool,
) -> vk.Result {
  is_existing := light_node_index in render.per_light_data

  if is_existing {
    // UPDATE PATH: Preserve shadow resources when updating light properties
    light := &render.per_light_data[light_node_index]
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
    render.per_light_data[light_node_index] = light_data^
  }

  // Manage shadow resources (common for both insert and update)
  light := &render.per_light_data[light_node_index]
  if cast_shadow {
    shadow_result: vk.Result
    switch &variant in light {
    case PointLight:
      shadow_result = ensure_shadow_cube_resource(
        render,
        gctx,
        &variant.shadow,
      )
    case SpotLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, &variant.shadow)
    case DirectionalLight:
      shadow_result = ensure_shadow_2d_resource(render, gctx, &variant.shadow)
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
        release_shadow_cube(render, gctx, &sm)
        variant.shadow = nil
      }
    case SpotLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_2d(render, gctx, &sm)
        variant.shadow = nil
      }
    case DirectionalLight:
      if variant.shadow != nil {
        sm := variant.shadow.?
        release_shadow_2d(render, gctx, &sm)
        variant.shadow = nil
      }
    }
  }

  return .SUCCESS
}

remove_light_entry :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  light_node_index: u32,
) {
  light, ok := render.per_light_data[light_node_index]
  if !ok do return

  // Release shadow resources if they exist
  switch &variant in light {
  case PointLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_cube(render, gctx, &sm)
    }
  case SpotLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_2d(render, gctx, &sm)
    }
  case DirectionalLight:
    if variant.shadow != nil {
      sm := variant.shadow.?
      release_shadow_2d(render, gctx, &sm)
    }
  }

  delete_key(&render.per_light_data, light_node_index)
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: u32,
  geometry_data: geom.Geometry,
) -> vk.Result {
  mesh := gpu.mutable_buffer_get(&render.mesh_data_buffer.buffer, handle)
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
  return .SUCCESS
}

free_mesh_geometry :: proc(render: ^Manager, handle: u32) {
  mesh := gpu.mutable_buffer_get(&render.mesh_data_buffer.buffer, handle)
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
  mesh^ = {}
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
  gpu.write(&render.node_data_buffer.buffer, node_data, int(index))
}

upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  frame_buffer := &render.bone_buffer.buffers[frame_index]
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
  gpu.write(&render.sprite_buffer.buffer, sprite_data, int(index))
}

upload_emitter_data :: proc(render: ^Manager, index: u32, emitter: ^Emitter) {
  gpu.write(&render.emitter_buffer.buffer, emitter, int(index))
}

upload_forcefield_data :: proc(
  render: ^Manager,
  index: u32,
  forcefield: ^ForceField,
) {
  gpu.write(&render.forcefield_buffer.buffer, forcefield, int(index))
}

upload_mesh_data :: proc(render: ^Manager, index: u32, mesh: ^Mesh) {
  gpu.write(&render.mesh_data_buffer.buffer, mesh, int(index))
}

upload_material_data :: proc(
  render: ^Manager,
  index: u32,
  material: ^Material,
) {
  gpu.write(&render.material_buffer.buffer, material, int(index))
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
    &render.camera_buffer.buffers[frame_index],
    &camera_data,
    int(camera_index),
  )
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

	log.infof("Frame graph topology: %d cameras, %d lights", len(camera_handles), len(light_handles))

	// Validate we have at least one camera
	if len(camera_handles) == 0 {
		log.warn("No cameras registered - frame graph requires at least one camera")
		return .ERROR_UNKNOWN
	}

	// Build topology hint arrays (temp memory, valid for duration of compile)
	camera_extents := make([]vk.Extent2D, len(camera_handles), context.temp_allocator)
	for h, i in camera_handles {
		if cam, ok := self.per_camera_data[h]; ok {
			camera_extents[i] = cam.render_extent
		} else {
			camera_extents[i] = vk.Extent2D{1920, 1080}
		}
	}
	light_is_point := make([]bool, len(light_handles), context.temp_allocator)
	for h, i in light_handles {
		if ld, ok := self.per_light_data[h]; ok {
			_, light_is_point[i] = ld.(PointLight)
		}
	}

	// Initialize execute contexts for sub-module dispatched passes
	self.particles_compute_ctx = particles_compute.ExecuteContext{
		renderer      = &self.particles_compute,
		node_data_ds  = self.node_data_buffer.descriptor_set,
		particle_buf  = self.particle_buffer.buffer,
		compact_buf   = self.compact_particle_buffer.buffer,
		draw_cmd_buf  = self.particle_draw_command_buffer.buffer,
		particle_bytes = vk.DeviceSize(self.particle_buffer.bytes_count),
	}
	self.ui_ctx = ui_render.ExecuteContext{
		renderer        = &self.ui,
		texture_manager = &self.texture_manager,
		commands        = &self.ui_commands,
		swapchain_view  = &self.current_swapchain_view,
		swapchain_extent = &self.current_swapchain_extent,
		texture_ds      = self.texture_manager.descriptor_set,
	}
	self.debug_ui_ctx = debug_ui.ExecuteContext{
		renderer        = &self.debug_ui,
		swapchain_view  = &self.current_swapchain_view,
		swapchain_extent = &self.current_swapchain_extent,
		texture_ds      = &self.texture_manager.descriptor_set,
		enabled         = &self.show_debug_ui,
	}

	// Create compile context
	ctx := rg.CompileContext{
		num_cameras     = len(camera_handles),
		num_lights      = len(light_handles),
		frames_in_flight = FRAMES_IN_FLIGHT,
		gctx            = gctx,
		camera_handles  = camera_handles[:],
		light_handles   = light_handles[:],
		camera_extents  = camera_extents,
		light_is_point  = light_is_point,
	}

	// Build pass declarations
	pass_decls := build_pass_declarations(self)
	defer delete(pass_decls)

	tm_ptr := rawptr(&self.texture_manager)

	if err := rg.build_graph(&self.frame_graph, pass_decls[:], ctx, tm_ptr); err != .NONE {
		log.errorf("Failed to build frame graph: %v", err)
		return .ERROR_UNKNOWN
	}

	log.infof("Frame graph compiled: %d passes, %d cameras, %d lights",
		len(self.frame_graph.sorted_passes), len(camera_handles), len(light_handles))

	return .SUCCESS
}

// get_camera_handle_by_index returns the actual camera handle for the N-th camera
// (sorted by handle value, matching compile_frame_graph ordering).
get_camera_handle_by_index :: proc(self: ^Manager, instance_idx: u32) -> u32 {
	handles := make([dynamic]u32, 0, len(self.per_camera_data), context.temp_allocator)
	for h in self.per_camera_data {
		append(&handles, h)
	}
	slice.sort(handles[:])
	if int(instance_idx) < len(handles) {
		return handles[instance_idx]
	}
	return 0
}

// get_light_handle_by_index returns the actual light handle for the N-th light
// (sorted by handle value, matching compile_frame_graph ordering).
get_light_handle_by_index :: proc(self: ^Manager, instance_idx: u32) -> u32 {
	handles := make([dynamic]u32, 0, len(self.per_light_data), context.temp_allocator)
	for h in self.per_light_data {
		append(&handles, h)
	}
	slice.sort(handles[:])
	if int(instance_idx) < len(handles) {
		return handles[instance_idx]
	}
	return 0
}

// get_camera_final_image returns the bindless texture handle of the final rendered
// image for the given camera (as allocated by the frame graph).
get_camera_final_image :: proc(
	manager: ^Manager,
	camera_handle_index: u32,
	frame_index: u32,
) -> (gpu.Texture2DHandle, bool) {
	// Find the graph instance_idx for this camera handle
	instance_idx: u32 = 0xFFFF_FFFF
	for handle, idx in manager.frame_graph.camera_handles {
		if handle == camera_handle_index {
			instance_idx = u32(idx)
			break
		}
	}
	if instance_idx == 0xFFFF_FFFF do return {}, false

	resource_name := fmt.tprintf("final_image_cam_%d", instance_idx)
	resource_id, found := manager.frame_graph.resource_by_name[resource_name]
	if !found do return {}, false

	res := &manager.frame_graph.resource_instances[resource_id]
	if len(res.texture_handle_bits) == 0 do return {}, false

	// Use modulo so single-variant (CURRENT-only) resources always return index 0
	// even when frame_index > 0 (e.g. frames_in_flight > 1).
	variant_idx := int(frame_index) % len(res.texture_handle_bits)
	return transmute(gpu.Texture2DHandle)res.texture_handle_bits[variant_idx], true
}
// Build array of pass declarations for frame graph compilation.
// Three passes (particles_compute, ui, debug_ui) dispatch directly to their
// sub-module execute procs via pre-built context structs in Manager, avoiding
// full Manager access in the hot execute path.
build_pass_declarations :: proc(manager: ^Manager) -> [dynamic]rg.PassDecl {
	decls := make([dynamic]rg.PassDecl, 0, 13)

	// Compute passes
	append(&decls, rg.PassDecl{name = "particles_compute", scope = .GLOBAL,     queue = .COMPUTE,  setup = particles_compute_setup, execute = particles_compute.execute, user_data = &manager.particles_compute_ctx})
	append(&decls, rg.PassDecl{name = "depth_pyramid",     scope = .PER_CAMERA, queue = .COMPUTE,  setup = depth_pyramid_setup,     execute = depth_pyramid_execute,     user_data = manager})
	append(&decls, rg.PassDecl{name = "occlusion_culling", scope = .PER_CAMERA, queue = .COMPUTE,  setup = occlusion_culling_setup, execute = occlusion_culling_execute, user_data = manager})
	append(&decls, rg.PassDecl{name = "shadow_culling",    scope = .PER_LIGHT,  queue = .COMPUTE,  setup = shadow_culling_setup,    execute = shadow_culling_execute,    user_data = manager})

	// Graphics passes
	append(&decls, rg.PassDecl{name = "shadow_render",     scope = .PER_LIGHT,  queue = .GRAPHICS, setup = shadow_render_setup,     execute = shadow_render_execute,     user_data = manager})
	append(&decls, rg.PassDecl{name = "geometry",          scope = .PER_CAMERA, queue = .GRAPHICS, setup = geometry_setup,          execute = geometry_execute,          user_data = manager})
	append(&decls, rg.PassDecl{name = "ambient",           scope = .PER_CAMERA, queue = .GRAPHICS, setup = ambient_setup,           execute = ambient_execute,           user_data = manager})
	append(&decls, rg.PassDecl{name = "direct_light",      scope = .PER_CAMERA, queue = .GRAPHICS, setup = direct_light_setup,      execute = direct_light_execute,      user_data = manager})
	append(&decls, rg.PassDecl{name = "particles_render",  scope = .PER_CAMERA, queue = .GRAPHICS, setup = particles_render_setup,  execute = particles_render_execute,  user_data = manager})
	append(&decls, rg.PassDecl{name = "transparent",       scope = .PER_CAMERA, queue = .GRAPHICS, setup = transparent_setup,       execute = transparent_execute,       user_data = manager})
	append(&decls, rg.PassDecl{name = "post_process",      scope = .GLOBAL,     queue = .GRAPHICS, setup = post_process_setup,      execute = post_process_execute,      user_data = manager})
	append(&decls, rg.PassDecl{name = "ui",                scope = .GLOBAL,     queue = .GRAPHICS, setup = ui_setup,                execute = ui_render.execute,         user_data = &manager.ui_ctx})
	append(&decls, rg.PassDecl{name = "debug_ui",          scope = .GLOBAL,     queue = .GRAPHICS, setup = debug_ui_setup,          execute = debug_ui.execute,          user_data = &manager.debug_ui_ctx})

	return decls
}
// ============================================================================
// Frame Graph Pass Implementations
// All setup/execute callbacks for the 13 frame graph passes
// ============================================================================

// ============================================================================
// GEOMETRY PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

geometry_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	extent: vk.Extent2D = {1920, 1080}
	if int(setup.instance_idx) < len(setup.camera_extents) {
		extent = setup.camera_extents[setup.instance_idx]
	}
	geometry.declare_resources(setup, extent)
}

geometry_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	// Get graph-owned G-buffer handles (simple names — graph auto-scopes to this camera)
	pos_tex, _  := rg.get_texture(resources, "gbuffer_position")
	nrm_tex, _  := rg.get_texture(resources, "gbuffer_normal")
	alb_tex, _  := rg.get_texture(resources, "gbuffer_albedo")
	mr_tex, _   := rg.get_texture(resources, "gbuffer_metallic_roughness")
	emi_tex, _  := rg.get_texture(resources, "gbuffer_emissive")
	fin_tex, _  := rg.get_texture(resources, "final_image")
	position_h           := tex2d(pos_tex)
	normal_h             := tex2d(nrm_tex)
	albedo_h             := tex2d(alb_tex)
	metallic_roughness_h := tex2d(mr_tex)
	emissive_h           := tex2d(emi_tex)
	final_image_h        := tex2d(fin_tex)
	depth_h              := cam.depth[frame_index]

	geometry.begin_pass(
		position_h,
		normal_h,
		albedo_h,
		metallic_roughness_h,
		emissive_h,
		depth_h,
		&manager.texture_manager,
		cmd,
	)
	geometry.render(
		&manager.geometry,
		cam_handle,
		cmd,
		manager.camera_buffer.descriptor_sets[frame_index],
		manager.texture_manager.descriptor_set,
		manager.bone_buffer.descriptor_sets[frame_index],
		manager.material_buffer.descriptor_set,
		manager.node_data_buffer.descriptor_set,
		manager.mesh_data_buffer.descriptor_set,
		manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
		manager.mesh_manager.vertex_buffer.buffer,
		manager.mesh_manager.index_buffer.buffer,
		cam.opaque_draw_commands[frame_index].buffer,
		cam.opaque_draw_count[frame_index].buffer,
	)
	geometry.end_pass(cmd)
}

// ============================================================================
// AMBIENT PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

ambient_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	ambient.declare_resources(setup)
}

ambient_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	if _, exists := manager.per_camera_data[cam_handle]; !exists do return

	pos_tex, _ := rg.get_texture(resources, "gbuffer_position")
	nrm_tex, _ := rg.get_texture(resources, "gbuffer_normal")
	alb_tex, _ := rg.get_texture(resources, "gbuffer_albedo")
	mr_tex, _  := rg.get_texture(resources, "gbuffer_metallic_roughness")
	emi_tex, _ := rg.get_texture(resources, "gbuffer_emissive")
	fin_tex, _ := rg.get_texture(resources, "final_image")

	ambient.begin_pass(
		&manager.ambient,
		tex2d(fin_tex),
		&manager.texture_manager,
		cmd,
		manager.camera_buffer.descriptor_sets[frame_index],
	)
	ambient.render(
		&manager.ambient,
		cam_handle,
		tex2d(pos_tex).index,
		tex2d(nrm_tex).index,
		tex2d(alb_tex).index,
		tex2d(mr_tex).index,
		tex2d(emi_tex).index,
		cmd,
	)
	ambient.end_pass(cmd)
}

// ============================================================================
// DIRECT_LIGHT PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

direct_light_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	direct_light.declare_resources(setup, u32(setup.num_lights))
}

direct_light_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	// Get G-buffer bindless indices from graph resources (simple names — auto-scoped to this camera)
	pos_tex, _ := rg.get_texture(resources, "gbuffer_position")
	nrm_tex, _ := rg.get_texture(resources, "gbuffer_normal")
	alb_tex, _ := rg.get_texture(resources, "gbuffer_albedo")
	mr_tex, _  := rg.get_texture(resources, "gbuffer_metallic_roughness")
	fin_tex, _ := rg.get_texture(resources, "final_image")
	pos_idx       := tex2d(pos_tex).index
	nrm_idx       := tex2d(nrm_tex).index
	alb_idx       := tex2d(alb_tex).index
	mr_idx        := tex2d(mr_tex).index
	final_image_h := tex2d(fin_tex)
	depth_h       := cam.depth[frame_index]

	direct_light.begin_pass(
		&manager.direct_light,
		final_image_h,
		depth_h,
		&manager.texture_manager,
		cmd,
		manager.camera_buffer.descriptor_sets[frame_index],
	)

	// Render all lights in sorted order; iteration order = graph light instance_idx
	light_node_indices := make([dynamic]u32, 0, len(manager.per_light_data), context.temp_allocator)
	for light_node_index in manager.per_light_data {
		append(&light_node_indices, light_node_index)
	}
	slice.sort(light_node_indices[:])

	for light_node_index, light_inst in light_node_indices {
		if light_inst >= int(rd.MAX_LIGHTS) do break
		light_data := &manager.per_light_data[light_node_index]

		switch &variant in light_data {
		case PointLight:
			shadow_map_idx: u32 = 0xFFFFFFFF
			shadow_vp := matrix[4, 4]f32{}
			if sm, ok := variant.shadow.?; ok {
				shadow_vp = sm.projection
				if tex, texok := rg.get_texture(resources, fmt.tprintf("shadow_map_cube_light_%d", light_inst)); texok {
					shadow_map_idx = texcube(tex).index
				}
			}
			direct_light.render_point_light(
				&manager.direct_light,
				cam_handle, pos_idx, nrm_idx, alb_idx, mr_idx,
				variant.color, variant.position, variant.radius,
				shadow_map_idx, shadow_vp, cmd,
			)
		case SpotLight:
			shadow_map_idx, shadow_vp := resolve_shadow_2d(variant.shadow, resources, light_inst)
			direct_light.render_spot_light(
				&manager.direct_light,
				cam_handle, pos_idx, nrm_idx, alb_idx, mr_idx,
				variant.color, variant.position, variant.direction,
				variant.radius, variant.angle_inner, variant.angle_outer,
				shadow_map_idx, shadow_vp, cmd,
			)
		case DirectionalLight:
			shadow_map_idx, shadow_vp := resolve_shadow_2d(variant.shadow, resources, light_inst)
			direct_light.render_directional_light(
				&manager.direct_light,
				cam_handle, pos_idx, nrm_idx, alb_idx, mr_idx,
				variant.color, variant.direction,
				shadow_map_idx, shadow_vp, cmd,
			)
		}
	}

	direct_light.end_pass(cmd)
}

// ============================================================================
// PARTICLES COMPUTE PASS (GLOBAL, COMPUTE)
// ============================================================================

particles_compute_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	particles_compute.declare_resources(setup)
}
// execute → particles_compute.execute (dispatched via ExecuteContext in Manager)

// ============================================================================
// DEPTH PYRAMID PASS (PER_CAMERA, COMPUTE)
// ============================================================================

depth_pyramid_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	depth_pyramid_system.declare_resources(setup)
}

depth_pyramid_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists || !cam.enable_culling do return

	depth_pyramid_system.build_pyramid(
		&manager.depth_pyramid,
		cmd,
		&cam.depth_pyramid[frame_index],
		cam.depth_reduce_descriptor_sets[frame_index][:],
	)
}

// ============================================================================
// OCCLUSION CULLING PASS (PER_CAMERA, COMPUTE)
// ============================================================================

occlusion_culling_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	occlusion_culling.declare_resources(setup)
}

occlusion_culling_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists || !cam.enable_culling do return

	next_frame_index := alg.next(frame_index, FRAMES_IN_FLIGHT)
	prev_frame := alg.prev(next_frame_index, FRAMES_IN_FLIGHT)

	occlusion_culling.perform_culling(
		&manager.visibility,
		cmd,
		cam_handle,
		next_frame_index,
		&cam.opaque_draw_count[next_frame_index],
		&cam.transparent_draw_count[next_frame_index],
		&cam.sprite_draw_count[next_frame_index],
		&cam.wireframe_draw_count[next_frame_index],
		&cam.random_color_draw_count[next_frame_index],
		&cam.line_strip_draw_count[next_frame_index],
		cam.descriptor_set[next_frame_index],
		cam.depth_pyramid[prev_frame].width,
		cam.depth_pyramid[prev_frame].height,
	)
}

// ============================================================================
// SHADOW CULLING PASS (PER_LIGHT, COMPUTE)
// ============================================================================

shadow_culling_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	shadow_culling_system.declare_resources(setup)
}

shadow_culling_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	light_index := resources.light_handle
	light_data, exists := &manager.per_light_data[light_index]
	if !exists do return

	// Execute appropriate culling based on light type
	shadow_2d: Maybe(ShadowMap)
	switch &variant in light_data {
	case PointLight:
		shadow, ok := variant.shadow.?
		if !ok do return
		shadow_sphere_culling_system.execute(
			&manager.shadow_sphere_culling,
			cmd,
			variant.position,
			variant.radius,
			shadow.draw_count[frame_index].buffer,
			shadow.descriptor_sets[frame_index],
		)
		return
	case SpotLight:       shadow_2d = variant.shadow
	case DirectionalLight: shadow_2d = variant.shadow
	}
	shadow, ok := shadow_2d.?
	if !ok do return
	shadow_culling_system.execute(
		&manager.shadow_culling,
		cmd,
		shadow.frustum_planes,
		shadow.draw_count[frame_index].buffer,
		shadow.descriptor_sets[frame_index],
	)
}

// ============================================================================
// SHADOW RENDER PASS (PER_LIGHT, GRAPHICS)
// ============================================================================

shadow_render_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	is_point := int(setup.instance_idx) < len(setup.light_is_point) && setup.light_is_point[setup.instance_idx]
	shadow_render_system.declare_resources(setup, is_point)
}

shadow_render_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	light_index := resources.light_handle
	light_data, exists := &manager.per_light_data[light_index]
	if !exists do return

	// Execute appropriate rendering based on light type
	mesh_desc_sets := [5]vk.DescriptorSet{
		manager.bone_buffer.descriptor_sets[frame_index],
		manager.material_buffer.descriptor_set,
		manager.node_data_buffer.descriptor_set,
		manager.mesh_data_buffer.descriptor_set,
		manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
	}

	shadow_2d: Maybe(ShadowMap)
	switch &variant in light_data {
	case PointLight:
		shadow, ok := variant.shadow.?
		if !ok do return
		cube_tex, _ := rg.get_texture(resources, "shadow_map_cube")
		cube_handle := texcube(cube_tex)
		shadow_sphere_render_system.render(
			&manager.shadow_sphere_render,
			cmd, &manager.texture_manager,
			shadow.projection, shadow.near, shadow.far, variant.position,
			cube_handle,
			shadow.draw_commands[frame_index], shadow.draw_count[frame_index],
			manager.texture_manager.descriptor_set,
			mesh_desc_sets[0], mesh_desc_sets[1], mesh_desc_sets[2], mesh_desc_sets[3], mesh_desc_sets[4],
			manager.mesh_manager.vertex_buffer.buffer,
			manager.mesh_manager.index_buffer.buffer,
			frame_index,
		)
		return
	case SpotLight:        shadow_2d = variant.shadow
	case DirectionalLight: shadow_2d = variant.shadow
	}
	shadow, ok := shadow_2d.?
	if !ok do return
	shadow_tex, _ := rg.get_texture(resources, "shadow_map_2d")
	shadow_handle := tex2d(shadow_tex)
	shadow_render_system.render(
		&manager.shadow_render,
		cmd, &manager.texture_manager,
		shadow.view_projection, shadow_handle,
		shadow.draw_commands[frame_index], shadow.draw_count[frame_index],
		manager.texture_manager.descriptor_set,
		mesh_desc_sets[0], mesh_desc_sets[1], mesh_desc_sets[2], mesh_desc_sets[3], mesh_desc_sets[4],
		manager.mesh_manager.vertex_buffer.buffer,
		manager.mesh_manager.index_buffer.buffer,
		frame_index,
	)
}

// ============================================================================
// PARTICLES RENDER PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

particles_render_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	particles_render.declare_resources(setup)
}

particles_render_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	fin_tex, _ := rg.get_texture(resources, "final_image")

	particles_render.begin_pass(
		&manager.particles_render,
		cmd,
		tex2d(fin_tex),
		cam.depth[frame_index],
		&manager.texture_manager,
	)
	particles_render.render(
		&manager.particles_render,
		cmd,
		cam_handle,
		manager.camera_buffer.descriptor_sets[frame_index],
		manager.texture_manager.descriptor_set,
		manager.compact_particle_buffer.buffer,
		manager.particle_draw_command_buffer.buffer,
	)
	particles_render.end_pass(cmd)
}

// ============================================================================
// TRANSPARENT PASS (PER_CAMERA, GRAPHICS)
// ============================================================================

transparent_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	transparent.declare_resources(setup)
}

transparent_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data
	cam_handle := resources.camera_handle
	cam, exists := &manager.per_camera_data[cam_handle]
	if !exists do return

	fin_tex, _ := rg.get_texture(resources, "final_image")

	transparent.begin_pass(&manager.transparent_renderer, cmd, tex2d(fin_tex), cam.depth[frame_index], &manager.texture_manager)
	transparent.render(
		&manager.transparent_renderer,
		cmd,
		cam_handle,
		manager.camera_buffer.descriptor_sets[frame_index],
		manager.texture_manager.descriptor_set,
		manager.bone_buffer.descriptor_sets[frame_index],
		manager.material_buffer.descriptor_set,
		manager.node_data_buffer.descriptor_set,
		manager.mesh_data_buffer.descriptor_set,
		manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
		manager.mesh_manager.vertex_buffer.buffer,
		manager.mesh_manager.index_buffer.buffer,
		cam.transparent_draw_commands[frame_index].buffer,
		cam.transparent_draw_count[frame_index].buffer,
		rd.MAX_NODES_IN_SCENE,
	)
	transparent.end_pass(cmd)
}

// ============================================================================
// POST PROCESS PASS (GLOBAL, GRAPHICS)
// ============================================================================

post_process_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	post_process.declare_resources(setup)
}

post_process_execute :: proc(
	resources: ^rg.PassResources,
	cmd: vk.CommandBuffer,
	frame_index: u32,
	user_data: rawptr,
) {
	manager := cast(^Manager)user_data

	// Get main camera depth (camera 0, still Camera-owned)
	main_cam_handle := get_camera_handle_by_index(manager, 0)
	main_cam, exists := &manager.per_camera_data[main_cam_handle]
	if !exists do return

	// Get G-buffer handles from graph resources (PER_CAMERA scope, camera 0)
	fin_tex, _ := rg.get_texture(resources, "final_image_cam_0")
	pos_tex, _ := rg.get_texture(resources, "gbuffer_position_cam_0")
	nrm_tex, _ := rg.get_texture(resources, "gbuffer_normal_cam_0")
	alb_tex, _ := rg.get_texture(resources, "gbuffer_albedo_cam_0")
	mr_tex, _  := rg.get_texture(resources, "gbuffer_metallic_roughness_cam_0")
	emi_tex, _ := rg.get_texture(resources, "gbuffer_emissive_cam_0")
	final_image_h := tex2d(fin_tex)

	final_image_vk: vk.Image
	if tex := gpu.get_texture_2d(&manager.texture_manager, final_image_h); tex != nil {
		final_image_vk = tex.image
	}
	post_process.begin_pass(&manager.post_process, cmd, manager.current_swapchain_extent, final_image_vk, manager.current_swapchain_image)
	post_process.render(
		&manager.post_process,
		cmd,
		manager.current_swapchain_extent,
		manager.current_swapchain_view,
		final_image_h.index,
		tex2d(pos_tex).index,
		tex2d(nrm_tex).index,
		tex2d(alb_tex).index,
		tex2d(mr_tex).index,
		tex2d(emi_tex).index,
		main_cam.depth[frame_index].index,
		&manager.texture_manager,
	)
	post_process.end_pass(&manager.post_process, cmd)
}

// ============================================================================
// UI PASS (GLOBAL, GRAPHICS)
// ============================================================================

ui_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	ui_render.declare_resources(setup)
}
// execute → ui_render.execute (dispatched via ExecuteContext in Manager)

// ============================================================================
// DEBUG UI PASS (GLOBAL, GRAPHICS)
// ============================================================================

debug_ui_setup :: proc(setup: ^rg.PassSetup, _: rawptr) {
	debug_ui.declare_resources(setup)
}
// execute → debug_ui.execute (dispatched via ExecuteContext in Manager)

// ============================================================================
// Helpers
// ============================================================================

// Resolve 2D shadow map index and view-projection from a Maybe(ShadowMap).
// Used by SpotLight and DirectionalLight which share the same shadow map type.
@(private)
resolve_shadow_2d :: proc(
	shadow: Maybe(ShadowMap),
	resources: ^rg.PassResources,
	light_inst: int,
) -> (shadow_map_idx: u32, shadow_vp: matrix[4, 4]f32) {
	shadow_map_idx = 0xFFFFFFFF
	sm, ok := shadow.?
	if !ok do return
	shadow_vp = sm.view_projection
	if tex, texok := rg.get_texture(resources, fmt.tprintf("shadow_map_2d_light_%d", light_inst)); texok {
		shadow_map_idx = tex2d(tex).index
	}
	return
}

// Initialize GPU resources for perspective camera
// Takes only the specific resources needed, no dependency on render manager
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
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    camera.depth[frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return

    // Transition depth image to DEPTH_STENCIL_READ_ONLY_OPTIMAL for initial pyramid build
    if depth := gpu.get_texture_2d(texture_manager, camera.depth[frame]); depth != nil {
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

  // Create indirect draw buffers (double-buffered)
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    camera.opaque_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.opaque_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.transparent_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.transparent_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.wireframe_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.wireframe_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.random_color_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.random_color_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.line_strip_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.line_strip_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.sprite_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.sprite_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
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

// Destroy GPU resources for perspective/orthographic camera
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
    dp.destroy_pyramid(
      gctx,
      &camera.depth_pyramid[frame],
      texture_manager,
    )
  }

  // Destroy indirect draw buffers
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &camera.opaque_draw_count[frame])
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.opaque_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.transparent_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.transparent_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.wireframe_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.wireframe_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.random_color_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.random_color_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.line_strip_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.line_strip_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &camera.sprite_draw_count[frame])
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.sprite_draw_commands[frame],
    )
  }
  // Zero out the GPU struct
  camera^ = {}
}

// Allocate descriptor sets for perspective/orthographic camera culling pipelines
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
    prev_frame_index := (frame_index + rd.FRAMES_IN_FLIGHT - 1) % rd.FRAMES_IN_FLIGHT
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
        gpu.buffer_info(&camera.opaque_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.opaque_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.transparent_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.transparent_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.sprite_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.sprite_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.wireframe_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.wireframe_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.random_color_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.random_color_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.line_strip_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.line_strip_draw_commands[frame_index]),
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

// Resize camera render targets (called on window resize)
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
  for frame in 0 ..< rd.FRAMES_IN_FLIGHT {
    camera.depth[frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return

    if depth := gpu.get_texture_2d(texture_manager, camera.depth[frame]); depth != nil {
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
