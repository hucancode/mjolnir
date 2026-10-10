package bindless

import "../gpu"
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
  SPRITE,
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
SPRITE_SETS :: SceneSets{.CAMERA, .TEXTURES, .NODE_DATA, .SPRITE}

// Layouts and current-frame sets for every SceneSet, plus the mesh
// vertex/index buffers.
SceneBindings :: struct {
  layouts:       [SceneSet]vk.DescriptorSetLayout,
  sets:          [SceneSet]vk.DescriptorSet,
  vertex_buffer: vk.Buffer,
  index_buffer:  vk.Buffer,
}

create_scene_pipeline_layout :: proc(
  gctx: ^gpu.GPUContext,
  scene: SceneBindings,
  sets: SceneSets,
  push_constant: vk.PushConstantRange,
) -> (
  vk.PipelineLayout,
  vk.Result,
) {
  layouts: [len(SceneSet)]vk.DescriptorSetLayout
  n := 0
  for s in sets {
    layouts[n] = scene.layouts[s]
    n += 1
  }
  return gpu.create_pipeline_layout(gctx, push_constant, ..layouts[:n])
}

// Binds the pipeline, the scene sets it declares and the mesh vertex/index
// buffers.
bind_scene :: proc(
  cmd: vk.CommandBuffer,
  pipeline: vk.Pipeline,
  layout: vk.PipelineLayout,
  scene: SceneBindings,
  sets: SceneSets,
) {
  ds: [len(SceneSet)]vk.DescriptorSet
  n := 0
  for s in sets {
    ds[n] = scene.sets[s]
    n += 1
  }
  gpu.bind_pipeline(cmd, .GRAPHICS, pipeline, layout, ..ds[:n])
  gpu.bind_vertex_index_buffers(cmd, scene.vertex_buffer, scene.index_buffer)
}

// Bindless 2D texture indices of one camera's G-buffer for one frame.
GBuffer :: struct {
  position:           u32,
  normal:             u32,
  albedo:             u32,
  metallic_roughness: u32,
  emissive:           u32,
  depth:              u32,
}
