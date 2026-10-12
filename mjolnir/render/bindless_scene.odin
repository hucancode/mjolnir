#+private
package render

import "gpu"
import vk "vendor:vulkan"

// Bindings of the scene set (set 0), one descriptor each of the type in
// SCENE_BINDING_TYPES. Shaders repeat these numbers as literals.
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
  // the shadow atlas
  SHADOW_MAPS,
  DEBUG_LINES,
}

SCENE_BINDING_TYPES := [SceneBinding]vk.DescriptorType {
  .VIEWS           = .STORAGE_BUFFER,
  .NODES           = .STORAGE_BUFFER,
  .MESHES          = .STORAGE_BUFFER,
  .MATERIALS       = .STORAGE_BUFFER,
  .BONES           = .STORAGE_BUFFER,
  .SKINNING        = .STORAGE_BUFFER,
  .EMITTERS        = .STORAGE_BUFFER,
  .FORCEFIELDS     = .STORAGE_BUFFER,
  .PARTICLES       = .STORAGE_BUFFER,
  .PARTICLE_ALIVE  = .STORAGE_BUFFER,
  .LIGHTS          = .STORAGE_BUFFER,
  .SHADOW_MAPS     = .SAMPLED_IMAGE,
  .DEBUG_LINES     = .STORAGE_BUFFER,
}

// Every scene pipeline uses one layout, {scene set, textures set} with this
// push-constant range, so both sets are bound once per command buffer and
// stay bound across pipeline switches.
PUSH_CONSTANT_SIZE :: 128
SCENE_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

// Render's two descriptor sets and the one pipeline layout over them.
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


// Create the scene set layout, one set per frame in flight pointing at the
// scene buffers, and the shared pipeline layout. Call after every scene buffer
// and the bindless set exist.
scene_descriptors_init :: proc(self: ^Renderer) -> (ret: vk.Result) {
  gctx := &self.gctx
  scene := &self.scene
  defer if ret != .SUCCESS do scene_descriptors_shutdown(scene, gctx)
  bindings: [len(SceneBinding)]gpu.DescriptorBinding
  for type, b in SCENE_BINDING_TYPES do bindings[b] = {type, 1, SCENE_STAGES}
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

// Point binding `b` of frame `frame_index`'s scene set at its current buffer.
// The caller guarantees no submitted work still uses that set.
scene_write_binding :: proc(self: ^Renderer, b: SceneBinding, frame_index: int) {
  atlas := &self.shadow_atlas[frame_index]
  layout := &self.arena_layout
  // an arena table, unless a resource of its own backs the binding
  info: gpu.DescriptorInfo = vk.DescriptorBufferInfo{buffer = self.frame_arena[frame_index].buffer, offset = layout.offset[b], range = layout.range[b]}
  #partial switch b {
  case .MESHES:          info = gpu.buffer_info(&self.mesh_data_buffer)
  case .SKINNING:        info = gpu.buffer_info(&self.mesh_buffers[.SKINNING])
  case .PARTICLES:       info = gpu.buffer_info(&self.particle_buffer)
  case .PARTICLE_ALIVE:  info = gpu.buffer_info(&self.particle_alive_buffer)
  case .BONES:           info = gpu.buffer_info(&self.bone_buffers[frame_index])
  case .SHADOW_MAPS:     info = vk.DescriptorImageInfo{imageView = atlas.view, imageLayout = .GENERAL}
  }
  gpu.write_descriptor(&self.gctx, self.scene.sets[frame_index], u32(b), 0, SCENE_BINDING_TYPES[b], info)
}

// Bind the scene and bindless sets of `frame_index` to `bind_point`.
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

// Push `data` at offset 0 of the push-constant range every pipeline shares.
push_constants :: proc(self: ^Renderer, cmd: vk.CommandBuffer, data: ^$T) {
  #assert(size_of(T) <= PUSH_CONSTANT_SIZE)
  vk.CmdPushConstants(cmd, self.scene.layout, SCENE_STAGES, 0, size_of(T), data)
}

// Bind the mesh arena's vertex and index buffers.
bind_mesh_buffers :: proc(self: ^Renderer, cmd: vk.CommandBuffer) {
  gpu.bind_vertex_index_buffers(
    cmd,
    self.mesh_buffers[.VERTEX].buffer,
    self.mesh_buffers[.INDEX].buffer,
  )
}
