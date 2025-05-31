package mjolnir

import "animation"
import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import vk "vendor:vulkan"

Bone :: struct {
  bind_transform:      geometry.Transform,
  children:            []u32,
  inverse_bind_matrix: linalg.Matrix4f32,
  name:                string,
}

bone_deinit :: proc(bone: ^Bone) {
  if bone.children != nil {
    delete(bone.children)
    bone.children = nil
  }
}

Skinning :: struct {
  root_bone_index: u32,
  bones:           []Bone,
  animations:      []animation.Clip,
  skin_buffer:     DataBuffer,
}

Mesh :: struct {
  vertices_len:  u32,
  indices_len:   u32,
  vertex_buffer: DataBuffer,
  index_buffer:  DataBuffer,
  aabb:          geometry.Aabb,
  skinning:      Maybe(Skinning),
}

mesh_deinit :: proc(self: ^Mesh) {
  data_buffer_deinit(&self.vertex_buffer)
  data_buffer_deinit(&self.index_buffer)

  skin, has_skin := &self.skinning.?
  if !has_skin {
    return
  }
  data_buffer_deinit(&skin.skin_buffer)

  for &bone in skin.bones {
    bone_deinit(&bone)
  }
  delete(skin.bones)
  for &clip in skin.animations {
    animation.clip_deinit(&clip)
  }
  delete(skin.animations)
}

mesh_init :: proc(self: ^Mesh, data: geometry.Geometry) -> vk.Result {
  self.vertices_len = u32(len(data.vertices))
  self.indices_len = u32(len(data.indices))
  self.aabb = data.aabb
  size := len(data.vertices) * size_of(geometry.Vertex)
  self.vertex_buffer = create_local_buffer(
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
    raw_data(data.vertices),
  ) or_return
  size = len(data.indices) * size_of(u32)
  self.index_buffer = create_local_buffer(
    vk.DeviceSize(size),
    {.INDEX_BUFFER},
    raw_data(data.indices),
  ) or_return

  skinnings, has_skin := data.skinnings.?
  if has_skin {
    size = len(skinnings) * size_of(geometry.SkinningData)
    skin_buffer := create_local_buffer(
      vk.DeviceSize(size),
      {.VERTEX_BUFFER},
      raw_data(skinnings),
    ) or_return
    self.skinning = Skinning {
      bones       = make([]Bone, 0),
      animations  = make([]animation.Clip, 0),
      skin_buffer = skin_buffer,
    }
  }
  return .SUCCESS
}

make_animation_instance :: proc(
  self: ^Mesh,
  animation_name: string,
  mode: animation.PlayMode,
  speed: f32 = 1.0,
) -> (
  instance: animation.Instance,
  found: bool,
) {
  skin, has_skin := &self.skinning.?
  if !has_skin {
    found = false
    return
  }
  for clip, i in skin.animations {
    if clip.name == animation_name {
      found = true
      instance = {
        clip_handle = u32(i),
        mode        = mode,
        status      = .PLAYING,
        time        = 0.0,
        duration    = clip.duration,
        speed       = speed,
      }
      return
    }
  }
  return
}

sample_clip :: proc(
  self: ^Mesh,
  clip_idx: u32,
  t: f32,
  out_bone_matrices: []linalg.Matrix4f32,
) {
  skin, has_skin := &self.skinning.?
  if !has_skin {
    return
  }
  if len(out_bone_matrices) < len(skin.bones) ||
     clip_idx >= u32(len(skin.animations)) {
    return
  }
  TraverseEntry :: struct {
    transform: linalg.Matrix4f32,
    bone:      u32,
  }
  stack := make([dynamic]TraverseEntry, 0, len(skin.bones))
  defer delete(stack)
  append(
    &stack,
    TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
  )
  clip := &skin.animations[clip_idx]
  for len(stack) > 0 {
    entry := pop(&stack)
    bone := &skin.bones[entry.bone]
    local_transform: geometry.Transform
    if entry.bone < u32(len(clip.channels)) {
      local_transform.position, local_transform.rotation, local_transform.scale =
        animation.channel_sample(clip.channels[entry.bone], t)
    } else {
      local_transform = bone.bind_transform
    }
    local_matrix := linalg.matrix4_from_trs(
      local_transform.position,
      local_transform.rotation,
      local_transform.scale,
    )
    world_transform := entry.transform * local_matrix
    out_bone_matrices[entry.bone] = world_transform * bone.inverse_bind_matrix
    for child_index in bone.children {
      append(&stack, TraverseEntry{world_transform, child_index})
    }
  }
}
