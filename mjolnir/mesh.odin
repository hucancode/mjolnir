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
    // delete(bone.children)
    bone.children = nil
  }
}

SkeletalMesh :: struct {
  root_bone_index: u32,
  bones:           []Bone,
  animations:      []animation.Clip,
  vertices_len:    u32,
  indices_len:     u32,
  vertex_buffer:   DataBuffer,
  skin_buffer:     DataBuffer,
  index_buffer:    DataBuffer,
  material:        Handle,
  aabb:            geometry.Aabb,
  ctx:             ^VulkanContext,
}

skeletal_mesh_deinit :: proc(self: ^SkeletalMesh) {
  if self.ctx == nil {
    return
  }

  if self.vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.vertex_buffer, self.ctx)
  }
  if self.index_buffer.buffer != 0 {
    data_buffer_deinit(&self.index_buffer, self.ctx)
  }
  if self.bones != nil {
    for &bone in self.bones {
      bone_deinit(&bone)
    }
    delete(self.bones)
    self.bones = nil
  }
  if self.animations != nil {
    for &anim_clip in self.animations {
      // deinit_clip(&anim_clip)
    }
    delete(self.animations)
    self.animations = nil
  }

  self.ctx = nil
}

skeletal_mesh_init :: proc(
  self: ^SkeletalMesh,
  geometry_data: ^geometry.SkinnedGeometry,
  ctx: ^VulkanContext,
) -> vk.Result {
  self.ctx = ctx
  self.vertices_len = u32(len(geometry_data.vertices))
  self.indices_len = u32(len(geometry_data.indices))
  self.aabb = geometry_data.aabb
  size := len(geometry_data.vertices) * size_of(geometry.Vertex)
  self.vertex_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
    raw_data(geometry_data.vertices),
  ) or_return
  size = len(geometry_data.skinnings) * size_of(geometry.SkinningData)
  self.skin_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
    raw_data(geometry_data.skinnings),
  ) or_return
  size = len(geometry_data.indices) * size_of(u32)
  self.index_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.INDEX_BUFFER},
    raw_data(geometry_data.indices),
  ) or_return
  self.bones = make([]Bone, 0)
  self.animations = make([]animation.Clip, 0)
  return .SUCCESS
}

make_animation_instance :: proc(
  self: ^SkeletalMesh,
  animation_name: string,
  mode: animation.PlayMode,
  speed: f32 = 1.0,
) -> (
  instance: animation.Instance,
  found: bool,
) {
  for clip, i in self.animations {
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
  self: ^SkeletalMesh,
  anim_instance: ^animation.Instance,
  target_pose: ^animation.Pose,
) {
  if anim_instance.status == .STOPPED ||
     anim_instance.clip_handle >= u32(len(self.animations)) {
    return
  }
  if len(target_pose.bone_matrices) < len(self.bones) {
    return
  }
  transform_stack := make([dynamic]linalg.Matrix4f32, 0, len(self.bones))
  bone_stack := make([dynamic]u32, 0, len(self.bones))
  defer {
    delete(transform_stack)
    delete(bone_stack)
  }
  append(&transform_stack, linalg.MATRIX4F32_IDENTITY)
  append(&bone_stack, u32(self.root_bone_index))
  active_clip := &self.animations[anim_instance.clip_handle]
  for len(bone_stack) > 0 {
    current_bone_index := pop(&bone_stack)
    parent_world_transform := pop(&transform_stack)
    current_bone := &self.bones[current_bone_index]
    local_transform: geometry.Transform
    if current_bone_index < u32(len(active_clip.channels)) {
      channel := &active_clip.channels[current_bone_index]
      local_transform.position, local_transform.rotation, local_transform.scale =
        animation.channel_sample(channel, anim_instance.time)
    } else {
      local_transform = current_bone.bind_transform
    }
    local_matrix := linalg.matrix4_from_trs(
      local_transform.position,
      local_transform.rotation,
      local_transform.scale,
    )
    current_world_transform := parent_world_transform * local_matrix
    // fmt.printfln("calculate_animation_transform, local matrix", local_matrix)
    target_pose.bone_matrices[current_bone_index] =
      current_world_transform * current_bone.inverse_bind_matrix
    for child_index in current_bone.children {
      append(&transform_stack, current_world_transform)
      append(&bone_stack, child_index)
    }
  }
}

StaticMesh :: struct {
  material:      Handle,
  vertices_len:  u32,
  indices_len:   u32,
  vertex_buffer: DataBuffer,
  index_buffer:  DataBuffer,
  aabb:          geometry.Aabb,
  ctx:           ^VulkanContext,
}

static_mesh_deinit :: proc(self: ^StaticMesh) {
  if self.ctx == nil {
    return
  }
  if self.vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.vertex_buffer, self.ctx)
  }
  if self.index_buffer.buffer != 0 {
    data_buffer_deinit(&self.index_buffer, self.ctx)
  }
  self.vertices_len = 0
  self.indices_len = 0
  self.aabb = {}
  self.ctx = nil
}

static_mesh_init :: proc(
  self: ^StaticMesh,
  data: ^geometry.Geometry,
  ctx: ^VulkanContext,
) -> vk.Result {
  self.ctx = ctx
  self.vertices_len = u32(len(data.vertices))
  self.indices_len = u32(len(data.indices))
  self.aabb = data.aabb
  size := len(data.vertices) * size_of(geometry.Vertex)
  self.vertex_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
    raw_data(data.vertices),
  ) or_return

  size = len(data.indices) * size_of(u32)
  self.index_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.INDEX_BUFFER},
    raw_data(data.indices),
  ) or_return

  return .SUCCESS
}

create_static_mesh :: proc(
  engine: ^Engine,
  geom: ^geometry.Geometry,
  material: Handle,
) -> (
  handle: Handle,
  mesh: ^StaticMesh,
  ret: vk.Result,
) {
  handle, mesh = resource.alloc(&engine.meshes)
  if mesh == nil {
    ret = .ERROR_UNKNOWN
    return
  }
  static_mesh_init(mesh, geom, &engine.ctx) or_return
  mesh.material = material
  ret = .SUCCESS
  return
}
