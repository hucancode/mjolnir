#+private
package render

import "gpu"
import vk "vendor:vulkan"

// Bindings of the scene set (set 0), one descriptor each of the type in
// SCENE_BINDING_TYPES. Shaders repeat these numbers as literals.
SceneBinding :: enum u32 {
  CAMERAS,
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
  VIEWS,
  // the shadow atlas
  SHADOW_MAPS,
}

SCENE_BINDING_TYPES := [SceneBinding]vk.DescriptorType {
  .CAMERAS         = .STORAGE_BUFFER,
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
  .VIEWS           = .STORAGE_BUFFER,
  .SHADOW_MAPS     = .SAMPLED_IMAGE,
}

// Every scene pipeline uses one layout, {scene set, textures set} with this
// push-constant range, so both sets are bound once per command buffer and
// stay bound across pipeline switches.
PUSH_CONSTANT_SIZE :: 128
SCENE_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

SceneDescriptors :: struct {
  set_layout: vk.DescriptorSetLayout,
  sets:       [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
  // {scene, textures}
  layout:     vk.PipelineLayout,
}

// The resource behind one scene binding for frame `frame_index`.
scene_binding_info :: proc(
  self: ^Manager,
  b: SceneBinding,
  frame_index: int,
) -> gpu.DescriptorInfo {
  atlas := &self.internal.shadow_atlas[frame_index]
  #partial switch b {
  case .MESHES:          return gpu.buffer_info(&self.internal.mesh_data_buffer)
  case .SKINNING:        return gpu.buffer_info(&self.mesh_manager.vertex_skinning_buffer)
  case .PARTICLES:       return gpu.buffer_info(&self.internal.particles.particle_buffer)
  case .PARTICLE_ALIVE:  return gpu.buffer_info(&self.internal.particles.alive_buffer)
  case .SHADOW_MAPS:     return vk.DescriptorImageInfo{imageView = atlas.image.view, imageLayout = .GENERAL}
  }
  // a frame table
  arena := &self.internal.frame_arena[frame_index]
  layout := &self.internal.arena_layout
  offset := layout.offset[b]
  range := arena.size - offset if b == .BONES else layout.range[b]
  return vk.DescriptorBufferInfo{buffer = arena.buffer, offset = offset, range = range}
}

// Create the scene set layout, one set per frame in flight pointing at the
// scene buffers, and the shared pipeline layout. Call after every scene buffer
// and the texture manager exist.
scene_descriptors_init :: proc(self: ^Manager) -> (ret: vk.Result) {
  gctx := &self.gctx
  scene := &self.internal.scene
  defer if ret != .SUCCESS do scene_descriptors_shutdown(scene, gctx)
  bindings: [len(SceneBinding)]gpu.DescriptorBinding
  for type, b in SCENE_BINDING_TYPES do bindings[b] = {type, 1, SCENE_STAGES}
  scene.set_layout = gpu.create_descriptor_layout(gctx, ..bindings[:]) or_return
  for &set, frame in scene.sets {
    gpu.allocate_descriptor_set(gctx, &set, &scene.set_layout) or_return
    for b in SceneBinding do scene_write_binding(self, b, frame)
  }
  sets := [2]vk.DescriptorSetLayout{scene.set_layout, self.texture_manager.set_layout}
  scene.layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = SCENE_STAGES, size = PUSH_CONSTANT_SIZE},
    ..sets[:],
  ) or_return
  return .SUCCESS
}

scene_descriptors_shutdown :: proc(self: ^SceneDescriptors, gctx: ^gpu.GPUContext) {
  vk.DestroyPipelineLayout(gctx.device, self.layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self^ = {}
}

// Point binding `b` of frame `frame_index`'s scene set at its current buffer.
// The caller guarantees no submitted work still uses that set.
scene_write_binding :: proc(self: ^Manager, b: SceneBinding, frame_index: int) {
  gpu.write_descriptor(
    &self.gctx,
    self.internal.scene.sets[frame_index],
    u32(b),
    0,
    SCENE_BINDING_TYPES[b],
    scene_binding_info(self, b, frame_index),
  )
}

// Bind the scene and textures sets of `frame_index` to `bind_point`.
bind_scene_sets :: proc(
  self: ^Manager,
  cmd: vk.CommandBuffer,
  bind_point: vk.PipelineBindPoint,
  frame_index: u32,
) {
  sets := [2]vk.DescriptorSet {
    self.internal.scene.sets[frame_index],
    self.texture_manager.descriptor_set,
  }
  vk.CmdBindDescriptorSets(cmd, bind_point, self.internal.scene.layout, 0, len(sets), raw_data(sets[:]), 0, nil)
}

// Push `data` at offset 0 of the push-constant range, through the scene
// layout or another layout with the same range.
push_constants :: proc {
  push_scene_constants,
  push_layout_constants,
}

push_scene_constants :: proc(self: ^Manager, cmd: vk.CommandBuffer, data: ^$T) {
  push_layout_constants(cmd, self.internal.scene.layout, data)
}

push_layout_constants :: proc(cmd: vk.CommandBuffer, layout: vk.PipelineLayout, data: ^$T) {
  #assert(size_of(T) <= PUSH_CONSTANT_SIZE)
  vk.CmdPushConstants(cmd, layout, SCENE_STAGES, 0, size_of(T), data)
}

// Bind the mesh arena's vertex and index buffers.
bind_mesh_buffers :: proc(self: ^Manager, cmd: vk.CommandBuffer) {
  gpu.bind_vertex_index_buffers(
    cmd,
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
  )
}

// Bindless 2D texture indices of one camera's G-buffer for one frame.
GBuffer :: struct {
  normal:             u32,
  albedo:             u32,
  metallic_roughness: u32,
  emissive:           u32,
  depth:              u32,
}

camera_gbuffer :: proc(cam: ^Camera, frame_index: u32) -> GBuffer {
  return {
    normal             = cam.attachments[.NORMAL][frame_index].index,
    albedo             = cam.attachments[.ALBEDO][frame_index].index,
    metallic_roughness = cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive           = cam.attachments[.EMISSIVE][frame_index].index,
    depth              = cam.attachments[.DEPTH][frame_index].index,
  }
}

// The image behind one of a camera's attachments for one frame.
camera_image :: proc(
  self: ^Manager,
  cam: ^Camera,
  a: AttachmentType,
  frame_index: u32,
) -> ^gpu.Image {
  return get_texture(&self.texture_manager, cam.attachments[a][frame_index])
}
