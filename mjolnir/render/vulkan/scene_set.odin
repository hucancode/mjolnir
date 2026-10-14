package vulkan_backend

import vk "vendor:vulkan"

MAX_NODES_IN_SCENE :: 65536
MAX_ACTIVE_CAMERAS :: 128

// The views table holds every camera at CAMERA_VIEW_BASE + camera, then the shadow views.
CAMERA_VIEW_BASE :: 0
SHADOW_VIEW_BASE :: MAX_ACTIVE_CAMERAS
MAX_VIEWS :: MAX_ACTIVE_CAMERAS + MAX_SHADOW_VIEWS

// The tables render writes, one copy per frame in flight (table); their sizes are given at
// init. The entries' layouts are render's, mirrored by the shaders.
Table :: enum {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  EMITTERS,
  FORCEFIELDS,
  LIGHTS,
  DEBUG_LINES,
}

// Vertex is the mesh vertex format.
Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  tangent:  [4]f32, // xyz = tangent, w = handedness (for bitangent reconstruction)
}

// MeshData is a mesh as the cull shader reads it from the mesh table.
MeshData :: struct {
  aabb_min:        [3]f32,
  index_count:     u32,
  aabb_max:        [3]f32,
  first_index:     u32,
  vertex_offset:   i32,
  skinning_offset: u32,
  flags:           MeshFlagSet,
  vertex_count:    u32,
}

MeshFlag :: enum u32 {
  SKINNED,
}
MeshFlagSet :: bit_set[MeshFlag;u32]

// Bindings of the scene set: render's tables in the frame arena (TABLE_BINDING) and the
// buffers the backend owns. Shaders repeat these numbers.
@(private)
SceneBinding :: enum u32 {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  SKINNING,
  EMITTERS,
  FORCEFIELDS,
  PARTICLES,
  PARTICLE_ALIVE,
  LIGHTS,
  SHADOW_MAPS,
  DEBUG_LINES,
}

TABLE_BINDING := [Table]SceneBinding {
  .VIEWS       = .VIEWS,
  .NODES       = .NODES,
  .MESHES      = .MESHES,
  .MATERIALS   = .MATERIALS,
  .BONES       = .BONES,
  .EMITTERS    = .EMITTERS,
  .FORCEFIELDS = .FORCEFIELDS,
  .LIGHTS      = .LIGHTS,
  .DEBUG_LINES = .DEBUG_LINES,
}

// Descriptor type of each scene set (set 0) binding, one descriptor each. A binding render
// writes is its table in the frame arena; the others are backed by a resource of their own
// (scene_write_binding).
SCENE_BINDING_TYPES := [SceneBinding]vk.DescriptorType {
  .VIEWS          = .STORAGE_BUFFER,
  .NODES          = .STORAGE_BUFFER,
  .MESHES         = .STORAGE_BUFFER,
  .MATERIALS      = .STORAGE_BUFFER,
  .BONES          = .STORAGE_BUFFER,
  .SKINNING       = .STORAGE_BUFFER,
  .EMITTERS       = .STORAGE_BUFFER,
  .FORCEFIELDS    = .STORAGE_BUFFER,
  .PARTICLES      = .STORAGE_BUFFER,
  .PARTICLE_ALIVE = .STORAGE_BUFFER,
  .LIGHTS         = .STORAGE_BUFFER,
  // the shadow atlas
  .SHADOW_MAPS    = .SAMPLED_IMAGE,
  .DEBUG_LINES    = .STORAGE_BUFFER,
}

// One layout for every scene pipeline, so both sets stay bound across pipeline switches.
@(private = "file")
PUSH_CONSTANT_SIZE :: 128
@(private)
SCENE_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

// SceneDescriptors are the scene and bindless descriptor sets with the pipeline layout over them.
@(private)
SceneDescriptors :: struct {
  // set 0: the scene buffers, one set per frame in flight
  set_layout:      vk.DescriptorSetLayout,
  sets:            [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  // set 1: the bindless arrays (BINDLESS_BINDINGS)
  bindless_layout: vk.DescriptorSetLayout,
  bindless_set:    vk.DescriptorSet,
  // {scene, bindless}
  layout:          vk.PipelineLayout,
}

@(private)
scene_descriptors_init :: proc(b: ^Backend) -> (ret: vk.Result) {
  gctx := &b.gctx
  scene := &b.scene
  defer if ret != .SUCCESS do scene_descriptors_shutdown(scene, gctx)
  bindings: [len(SceneBinding)]DescriptorBinding
  for type, binding in SCENE_BINDING_TYPES do bindings[binding] = {type, 1, SCENE_STAGES}
  scene.set_layout = create_descriptor_layout(gctx, ..bindings[:]) or_return
  for &set, frame in scene.sets {
    allocate_descriptor_set(gctx, &set, &scene.set_layout) or_return
    for binding in SceneBinding do scene_write_binding(b, binding, frame)
  }
  sets := [2]vk.DescriptorSetLayout{scene.set_layout, scene.bindless_layout}
  push_range := vk.PushConstantRange{stageFlags = SCENE_STAGES, size = PUSH_CONSTANT_SIZE}
  layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = len(sets),
    pSetLayouts            = raw_data(sets[:]),
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_range,
  }
  vk.CreatePipelineLayout(gctx.device, &layout_info, nil, &scene.layout) or_return
  return .SUCCESS
}

@(private)
scene_descriptors_shutdown :: proc(self: ^SceneDescriptors, gctx: ^GPUContext) {
  vk.DestroyPipelineLayout(gctx.device, self.layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self.layout, self.set_layout = 0, 0
}

// The caller guarantees no submitted work still uses the set.
@(private)
scene_write_binding :: proc(b: ^Backend, binding: SceneBinding, frame_index: int) {
  atlas := &b.shadow_atlas[frame_index]
  // an arena table, unless a resource of its own backs the binding
  info: DescriptorInfo = vk.DescriptorBufferInfo {
    buffer = b.frame_arena[frame_index].buffer,
    offset = vk.DeviceSize(b.table_offset[binding]),
    range  = vk.DeviceSize(b.table_size[binding]),
  }
  #partial switch binding {
  case .SKINNING:        info = buffer_info(&b.mesh_buffers[.SKINNING])
  case .PARTICLES:       info = buffer_info(&b.particle_buffer)
  case .PARTICLE_ALIVE:  info = buffer_info(&b.particle_alive_buffer)
  case .SHADOW_MAPS:     info = vk.DescriptorImageInfo{imageView = atlas.view, imageLayout = .GENERAL}
  }
  write_descriptor(&b.gctx, b.scene.sets[frame_index], u32(binding), 0, SCENE_BINDING_TYPES[binding], info)
}

@(private)
bind_scene_sets :: proc(
  b: ^Backend,
  cmd: vk.CommandBuffer,
  bind_point: vk.PipelineBindPoint,
  frame_index: u32,
) {
  sets := [2]vk.DescriptorSet {
    b.scene.sets[frame_index],
    b.scene.bindless_set,
  }
  vk.CmdBindDescriptorSets(cmd, bind_point, b.scene.layout, 0, len(sets), raw_data(sets[:]), 0, nil)
}

@(private)
push_constants :: proc(b: ^Backend, cmd: vk.CommandBuffer, data: ^$T) {
  #assert(size_of(T) <= PUSH_CONSTANT_SIZE)
  vk.CmdPushConstants(cmd, b.scene.layout, SCENE_STAGES, 0, size_of(T), data)
}

@(private)
bind_mesh_buffers :: proc(b: ^Backend, cmd: vk.CommandBuffer) {
  bind_vertex_index_buffers(
    cmd,
    b.mesh_buffers[.VERTEX].buffer,
    b.mesh_buffers[.INDEX].buffer,
  )
}

VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX},
}

VERTEX_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, position))},
  {location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, normal))},
  {location = 2, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, color))},
  {location = 3, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, uv))},
  {location = 4, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, tangent))},
}
