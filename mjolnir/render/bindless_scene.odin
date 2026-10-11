#+private
package render

import "gpu"
import vk "vendor:vulkan"

// Descriptor sets shared by the scene-mesh pipelines. A pipeline binds a
// subset of them as consecutive sets, in enum order.
SceneSet :: enum {
  CAMERA,
  TEXTURES,
  BONE,
  MATERIAL,
  NODE_DATA,
  MESH_DATA,
  VERTEX_SKINNING,
}

SceneSets :: bit_set[SceneSet]

MESH_SETS :: SceneSets {
  .CAMERA,
  .TEXTURES,
  .BONE,
  .MATERIAL,
  .NODE_DATA,
  .MESH_DATA,
  .VERTEX_SKINNING,
}
SPRITE_SETS :: SceneSets{.CAMERA, .TEXTURES, .MATERIAL, .NODE_DATA}

scene_set_layout :: proc(self: ^Manager, s: SceneSet) -> vk.DescriptorSetLayout {
  switch s {
  case .CAMERA:          return self.internal.camera_buffer.set_layout
  case .TEXTURES:        return self.texture_manager.set_layout
  case .BONE:            return self.internal.bone_buffer.set_layout
  case .MATERIAL:        return self.internal.material_buffer.set_layout
  case .NODE_DATA:       return self.internal.node_data_buffer.set_layout
  case .MESH_DATA:       return self.internal.mesh_data_buffer.set_layout
  case .VERTEX_SKINNING: return self.mesh_manager.skinning_set_layout
  }
  return 0
}

scene_set :: proc(self: ^Manager, s: SceneSet, frame_index: u32) -> vk.DescriptorSet {
  switch s {
  case .CAMERA:          return self.internal.camera_buffer.descriptor_sets[frame_index]
  case .TEXTURES:        return self.texture_manager.descriptor_set
  case .BONE:            return self.internal.bone_buffer.descriptor_sets[frame_index]
  case .MATERIAL:        return self.internal.material_buffer.descriptor_sets[frame_index]
  case .NODE_DATA:       return self.internal.node_data_buffer.descriptor_sets[frame_index]
  case .MESH_DATA:       return self.internal.mesh_data_buffer.descriptor_set
  case .VERTEX_SKINNING: return self.mesh_manager.skinning_set
  }
  return 0
}

create_scene_pipeline_layout :: proc(
  self: ^Manager,
  sets: SceneSets,
  push_constant: vk.PushConstantRange,
) -> (
  vk.PipelineLayout,
  vk.Result,
) {
  layouts: [len(SceneSet)]vk.DescriptorSetLayout
  n := 0
  for s in sets {
    layouts[n] = scene_set_layout(self, s)
    n += 1
  }
  return gpu.create_pipeline_layout(&self.gctx, push_constant, ..layouts[:n])
}

// Binds the pipeline, the scene sets it declares and the mesh vertex/index
// buffers.
bind_scene :: proc(
  self: ^Manager,
  cmd: vk.CommandBuffer,
  frame_index: u32,
  pipeline: vk.Pipeline,
  layout: vk.PipelineLayout,
  sets: SceneSets,
) {
  ds: [len(SceneSet)]vk.DescriptorSet
  n := 0
  for s in sets {
    ds[n] = scene_set(self, s, frame_index)
    n += 1
  }
  gpu.bind_pipeline(cmd, .GRAPHICS, pipeline, layout, ..ds[:n])
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
  return get_texture_2d(&self.texture_manager, cam.attachments[a][frame_index])
}
