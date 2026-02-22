package render

import alg "../algebra"
import cont "../containers"
import geom "../geometry"
import "../gpu"
import cmd "../gpu/ui"
import "camera"
import cam "camera"
import rctx "context"
import "core:log"
import "core:math"
import "core:math/linalg"
import rd "data"
import "debug"
import "debug_ui"
import rg "graph"
import "geometry"
import ambient "ambient"
import light "lighting"
import line_strip "line_strip"
import oc "occlusion_culling"
import psim "particle_simulation"
import prender "particle_render"
import tonemap "post_process/tonemap"
import random_color "random_color"
import shd "shadow"
import sprite "sprite"
import transparent "transparent"
import ui_render "ui"
import wireframe "wireframe"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: rd.FRAMES_IN_FLIGHT

// Re-export RenderContext from context package
RenderContext :: rctx.RenderContext

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
BoneInstance :: debug.BoneInstance

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

ShadowResources :: struct {
  shadow_data_buffer: gpu.PerFrameBindlessBuffer(
    shd.ShadowData,
    FRAMES_IN_FLIGHT,
  ),
  spot_lights:         [shd.MAX_SHADOW_MAPS]light.SpotLight,
  directional_lights:  [shd.MAX_SHADOW_MAPS]light.DirectionalLight,
  point_lights:        [shd.MAX_SHADOW_MAPS]light.PointLight,
  slot_active:         [shd.MAX_SHADOW_MAPS]bool,      // Set by shadow_sync_lights each frame
  slot_allocated:      [shd.MAX_SHADOW_MAPS]bool,      // Tracks which slots have GPU resources
  slot_kind:           [shd.MAX_SHADOW_MAPS]LightType, // Current frame's light type
  light_to_slot:       [rd.MAX_LIGHTS]u32,
}

ParticleResources :: struct {
  particle_buffer:         gpu.MutableBuffer(psim.Particle),
  compact_particle_buffer: gpu.MutableBuffer(psim.Particle),
  draw_command_buffer:     gpu.MutableBuffer(vk.DrawIndirectCommand),
  params_buffer:           gpu.MutableBuffer(psim.ParticleSystemParams),
  particle_count_buffer:   gpu.MutableBuffer(u32),
}

UIResources :: struct {
  vertex_buffers: [FRAMES_IN_FLIGHT]gpu.MutableBuffer(ui_render.Vertex2D),
  index_buffers:  [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
}

DebugUIResources :: struct {
  vertex_buffer: gpu.MutableBuffer(debug_ui.Vertex2D),
  index_buffer:  gpu.MutableBuffer(u32),
}

DebugResources :: struct {
  bone_instance_buffer: gpu.MutableBuffer(debug.BoneInstance),
}

Manager :: struct {
  command_buffers:         [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers: [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  geometry:                geometry.Renderer,
  ambient:                 ambient.AmbientRenderer,
  lighting:                light.LightingRenderer,
  transparent:             transparent.Renderer,
  wireframe:               wireframe.Renderer,
  random_color:            random_color.Renderer,
  line_strip:              line_strip.Renderer,
  sprite:                  sprite.Renderer,
  particle_simulation:     psim.System,
  particle_render:         prender.Renderer,
  tonemap_renderer:        tonemap.Renderer,
  debug_ui:                debug_ui.Renderer,
  debug_renderer:          debug.Renderer,
  ui:                      ui_render.Renderer,
  ui_commands:             [dynamic]cmd.RenderCommand, // Staged commands from UI module
  cameras:                 map[u32]camera.Camera,
  camera_resources:        map[u32]camera.CameraResources,
  meshes:                  map[u32]Mesh,
  occlusion_culling:       oc.System,
  shadow:                  shd.ShadowSystem,
  shadow_resources:        ShadowResources,
  particle_resources:      ParticleResources,
  ui_resources:            UIResources,
  debug_ui_resources:      DebugUIResources,
  debug_resources:         DebugResources,
  linear_repeat_sampler:   vk.Sampler,
  linear_clamp_sampler:    vk.Sampler,
  nearest_repeat_sampler:  vk.Sampler,
  nearest_clamp_sampler:   vk.Sampler,
  bone_buffer:             gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:           gpu.PerFrameBindlessBuffer(
    rd.Camera,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:         gpu.BindlessBuffer(Material),
  node_data_buffer:        gpu.BindlessBuffer(Node),
  mesh_data_buffer:        gpu.BindlessBuffer(Mesh),
  emitter_buffer:          gpu.BindlessBuffer(Emitter),
  forcefield_buffer:       gpu.BindlessBuffer(ForceField),
  sprite_buffer:           gpu.BindlessBuffer(Sprite),
  lights_buffer:           gpu.BindlessBuffer(Light),
  mesh_manager:            gpu.MeshManager,
  bone_matrix_slab:        cont.SlabAllocator,
  bone_matrix_offsets:     map[u32]u32,
  texture_manager:         gpu.TextureManager,
  // Render graph (Phase 1+)
  graph:                   rg.Graph,
  default_graph_state:     DefaultGraphState,
}

// build_render_context constructs a RenderContext for the current frame.
// Should be called once per frame before rendering.
build_render_context :: proc(manager: ^Manager, frame_index: u32) -> RenderContext {
	return RenderContext {
		cameras_descriptor_set = manager.camera_buffer.descriptor_sets[frame_index],
		textures_descriptor_set = manager.texture_manager.descriptor_set,
		bone_descriptor_set = manager.bone_buffer.descriptor_sets[frame_index],
		material_descriptor_set = manager.material_buffer.descriptor_set,
		node_data_descriptor_set = manager.node_data_buffer.descriptor_set,
		mesh_data_descriptor_set = manager.mesh_data_buffer.descriptor_set,
		vertex_skinning_descriptor_set = manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
		sprite_buffer_descriptor_set = manager.sprite_buffer.descriptor_set,
		lights_descriptor_set = manager.lights_buffer.descriptor_set,
		vertex_buffer = manager.mesh_manager.vertex_buffer.buffer,
		index_buffer = manager.mesh_manager.index_buffer.buffer,
	}
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
  self.camera_resources = make(map[u32]camera.CameraResources)
  self.meshes = make(map[u32]Mesh)
  self.ui_commands = make([dynamic]cmd.RenderCommand, 0, 256)
  rg.init(&self.graph)
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
  gpu.bindless_buffer_init(
    &self.lights_buffer,
    gctx,
    rd.MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
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
  oc.init(
    &self.occlusion_culling,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  gpu.per_frame_bindless_buffer_init(
    &self.shadow_resources.shadow_data_buffer,
    gctx,
    shd.MAX_SHADOW_MAPS,
    {.VERTEX, .FRAGMENT, .GEOMETRY, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(
      &self.shadow_resources.shadow_data_buffer,
      gctx.device,
    )
  }
  shd.shadow_init(
    &self.shadow,
    gctx,
    self.shadow_resources.shadow_data_buffer.set_layout,
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
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
  ) or_return
  light.init(
    &self.lighting,
    gctx,
    self.camera_buffer.set_layout,
    self.lights_buffer.set_layout,
    self.shadow_resources.shadow_data_buffer.set_layout,
    self.texture_manager.set_layout,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  geometry.init(
    &self.geometry,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  psim.init(
    &self.particle_simulation,
    gctx,
    self.emitter_buffer.set_layout,
    self.forcefield_buffer.set_layout,
    self.node_data_buffer.set_layout,
  ) or_return
  prender.init(
    &self.particle_render,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  transparent.init(
    &self.transparent,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  wireframe.init(
    &self.wireframe,
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
    &self.random_color,
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
    &self.line_strip,
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
    &self.sprite,
    gctx,
    self.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.node_data_buffer.set_layout,
    self.sprite_buffer.set_layout,
  ) or_return
  tonemap.init(
    &self.tonemap_renderer,
    gctx,
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

  // Allocate debug resources (bone instance buffer)
  self.debug_resources.bone_instance_buffer = gpu.create_mutable_buffer(
    gctx,
    debug.BoneInstance,
    4096, // max bones
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.debug_resources.bone_instance_buffer)
  }

  // Allocate UI resources (vertex and index buffers per frame)
  for i in 0 ..< FRAMES_IN_FLIGHT {
    self.ui_resources.vertex_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      ui_render.Vertex2D,
      ui_render.UI_MAX_VERTICES,
      {.VERTEX_BUFFER},
    ) or_return
    defer if ret != .SUCCESS {
      gpu.mutable_buffer_destroy(gctx.device, &self.ui_resources.vertex_buffers[i])
    }
    self.ui_resources.index_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      u32,
      ui_render.UI_MAX_INDICES,
      {.INDEX_BUFFER},
    ) or_return
    defer if ret != .SUCCESS {
      gpu.mutable_buffer_destroy(gctx.device, &self.ui_resources.index_buffers[i])
    }
  }

  // Allocate Debug UI resources
  self.debug_ui_resources.vertex_buffer = gpu.create_mutable_buffer(
    gctx,
    debug_ui.Vertex2D,
    debug_ui.UI_MAX_VERTICES,
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.debug_ui_resources.vertex_buffer)
  }
  self.debug_ui_resources.index_buffer = gpu.create_mutable_buffer(
    gctx,
    u32,
    debug_ui.UI_MAX_INDICES,
    {.INDEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.debug_ui_resources.index_buffer)
  }

  // Allocate Particle resources
  self.particle_resources.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    psim.Particle,
    psim.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.particle_buffer)
  }
  self.particle_resources.compact_particle_buffer = gpu.create_mutable_buffer(
    gctx,
    psim.Particle,
    psim.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.compact_particle_buffer)
  }
  self.particle_resources.draw_command_buffer = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndirectCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.draw_command_buffer)
  }
  self.particle_resources.params_buffer = gpu.create_mutable_buffer(
    gctx,
    psim.ParticleSystemParams,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.params_buffer)
  }
  self.particle_resources.particle_count_buffer = gpu.create_mutable_buffer(
    gctx,
    u32,
    1,
    {.STORAGE_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.particle_count_buffer)
  }

  debug.init(
    &self.debug_renderer,
    gctx,
    self.camera_buffer.set_layout,
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
  gpu.bindless_buffer_realloc_descriptor(&self.lights_buffer, gctx) or_return
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
  light.setup(&self.lighting, gctx) or_return
  shd.shadow_setup_buffers(
    &self.shadow_resources.shadow_data_buffer,
    gctx,
  ) or_return
  // Pre-allocate all shadow slots upfront (following single-node API)
  for slot in 0 ..< shd.MAX_SHADOW_MAPS {
    shd.shadow_setup_slot(
      &self.shadow,
      &self.shadow_resources.shadow_data_buffer,
      u32(slot),
      &self.shadow_resources.spot_lights[slot],
      &self.shadow_resources.directional_lights[slot],
      &self.shadow_resources.point_lights[slot],
      gctx,
      &self.texture_manager,
      &self.node_data_buffer,
      &self.mesh_data_buffer,
    ) or_return
    self.shadow_resources.slot_allocated[slot] = true
  }
  psim.setup(
    &self.particle_simulation,
    gctx,
    self.emitter_buffer.descriptor_set,
    self.forcefield_buffer.descriptor_set,
    &self.particle_resources.particle_buffer,
    &self.particle_resources.compact_particle_buffer,
    &self.particle_resources.draw_command_buffer,
    &self.particle_resources.params_buffer,
    &self.particle_resources.particle_count_buffer,
  ) or_return
  prender.setup(
    &self.particle_render,
    gctx,
    &self.texture_manager,
  ) or_return
  // Post-processing is now node-based, no setup needed
  debug_ui.setup(&self.debug_ui, gctx, &self.texture_manager) or_return
  // UI buffers now managed by Manager.ui_resources, no setup needed
  return .SUCCESS
}

teardown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  // Destroy camera GPU resources (VkImages, draw command buffers) before texture_manager goes away
  for _, &cam_res in self.camera_resources {
    camera.destroy_gpu(gctx, &cam_res, &self.texture_manager)
  }
  clear(&self.camera_resources)
  clear(&self.cameras)

  // Destroy debug resources
  gpu.mutable_buffer_destroy(gctx.device, &self.debug_resources.bone_instance_buffer)

  // Destroy UI resources
  for i in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.ui_resources.vertex_buffers[i])
    gpu.mutable_buffer_destroy(gctx.device, &self.ui_resources.index_buffers[i])
  }

  // Destroy Debug UI resources
  gpu.mutable_buffer_destroy(gctx.device, &self.debug_ui_resources.vertex_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.debug_ui_resources.index_buffer)

  // Destroy Particle resources
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.compact_particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.draw_command_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.params_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.particle_resources.particle_count_buffer)

  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  // Post-processing is now node-based, no teardown needed
  psim.teardown(&self.particle_simulation, gctx)
  prender.teardown(&self.particle_render, gctx, &self.texture_manager)
  // Teardown shadow slots that were allocated
  for slot in 0 ..< shd.MAX_SHADOW_MAPS {
    if !self.shadow_resources.slot_allocated[slot] do continue
    shd.shadow_teardown_slot(
      &self.shadow,
      u32(slot),
      &self.shadow_resources.spot_lights[slot],
      &self.shadow_resources.directional_lights[slot],
      &self.shadow_resources.point_lights[slot],
      gctx,
      &self.texture_manager,
    )
    self.shadow_resources.slot_allocated[slot] = false
  }
  ambient.teardown(&self.ambient, gctx, &self.texture_manager)
  light.teardown(&self.lighting, gctx)
  gpu.texture_manager_teardown(&self.texture_manager, gctx)
  // Zero all descriptor set handles (freed in bulk below)
  self.material_buffer.descriptor_set = 0
  self.node_data_buffer.descriptor_set = 0
  self.mesh_data_buffer.descriptor_set = 0
  self.emitter_buffer.descriptor_set = 0
  self.forcefield_buffer.descriptor_set = 0
  self.sprite_buffer.descriptor_set = 0
  self.lights_buffer.descriptor_set = 0
  for &ds in self.bone_buffer.descriptor_sets do ds = 0
  for &ds in self.camera_buffer.descriptor_sets do ds = 0
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
  // Bulk-free all descriptor sets allocated from the pool
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
}

@(private)
ensure_camera_slot :: proc(self: ^Manager, handle: u32) {
  if handle not_in self.cameras {
    self.cameras[handle] = {}
  }
  if handle not_in self.camera_resources {
    self.camera_resources[handle] = {}
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
  // intentionally empty
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
  for cam_index, &cam_res in self.camera_resources {
    // Only build pyramid if enabled for this camera
    oc.build_pyramid(
      &self.occlusion_culling,
      gctx,
      cmd,
      &cam_res,
      u32(cam_index),
      frame_index,
    ) // Build pyramid[N]
    oc.perform_culling(
      &self.occlusion_culling,
      gctx,
      cmd,
      &cam_res,
      u32(cam_index),
      next_frame_index,
      {.VISIBLE},
      {},
    ) // Write draw_list[N+1]

  }
  // Particle simulation is now handled by the render graph
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
  instances: []debug.BoneInstance,
) {
  debug.stage_bones(&self.debug_renderer, instances)
}

// Clear staged debug visualization data
clear_debug_visualization :: proc(self: ^Manager) {
  debug.clear_bones(&self.debug_renderer)
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.free_command_buffer(gctx, ..self.command_buffers[:])
  if gctx.has_async_compute {
    gpu.free_compute_command_buffer(gctx, self.compute_command_buffers[:])
  }
  ui_render.shutdown(&self.ui, gctx)
  delete(self.ui_commands)
  debug.shutdown(&self.debug_renderer, gctx)
  debug_ui.shutdown(&self.debug_ui, gctx)
  tonemap.destroy(&self.tonemap_renderer, gctx)
  psim.destroy(&self.particle_simulation, gctx)
  prender.destroy(&self.particle_render, gctx)
  transparent.destroy(&self.transparent, gctx)
  wireframe.destroy(&self.wireframe, gctx)
  random_color.destroy(&self.random_color, gctx)
  line_strip.destroy(&self.line_strip, gctx)
  sprite.destroy(&self.sprite, gctx)
  ambient.destroy(&self.ambient, gctx)
  light.destroy(&self.lighting, gctx)
  shd.shadow_shutdown(&self.shadow, gctx)
  gpu.per_frame_bindless_buffer_destroy(
    &self.shadow_resources.shadow_data_buffer,
    gctx.device,
  )
  geometry.shutdown(&self.geometry, gctx)
  oc.shutdown(&self.occlusion_culling, gctx)
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
  gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  delete(self.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  delete(self.cameras)
  delete(self.camera_resources)
  delete(self.meshes)
  rg.destroy(&self.graph)
}

resize :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  light.recreate_images(
    &self.lighting,
    extent,
    color_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  // Post-processing is now node-based, no image recreation needed
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

upload_light_data :: proc(
  render: ^Manager,
  index: u32,
  light_data: ^rd.Light,
) {
  gpu.write(&render.lights_buffer.buffer, light_data, int(index))
  shd.shadow_invalidate_light(
    &render.shadow_resources.slot_active,
    &render.shadow_resources.light_to_slot,
    index,
  )
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
