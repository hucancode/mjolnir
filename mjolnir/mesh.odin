package mjolnir

import "animation"
import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import "resource"
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
  material:      Handle,
  aabb:          geometry.Aabb,
  skinning:      Maybe(Skinning),
}

mesh_deinit :: proc(self: ^Mesh) {
  if self.vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.vertex_buffer)
  }
  if self.index_buffer.buffer != 0 {
    data_buffer_deinit(&self.index_buffer)
  }
  if self.skinning != nil {
    skin, ok := &self.skinning.?
    if skin.skin_buffer.buffer != 0 {
      data_buffer_deinit(&skin.skin_buffer)
    }
    if skin.bones != nil {
      for &bone in skin.bones {
        bone_deinit(&bone)
      }
      delete(skin.bones)
    }
    if skin.animations != nil {
      for &anim_clip in skin.animations {
        // deinit_clip(&anim_clip)
      }
      delete(skin.animations)
    }
  }
}

mesh_init :: proc(
  self: ^Mesh,
  data: geometry.Geometry,
  material: Handle,
) -> vk.Result {
  self.vertices_len = u32(len(data.vertices))
  self.indices_len = u32(len(data.indices))
  self.aabb = data.aabb
  self.material = material
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

create_mesh :: proc(
  engine: ^Engine,
  data: geometry.Geometry,
  material: Handle,
) -> (
  handle: Handle,
  mesh: ^Mesh,
  ret: vk.Result,
) {
  handle, mesh = resource.alloc(&engine.meshes)
  mesh_init(mesh, data, material)
  ret = .SUCCESS
  return
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
  found = false
  return
}

calculate_animation_transform :: proc(
  self: ^Mesh,
  anim_instance: ^animation.Instance,
  target_pose: ^animation.Pose,
) {
  skin, has_skin := &self.skinning.?
  if !has_skin {
      return
  }
  if anim_instance.status == .STOPPED ||
     anim_instance.clip_handle >= u32(len(skin.animations)) {
    return
  }
  if len(target_pose.bone_matrices) < len(skin.bones) {
    return
  }
  transform_stack := make([dynamic]linalg.Matrix4f32, 0, len(skin.bones))
  bone_stack := make([dynamic]u32, 0, len(skin.bones))
  defer {
    delete(transform_stack)
    delete(bone_stack)
  }
  append(&transform_stack, linalg.MATRIX4F32_IDENTITY)
  append(&bone_stack, u32(skin.root_bone_index))
  active_clip := &skin.animations[anim_instance.clip_handle]
  for len(bone_stack) > 0 {
    current_bone_index := pop(&bone_stack)
    parent_world_transform := pop(&transform_stack)
    current_bone := &skin.bones[current_bone_index]
    local_transform: geometry.Transform
    if current_bone_index < u32(len(active_clip.channels)) {
      local_transform.position, local_transform.rotation, local_transform.scale =
        animation.channel_sample(
          active_clip.channels[current_bone_index],
          anim_instance.time,
        )
    } else {
      local_transform = current_bone.bind_transform
    }
    local_matrix := linalg.matrix4_from_trs(
      local_transform.position,
      local_transform.rotation,
      local_transform.scale,
    )
    current_world_transform := parent_world_transform * local_matrix
    target_pose.bone_matrices[current_bone_index] =
      current_world_transform * current_bone.inverse_bind_matrix
    for child_index in current_bone.children {
      append(&transform_stack, current_world_transform)
      append(&bone_stack, child_index)
    }
  }
}
