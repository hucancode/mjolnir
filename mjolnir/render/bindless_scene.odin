#+private
package render

import "gpu"
import vk "vendor:vulkan"

// Bindings of the scene set (set 0), one descriptor each of the type in
// BINDINGS. Shaders repeat these numbers as literals.
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

// Descriptor type of each binding. A binding with a stride is a table the CPU writes: one copy
// per frame in flight in the frame arena, `capacity` entries of `stride` bytes (see frame_arena.odin).
// The others are backed by a resource of their own (scene_write_binding).
BINDINGS := [SceneBinding]struct {
  type:     vk.DescriptorType,
  stride:   int,
  capacity: int,
} {
  .VIEWS          = {.STORAGE_BUFFER, size_of(ViewGPU), MAX_VIEWS},
  .NODES          = {.STORAGE_BUFFER, size_of(NodeData), MAX_NODES_IN_SCENE},
  .MESHES         = {.STORAGE_BUFFER, size_of(MeshData), MAX_MESHES},
  .MATERIALS      = {.STORAGE_BUFFER, size_of(Material), MAX_MATERIALS},
  .BONES          = {.STORAGE_BUFFER, size_of(matrix[4, 4]f32), BONE_CAPACITY},
  .SKINNING       = {type = .STORAGE_BUFFER},
  .EMITTERS       = {.STORAGE_BUFFER, size_of(Emitter), MAX_EMITTERS},
  .FORCEFIELDS    = {.STORAGE_BUFFER, size_of(ForceField), MAX_FORCE_FIELDS},
  .PARTICLES      = {type = .STORAGE_BUFFER},
  .PARTICLE_ALIVE = {type = .STORAGE_BUFFER},
  .LIGHTS         = {.STORAGE_BUFFER, size_of(Light), MAX_LIGHTS},
  // the shadow atlas
  .SHADOW_MAPS    = {type = .SAMPLED_IMAGE},
  .DEBUG_LINES    = {.STORAGE_BUFFER, size_of(DebugLineSegment), MAX_SEGMENTS},
}

// One layout for every scene pipeline, so both sets stay bound across pipeline switches.
@(private = "file")
PUSH_CONSTANT_SIZE :: 128
SCENE_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

// SceneDescriptors are the scene and bindless descriptor sets with the pipeline layout over them.
SceneDescriptors :: struct {
  // set 0: the scene buffers, one set per frame in flight
  set_layout:      vk.DescriptorSetLayout,
  sets:            [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
  // set 1: the bindless arrays (BINDLESS_BINDINGS)
  bindless_layout: vk.DescriptorSetLayout,
  bindless_set:    vk.DescriptorSet,
  // {scene, bindless}
  layout:          vk.PipelineLayout,
}


scene_descriptors_init :: proc(self: ^Renderer) -> (ret: vk.Result) {
  gctx := &self.gctx
  scene := &self.scene
  defer if ret != .SUCCESS do scene_descriptors_shutdown(scene, gctx)
  bindings: [len(SceneBinding)]gpu.DescriptorBinding
  for binding, b in BINDINGS do bindings[b] = {binding.type, 1, SCENE_STAGES}
  scene.set_layout = gpu.create_descriptor_layout(gctx, ..bindings[:]) or_return
  for &set, frame in scene.sets {
    gpu.allocate_descriptor_set(gctx, &set, &scene.set_layout) or_return
    for b in SceneBinding do scene_write_binding(self, b, frame)
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

scene_descriptors_shutdown :: proc(self: ^SceneDescriptors, gctx: ^gpu.GPUContext) {
  vk.DestroyPipelineLayout(gctx.device, self.layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self.layout, self.set_layout = 0, 0
}

// The caller guarantees no submitted work still uses the set.
scene_write_binding :: proc(self: ^Renderer, b: SceneBinding, frame_index: int) {
  atlas := &self.shadow_atlas[frame_index]
  // an arena table, unless a resource of its own backs the binding
  info: gpu.DescriptorInfo = vk.DescriptorBufferInfo{buffer = self.frame_arena[frame_index].buffer, offset = self.arena_offset[b], range = table_range(b)}
  #partial switch b {
  case .SKINNING:        info = gpu.buffer_info(&self.mesh_buffers[.SKINNING])
  case .PARTICLES:       info = gpu.buffer_info(&self.particle_buffer)
  case .PARTICLE_ALIVE:  info = gpu.buffer_info(&self.particle_alive_buffer)
  case .SHADOW_MAPS:     info = vk.DescriptorImageInfo{imageView = atlas.view, imageLayout = .GENERAL}
  }
  gpu.write_descriptor(&self.gctx, self.scene.sets[frame_index], u32(b), 0, BINDINGS[b].type, info)
}

bind_scene_sets :: proc(
  self: ^Renderer,
  cmd: vk.CommandBuffer,
  bind_point: vk.PipelineBindPoint,
  frame_index: u32,
) {
  sets := [2]vk.DescriptorSet {
    self.scene.sets[frame_index],
    self.scene.bindless_set,
  }
  vk.CmdBindDescriptorSets(cmd, bind_point, self.scene.layout, 0, len(sets), raw_data(sets[:]), 0, nil)
}

push_constants :: proc(self: ^Renderer, cmd: vk.CommandBuffer, data: ^$T) {
  #assert(size_of(T) <= PUSH_CONSTANT_SIZE)
  vk.CmdPushConstants(cmd, self.scene.layout, SCENE_STAGES, 0, size_of(T), data)
}

bind_mesh_buffers :: proc(self: ^Renderer, cmd: vk.CommandBuffer) {
  gpu.bind_vertex_index_buffers(
    cmd,
    self.mesh_buffers[.VERTEX].buffer,
    self.mesh_buffers[.INDEX].buffer,
  )
}
